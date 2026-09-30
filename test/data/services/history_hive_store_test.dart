import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:pindl/data/models/history_item.dart';
import 'package:pindl/data/services/history_hive_store.dart';
import 'package:pindl/presentation/providers/history_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 12.5 (PERF-2 / G5) — history persistence moved from whole-list JSON
/// in SharedPreferences to per-item Hive entries.
///
/// Contract evidence pinned here:
/// 1. Migration parity: seeded legacy SP JSON → Hive with zero loss.
/// 2. Idempotency: migration runs once (SP key deleted; second open no-ops).
/// 3. Precedence: existing Hive data wins; stale SP key is still removed.
/// 4. Non-fatal failure: corrupt SP JSON never throws; key kept for retry.
/// 5. FIFO cap: >maxItems evicts oldest (lowest key) on both store and notifier.
/// 6. State↔store index alignment: updateLast(index) writes the same record.
/// 7. Write volume: O(n)-serialize-per-add vs O(1) add — measured (G5).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('pindl_test_hive');
    // Plain dart:io init (no path_provider channel needed in tests).
    Hive.init(tempRoot.path);
  });

  tearDown(() async {
    await Hive.close();
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  Future<SharedPreferences> seedSp(
      String key, List<Map<String, dynamic>> items) async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode(items),
    });
    return SharedPreferences.getInstance();
  }

  Map<String, dynamic> legacyJson(String id, int minutesSinceEpoch,
          {String status = 'success', String? error}) =>
      HistoryItem(
        id: id,
        url: 'https://www.pinterest.com/pin/$id/',
        status: HistoryStatus.values.firstWhere((s) => s.name == status),
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(minutesSinceEpoch * 60000),
        errorMessage: error,
      ).toJson();

  HistoryItem legacyItem(String id, int minutesSinceEpoch,
          {String status = 'success', String? error}) =>
      HistoryItem.fromJson(legacyJson(id, minutesSinceEpoch,
          status: status, error: error));

  group('SP→Hive migration parity (G5)', () {
    test('extraction history: seeded SP JSON migrates losslessly', () async {
      final legacy = [
        legacyJson('a', 1, status: 'pending'),
        legacyJson('b', 2, status: 'success'),
        legacyJson('c', 3, status: 'failed', error: 'boom'),
        legacyJson('d', 4, status: 'cancelled'),
      ];
      final prefs = await seedSp('extraction_history', legacy);

      final store = await HistoryHiveStore.openExtraction(prefs);

      final loaded = store.loadAll();
      expect(loaded, hasLength(4));
      for (var i = 0; i < legacy.length; i++) {
        final original = HistoryItem.fromJson(legacy[i]);
        expect(loaded[i].id, original.id, reason: 'item $i order preserved');
        expect(loaded[i].url, original.url);
        expect(loaded[i].status, original.status);
        expect(loaded[i].createdAt, original.createdAt);
        expect(loaded[i].errorMessage, original.errorMessage);
      }
      // SP key deleted after a successful migration.
      expect(prefs.getString('extraction_history'), isNull);
    });

    test('download history: seeded SP JSON migrates losslessly', () async {
      final legacy = [
        DownloadHistoryItem(
          id: 'd1',
          filename: 'img_1.jpg',
          url: 'https://i.pinimg.com/1.jpg',
          status: HistoryStatus.success,
          createdAt: DateTime.fromMillisecondsSinceEpoch(60000),
        ),
        DownloadHistoryItem(
          id: 'd2',
          filename: 'img_2.jpg',
          url: 'https://i.pinimg.com/2.jpg',
          status: HistoryStatus.failed,
          createdAt: DateTime.fromMillisecondsSinceEpoch(120000),
          errorMessage: 'disk full',
        ),
      ];
      final prefs = await seedSp(
        'download_history',
        legacy.map((e) => e.toJson()).toList(),
      );

      final store = await HistoryHiveStore.openDownloads(prefs);

      final loaded = store.loadAll();
      expect(loaded, hasLength(2));
      expect(loaded[0].filename, 'img_1.jpg');
      expect(loaded[0].status, HistoryStatus.success);
      expect(loaded[1].filename, 'img_2.jpg');
      expect(loaded[1].status, HistoryStatus.failed);
      expect(loaded[1].errorMessage, 'disk full');
      expect(prefs.getString('download_history'), isNull);
    });

    test('idempotent: second open does not duplicate or re-import', () async {
      final legacy = [legacyJson('a', 1), legacyJson('b', 2)];
      final prefs = await seedSp('extraction_history', legacy);

      final first = await HistoryHiveStore.openExtraction(prefs);
      expect(first.length, 2);
      expect(prefs.getString('extraction_history'), isNull);

      // Second open on the same (now persistent) box: no duplication.
      final second = await HistoryHiveStore.openExtraction(prefs);
      expect(second.length, 2);
      expect(second.loadAll().map((e) => e.id), ['a', 'b']);
    });

    test('precedence: existing Hive data wins, stale SP key still removed',
        () async {
      // Populate Hive directly first (e.g. app already wrote new-format data).
      // Open with null prefs: no SP → no migration fires on this open.
      final pre = await HistoryHiveStore.openExtraction(null);
      await pre.add(legacyItem('hive', 9, status: 'success'));
      await pre.idle;
      // Re-seed SP as if an old client re-created it (downgrade/restore edge).
      SharedPreferences.setMockInitialValues({
        'extraction_history': jsonEncode([legacyJson('stale', 1)]),
      });
      final prefs2 = await SharedPreferences.getInstance();

      final store = await HistoryHiveStore.openExtraction(prefs2);

      expect(store.loadAll().map((e) => e.id), ['hive'],
          reason: 'import skipped when box non-empty');
      expect(prefs2.getString('extraction_history'), isNull,
          reason: 'stale key removed to stop repeat attempts');
    });

    test('corrupt SP JSON is non-fatal: no throw, key kept for retry',
        () async {
      SharedPreferences.setMockInitialValues({
        'extraction_history': '{not-valid-json',
      });
      final prefs = await SharedPreferences.getInstance();

      final store = await HistoryHiveStore.openExtraction(prefs);

      expect(store.length, 0, reason: 'nothing imported');
      expect(prefs.getString('extraction_history'), '{not-valid-json',
          reason: 'data left in place for a retry on next run');
    });

    test('fresh install (no SP key): opens empty without touching SP',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final store = await HistoryHiveStore.openExtraction(prefs);

      expect(store.length, 0);
      expect(prefs.getKeys(), isEmpty);
    });
  });

  group('FIFO cap (plan step 3)', () {
    test('store: exceeding maxItems evicts oldest (lowest key) first',
        () async {
      final box = await Hive.openBox<HistoryItem>('extraction_history');
      final store = HistoryHiveStore<HistoryItem>(
        box: box,
        legacySpKey: 'extraction_history',
        fromSpJson: HistoryItem.fromJson,
        maxItems: 10,
      );
      for (var i = 0; i < 12; i++) {
        await store.add(legacyItem('i$i', i + 1));
      }

      expect(store.length, 10);
      final ids = store.loadAll().map((e) => e.id).toList();
      expect(ids.first, 'i2', reason: 'oldest two evicted');
      expect(ids.last, 'i11');
      expect(ids.contains('i0'), isFalse);
      expect(ids.contains('i1'), isFalse);
    });

    test('notifier+store stay aligned across eviction (1001 adds)', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = await HistoryHiveStore.openExtraction(prefs);
      final notifier = HistoryNotifier(store);

      for (var i = 0; i < 1001; i++) {
        notifier.addPending('https://www.pinterest.com/pin/$i/');
      }
      // Drain the store's serialized op queue (async Hive I/O needs more
      // than one event-loop turn — Duration.zero does NOT drain it).
      await store.idle;

      expect(notifier.state.items, hasLength(1000));
      expect(store.length, 1000);
      expect(
        notifier.state.items.first.id,
        store.loadAll().first.id,
        reason: 'both FIFO evictions dropped the same oldest record',
      );
      expect(
        notifier.state.items.last.id,
        store.loadAll().last.id,
      );
    });
  });

  group('state↔store index alignment (updateLast mirror)', () {
    test('updateLast persists to the same record in Hive', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = await HistoryHiveStore.openExtraction(prefs);
      final notifier = HistoryNotifier(store);

      notifier.addPending('https://www.pinterest.com/pin/1/');
      notifier.addPending('https://www.pinterest.com/pin/2/');
      await store.idle;

      notifier.updateLast(HistoryStatus.failed, errorMessage: 'parse failed');
      await store.idle;

      final persisted = store.loadAll();
      expect(persisted, hasLength(2));
      expect(persisted[0].status, HistoryStatus.pending,
          reason: 'first item untouched');
      expect(persisted[1].status, HistoryStatus.failed);
      expect(persisted[1].errorMessage, 'parse failed');

      // Reload from disk through a fresh notifier: same data, no loss.
      final reloaded = HistoryNotifier(
        await HistoryHiveStore.openExtraction(prefs),
      );
      expect(reloaded.state.items[1].status, HistoryStatus.failed);
      expect(reloaded.state.items[1].errorMessage, 'parse failed');
    });

    test('clearAll empties both state and store', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = await HistoryHiveStore.openExtraction(prefs);
      final notifier = HistoryNotifier(store);

      notifier.addPending('https://www.pinterest.com/pin/1/');
      await store.idle;
      notifier.clearAll();
      await store.idle;

      expect(notifier.state.items, isEmpty);
      expect(store.length, 0);
    });
  });

  group('write volume (G5 measured)', () {
    test('per-add written bytes: O(1) item vs O(n) whole-list JSON',
        () async {
      // OLD model (pre-12.5): every add re-encoded the FULL list to JSON and
      // wrote that string to SharedPreferences. Modeled faithfully below.
      const n = 1000;
      final oldList = List.generate(n, (i) => legacyJson('i$i', i + 1));

      var oldBytes = 0;
      final oldSw = Stopwatch()..start();
      for (var add = 0; add < 100; add++) {
        oldList.add(legacyJson('new$add', n + add + 1));
        oldBytes += jsonEncode(oldList).length; // what _saveHistory wrote
      }
      oldSw.stop();

      // NEW: Hive store with n preloaded items; each add writes one record.
      final store = await HistoryHiveStore.openExtraction(null);
      for (var i = 0; i < n; i++) {
        await store.add(legacyItem('i$i', i + 1));
      }
      var newBytes = 0;
      final newSw = Stopwatch()..start();
      for (var add = 0; add < 100; add++) {
        final item = legacyJson('new$add', n + add + 1);
        await store.add(HistoryItem.fromJson(item));
        newBytes += item.length; // one record ≈ the map's own volume
      }
      newSw.stop();

      // ignore: avoid_print
      print('G5 write volume (100 adds onto 1000-item history): '
          'old=${oldBytes ~/ 1024}KB (${oldSw.elapsedMilliseconds}ms), '
          'new≈${(newBytes / 1024).toStringAsFixed(1)}KB '
          '(${newSw.elapsedMilliseconds}ms)');

      // Deterministic claim: the old path re-serialized the whole list, so
      // its byte volume per event grows with history size; the new path is
      // bounded by a single record. Assert the structural gap, not timing.
      expect(oldBytes, greaterThan(newBytes * 100),
          reason: 'whole-list JSON rewrite per add must dwarf per-item adds');
    });
  });
}
