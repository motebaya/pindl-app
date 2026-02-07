import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/models/history_item.dart';

/// State for history management
class HistoryState {
  final List<HistoryItem> items;
  final bool sortDescending;

  const HistoryState({
    this.items = const [],
    this.sortDescending = true,
  });

  HistoryState copyWith({
    List<HistoryItem>? items,
    bool? sortDescending,
  }) {
    return HistoryState(
      items: items ?? this.items,
      sortDescending: sortDescending ?? this.sortDescending,
    );
  }

  List<HistoryItem> get sortedItems {
    final sorted = List<HistoryItem>.from(items);
    sorted.sort((a, b) => sortDescending
        ? b.createdAt.compareTo(a.createdAt)
        : a.createdAt.compareTo(b.createdAt));
    return sorted;
  }
}

/// Download history state
class DownloadHistoryState {
  final List<DownloadHistoryItem> items;
  final bool sortDescending;

  const DownloadHistoryState({
    this.items = const [],
    this.sortDescending = true,
  });

  DownloadHistoryState copyWith({
    List<DownloadHistoryItem>? items,
    bool? sortDescending,
  }) {
    return DownloadHistoryState(
      items: items ?? this.items,
      sortDescending: sortDescending ?? this.sortDescending,
    );
  }

  List<DownloadHistoryItem> get sortedItems {
    final sorted = List<DownloadHistoryItem>.from(items);
    sorted.sort((a, b) => sortDescending
        ? b.createdAt.compareTo(a.createdAt)
        : a.createdAt.compareTo(b.createdAt));
    return sorted;
  }
}

/// History notifier for extraction history
class HistoryNotifier extends StateNotifier<HistoryState> {
  static const _historyKey = 'extraction_history';
  static const _maxItems = 1000;
  final SharedPreferences? _prefs;

  HistoryNotifier(this._prefs) : super(const HistoryState()) {
    _loadHistory();
  }

  void _loadHistory() {
    if (_prefs == null) return;
    final jsonStr = _prefs!.getString(_historyKey);
    if (jsonStr == null) return;

    try {
      final jsonList = jsonDecode(jsonStr) as List<dynamic>;
      final items = jsonList
          .map((e) => HistoryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(items: items);
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    if (_prefs == null) return;
    final jsonList = state.items.map((e) => e.toJson()).toList();
    await _prefs!.setString(_historyKey, jsonEncode(jsonList));
  }

  /// Add a pending history item when submit is pressed
  void addPending(String url) {
    final item = HistoryItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      url: url,
      status: HistoryStatus.pending,
      createdAt: DateTime.now(),
    );
    var newItems = [...state.items, item];
    
    // Enforce max 1000 items limit (remove oldest first - FIFO)
    while (newItems.length > _maxItems) {
      newItems.removeAt(0);
    }
    
    state = state.copyWith(items: newItems);
    _saveHistory();
  }

  /// Update the last pending item to success/failed
  void updateLast(HistoryStatus status, {String? errorMessage}) {
    if (state.items.isEmpty) return;
    
    // Find the last pending item
    final index = state.items.lastIndexWhere((i) => i.status == HistoryStatus.pending);
    if (index == -1) return;

    final items = List<HistoryItem>.from(state.items);
    items[index] = items[index].copyWith(
      status: status,
      errorMessage: errorMessage,
    );
    state = state.copyWith(items: items);
    _saveHistory();
  }

  /// Toggle sort order
  void toggleSort() {
    state = state.copyWith(sortDescending: !state.sortDescending);
  }

  /// Clear all history
  void clearAll() {
    state = state.copyWith(items: []);
    _saveHistory();
  }
}

/// Download history notifier
class DownloadHistoryNotifier extends StateNotifier<DownloadHistoryState> {
  static const _historyKey = 'download_history';
  static const _maxItems = 1000;
  final SharedPreferences? _prefs;

  DownloadHistoryNotifier(this._prefs) : super(const DownloadHistoryState()) {
    _loadHistory();
  }

  void _loadHistory() {
    if (_prefs == null) return;
    final jsonStr = _prefs!.getString(_historyKey);
    if (jsonStr == null) return;

    try {
      final jsonList = jsonDecode(jsonStr) as List<dynamic>;
      final items = jsonList
          .map((e) => DownloadHistoryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(items: items);
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    if (_prefs == null) return;
    final jsonList = state.items.map((e) => e.toJson()).toList();
    await _prefs!.setString(_historyKey, jsonEncode(jsonList));
  }

  /// Add a download history item
  void add({
    required String filename,
    required String url,
    required HistoryStatus status,
    String? errorMessage,
  }) {
    final item = DownloadHistoryItem(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      filename: filename,
      url: url,
      status: status,
      createdAt: DateTime.now(),
      errorMessage: errorMessage,
    );
    var newItems = [...state.items, item];
    
    // Enforce max 1000 items limit (remove oldest first - FIFO)
    while (newItems.length > _maxItems) {
      newItems.removeAt(0);
    }
    
    state = state.copyWith(items: newItems);
    _saveHistory();
  }

  /// Toggle sort order
  void toggleSort() {
    state = state.copyWith(sortDescending: !state.sortDescending);
  }

  /// Clear all history
  void clearAll() {
    state = state.copyWith(items: []);
    _saveHistory();
  }
}

/// Provider for extraction history
final historyProvider =
    StateNotifierProvider<HistoryNotifier, HistoryState>((ref) {
  // This will be overridden in main.dart with actual SharedPreferences
  return HistoryNotifier(null);
});

/// Provider for download history
final downloadHistoryProvider =
    StateNotifierProvider<DownloadHistoryNotifier, DownloadHistoryState>((ref) {
  // This will be overridden in main.dart with actual SharedPreferences
  return DownloadHistoryNotifier(null);
});
