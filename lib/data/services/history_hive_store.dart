import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/history_item.dart';

/// Phase 12.5 (PERF-2): history persistence moves from whole-list JSON
/// strings in SharedPreferences to per-item Hive entries.
///
/// Why: SP re-serialized up to ~0.5 MB of JSON on EVERY add/update (1000-item
/// FIFO cap); Hive `add` is O(1) per item with no rewrite of the rest.
///
/// Migration (idempotent, plan step 4): on first open, if the legacy SP keys
/// exist, decode once into Hive and delete the SP keys. Failure is non-fatal
/// (histories are logs — plan's own wording). Downgrade path unsupported
/// (noted in plan).
///
/// Adapter TypeIds: BackgroundTaskState already owns TypeId 1 (main.dart);
/// HistoryItem = 2, DownloadHistoryItem = 3, HistoryStatus enum = 4.
class HistoryItemAdapter extends TypeAdapter<HistoryItem> {
  @override
  final int typeId = 2;

  @override
  HistoryItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      final key = reader.readByte();
      final value = reader.read();
      fields[key] = value;
    }
    return HistoryItem(
      id: fields[0] as String,
      url: fields[1] as String,
      status: fields[2] as HistoryStatus,
      createdAt: fields[3] as DateTime,
      errorMessage: fields[4] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, HistoryItem obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.url)
      ..writeByte(2)
      ..write(obj.status)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.errorMessage);
  }
}

class DownloadHistoryItemAdapter extends TypeAdapter<DownloadHistoryItem> {
  @override
  final int typeId = 3;

  @override
  DownloadHistoryItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      final key = reader.readByte();
      final value = reader.read();
      fields[key] = value;
    }
    return DownloadHistoryItem(
      id: fields[0] as String,
      filename: fields[1] as String,
      url: fields[2] as String,
      status: fields[3] as HistoryStatus,
      createdAt: fields[4] as DateTime,
      errorMessage: fields[5] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, DownloadHistoryItem obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.filename)
      ..writeByte(2)
      ..write(obj.url)
      ..writeByte(3)
      ..write(obj.status)
      ..writeByte(4)
      ..write(obj.createdAt)
      ..writeByte(5)
      ..write(obj.errorMessage);
  }
}

class HistoryStatusAdapter extends TypeAdapter<HistoryStatus> {
  @override
  final int typeId = 4;

  @override
  HistoryStatus read(BinaryReader reader) =>
      HistoryStatus.values[reader.readByte()];

  @override
  void write(BinaryWriter writer, HistoryStatus obj) =>
      writer.writeByte(obj.index);
}

/// Hive-backed store for one history type. Keys are auto-increment ints;
/// FIFO cap = delete lowest keys beyond [_maxItems].
class HistoryHiveStore<T> {
  final Box<T> box;
  final int maxItems;
  final String legacySpKey;
  final T? Function(Map<String, dynamic>) fromSpJson;

  HistoryHiveStore({
    required this.box,
    required this.legacySpKey,
    required this.fromSpJson,
    this.maxItems = 1000,
  });

  static Future<void> registerAdapters() async {
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(HistoryItemAdapter());
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(DownloadHistoryItemAdapter());
    }
    if (!Hive.isAdapterRegistered(4)) {
      Hive.registerAdapter(HistoryStatusAdapter());
    }
  }

  /// Open the box and run the one-time SP→Hive migration.
  static Future<HistoryHiveStore<HistoryItem>> openExtraction(
      SharedPreferences? prefs) async {
    await registerAdapters();
    final box = await Hive.openBox<HistoryItem>('extraction_history');
    final store = HistoryHiveStore(
      box: box,
      legacySpKey: 'extraction_history',
      fromSpJson: (j) => HistoryItem.fromJson(j),
    );
    await store._migrateFrom(prefs, box);
    return store;
  }

  static Future<HistoryHiveStore<DownloadHistoryItem>> openDownloads(
      SharedPreferences? prefs) async {
    await registerAdapters();
    final box = await Hive.openBox<DownloadHistoryItem>('download_history');
    final store = HistoryHiveStore(
      box: box,
      legacySpKey: 'download_history',
      fromSpJson: (j) => DownloadHistoryItem.fromJson(j),
    );
    await store._migrateFrom(prefs, box);
    return store;
  }

  /// Plan step 4: decode legacy SP list once into Hive, delete SP keys.
  /// Idempotent: SP key absence = already migrated (or fresh install).
  Future<void> _migrateFrom(
      SharedPreferences? prefs, Box<dynamic> box) async {
    if (prefs == null) return;
    final jsonStr = prefs.getString(legacySpKey);
    if (jsonStr == null) return;
    try {
      // Only import when the Hive box is empty — a failed run that deleted
      // the SP key mid-way loses nothing (histories are logs).
      if (box.isEmpty) {
        final list =
            (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
        for (final entry in list) {
          await box.add(fromSpJson(entry));
        }
      }
      await prefs.remove(legacySpKey);
    } catch (_) {
      // Non-fatal: leave SP data in place; retried next run.
    }
  }

  List<T> loadAll() {
    // Insertion (key) order — exactly the old SP JSON list semantics, and
    // the order the notifier state uses, so state indices == box indices.
    // Display sorting stays the notifier's job (sortedItems).
    return box.values.toList();
  }

  // Phase 12.5 (G5 finding): notifier mutators are sync void, so store ops
  // fire un-awaited and can interleave (clear landing before a pending add,
  // concurrent eviction loops breaking the FIFO cap). Serialize every
  // mutation; each queued op runs to completion before the next starts.
  Future<void> _opQueue = Future.value();

  /// Resolves when every queued mutation has settled (test/teardown drain).
  Future<void> get idle => _opQueue;

  Future<void> _enqueue(Future<void> Function() op) {
    final result = _opQueue.then((_) => op());
    // Keep the queue alive if an op fails (histories are logs).
    _opQueue = result.catchError((Object _) {});
    return result;
  }

  Future<void> add(T item) => _enqueue(() async {
        await box.add(item);
        // FIFO cap: delete oldest keys beyond the cap (amortized O(1)).
        while (box.length > maxItems) {
          await box.delete(box.keyAt(0));
        }
      });

  Future<void> updateAt(int index, T item) => _enqueue(() async {
        if (index < 0 || index >= box.length) return;
        await box.putAt(index, item);
      });

  Future<void> clearAll() => _enqueue(box.clear);

  int get length => box.length;

  T? itemAt(int index) =>
      (index < 0 || index >= box.length) ? null : box.getAt(index);
}
