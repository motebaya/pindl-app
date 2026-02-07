import 'dart:async';
import '../../core/theme/app_colors.dart';
import 'package:flutter/material.dart';

/// Log levels for the console
enum LogLevel {
  init,
  validate,
  config,
  fetch,
  parse,
  queue,
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

  LogService({this.maxEntries = 500});

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
