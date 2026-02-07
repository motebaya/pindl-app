import 'dart:math';

/// Generates trace IDs for Pinterest API requests
/// Ported from Node.js Utils.getTraceId()
class TraceIdGenerator {
  static final Random _random = Random();

  TraceIdGenerator._();

  /// Generate a random 16-character hex string for x-b3 headers
  /// Used for trace ID, span ID, and parent span ID spoofing
  static String generate() {
    // Generate random number up to MAX_SAFE_INTEGER equivalent
    final value = _random.nextInt(0x7FFFFFFF) * 0x100000000 + _random.nextInt(0xFFFFFFFF);
    return value.toRadixString(16).padLeft(16, '0').substring(0, 16);
  }

  /// Generate a set of trace headers for Pinterest API
  static Map<String, String> generateHeaders() {
    return {
      'x-b3-traceid': generate(),
      'x-b3-spanid': generate(),
      'x-b3-parentspanid': generate(),
      'x-b3-flags': '0',
    };
  }
}
