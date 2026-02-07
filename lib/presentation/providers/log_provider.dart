import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/services/log_service.dart';

/// Provider for log service
final logServiceProvider = Provider<LogService>((ref) {
  final service = LogService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Provider for log stream
final logStreamProvider = StreamProvider<LogEntry>((ref) {
  final service = ref.watch(logServiceProvider);
  return service.stream;
});

/// Provider for current log entries
final logEntriesProvider = Provider<List<LogEntry>>((ref) {
  final service = ref.watch(logServiceProvider);
  return service.entries;
});
