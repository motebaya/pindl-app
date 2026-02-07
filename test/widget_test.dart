// Basic Flutter widget tests for PinDL app

import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/utils/pin_url_validator.dart';
import 'package:pindl/core/utils/format_utils.dart';
import 'package:pindl/core/utils/trace_id_generator.dart';

void main() {
  group('PinUrlValidator', () {
    test('parses long Pinterest URL correctly', () {
      final result = PinUrlValidator.parse(
          'https://www.pinterest.com/pin/123456789012345678/');
      expect(result, isNotNull);
      expect(result!.format, 'long');
      expect(result.id, '123456789012345678');
    });

    test('parses short pin.it URL correctly', () {
      final result = PinUrlValidator.parse('https://pin.it/abc123XYZ');
      expect(result, isNotNull);
      expect(result!.format, 'short');
      expect(result.id, 'abc123XYZ');
    });

    test('parses pin ID only correctly', () {
      final result = PinUrlValidator.parse('123456789012345678');
      expect(result, isNotNull);
      expect(result!.format, 'id');
      expect(result.id, '123456789012345678');
    });

    test('detects username input', () {
      expect(PinUrlValidator.isUsername('username123'), isTrue);
      expect(PinUrlValidator.isUsername('@username123'), isTrue);
      expect(PinUrlValidator.isUsername('user_name'), isTrue);
    });

    test('normalizes username', () {
      expect(PinUrlValidator.normalizeUsername('@username'), 'username');
      expect(PinUrlValidator.normalizeUsername('username'), 'username');
    });
  });

  group('FormatUtils', () {
    test('formats file sizes correctly', () {
      expect(FormatUtils.humanSize(0), '0 B');
      expect(FormatUtils.humanSize(1024), contains('KB'));
      expect(FormatUtils.humanSize(1048576), contains('MB'));
    });

    test('sanitizes filenames correctly', () {
      expect(FormatUtils.sanitizeFilename('file<name>.jpg'), 'filename.jpg');
      expect(FormatUtils.sanitizeFilename('normal.jpg'), 'normal.jpg');
    });
  });

  group('TraceIdGenerator', () {
    test('generates 16-character hex string', () {
      final id = TraceIdGenerator.generate();
      expect(id.length, 16);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(id), isTrue);
    });

    test('generates different IDs each time', () {
      final id1 = TraceIdGenerator.generate();
      final id2 = TraceIdGenerator.generate();
      expect(id1, isNot(equals(id2)));
    });
  });
}
