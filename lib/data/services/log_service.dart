import 'dart:async';
import '../../core/theme/app_colors.dart';
import 'package:flutter/material.dart';

/// Log levels for the console.
///
/// `debug` is the verbose-only level (3.1.1+8). Before it existed there was no
/// level a debug line could even be filed under, so the "Verbose logs" toggle
/// could not add anything to the console no matter what it was wired to.
enum LogLevel {
  init,
  validate,
  config,
  fetch,
  parse,
  queue,
  debug,
  downloading,
  saved,
  skipped,
  error,
  interrupted,
  complete,
}

/// A single log entry
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  factory LogEntry.now(LogLevel level, String message) {
    return LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
    );
  }

  /// Get color for this log level
  Color get color {
    switch (level) {
      case LogLevel.init:
        return AppColors.consoleInit;
      case LogLevel.validate:
        return AppColors.consoleValidate;
      case LogLevel.config:
        return AppColors.consoleConfig;
      case LogLevel.fetch:
        return AppColors.consoleFetch;
      case LogLevel.parse:
        return AppColors.consoleParse;
      case LogLevel.queue:
        return AppColors.consoleQueue;
      case LogLevel.debug:
        return AppColors.consoleDebug;
      case LogLevel.downloading:
        return AppColors.consoleDownloading;
      case LogLevel.saved:
        return AppColors.consoleSaved;
      case LogLevel.skipped:
        return AppColors.consoleSkipped;
      case LogLevel.error:
        return AppColors.consoleError;
      case LogLevel.interrupted:
        return AppColors.consoleInterrupted;
      case LogLevel.complete:
        return AppColors.consoleComplete;
    }
  }

  @override
  String toString() {
    final time = '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
    return '[$time] [${level.name.toUpperCase()}] $message';
  }
}

/// Log service for managing console output
class LogService {
  final int maxEntries;
  final List<LogEntry> _entries = [];
  final _controller = StreamController<LogEntry>.broadcast();

  /// Verbose gate (3.1.1+8). Only [debug] entries are gated: every other level
  /// is emitted unconditionally, so turning verbose OFF keeps the console
  /// concise without hiding a single error, warning or progress line, and
  /// turning it ON can only ever ADD lines.
  ///
  /// Set from the "Verbose logs" setting by the operation that starts the work
  /// (JobNotifier.startExtraction/startDownload/startBoardDownload/
  /// discoverBoards), the same way the extractor's own verbose flag is set.
  bool verbose;

  LogService({this.maxEntries = 500, this.verbose = false});

  /// Stream of log entries
  Stream<LogEntry> get stream => _controller.stream;

  /// All current entries
  List<LogEntry> get entries => List.unmodifiable(_entries);

  /// Log a message
  void log(LogLevel level, String message) {
    final entry = LogEntry.now(level, message);
    _entries.add(entry);

    // Trim if over max
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }

    _controller.add(entry);
  }

  /// Convenience methods
  void init(String message) => log(LogLevel.init, message);
  void validate(String message) => log(LogLevel.validate, message);
  void config(String message) => log(LogLevel.config, message);
  void fetch(String message) => log(LogLevel.fetch, message);
  void parse(String message) => log(LogLevel.parse, message);
  void queue(String message) => log(LogLevel.queue, message);

  /// Verbose-only diagnostic detail. Dropped entirely while [verbose] is off —
  /// never queued, never streamed, never trimmed against [maxEntries].
  void debug(String message) {
    if (!verbose) return;
    log(LogLevel.debug, message);
  }
  void downloading(String message) => log(LogLevel.downloading, message);
  void saved(String message) => log(LogLevel.saved, message);
  void skipped(String message) => log(LogLevel.skipped, message);
  void error(String message) => log(LogLevel.error, message);
  void interrupted(String message) => log(LogLevel.interrupted, message);
  void complete(String message) => log(LogLevel.complete, message);

  /// Clear all entries
  void clear() {
    _entries.clear();
  }

  /// Dispose resources
  void dispose() {
    _controller.close();
  }
}
