import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/models/pin_item.dart';

import '../helpers/fixture_loader.dart';

/// Characterization: PinItem.fromUserPinJson media selection.
/// PHASE 07 FLIP (07.2, gate G2 — deliberate, documented): rendition ranking
/// delegated to core/media/video_selection.dart (JS MP4_PREFERENCE port):
/// MP4 720P→960P→480P→360P, then any MP4, then HLS V_HLSV4 over
/// V_HLSV3_MOBILE (legacy code preferred HLSV3 — intended change, release-noted).
void main() {
  group('image pin', () {
    test('images.orig.url -> imageUrl, hasVideo false', () {
      final pin = PinItem.fromUserPinJson({
        'id': '111111111111111111',
        'title': 'img',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': [],
      });
      expect(pin.hasImage, isTrue);
      expect(pin.imageUrl, 'https://i.pinimg.com/originals/a.jpg');
      expect(pin.hasVideo, isFalse);
      expect(pin.videoUrl, isNull);
    });
  });

  group('direct MP4 (V_720P .mp4)', () {
    test('selected without conversion', () {
      final pin = PinItem.fromUserPinJson({
        'id': '222222222222222222',
        'title': 'mp4',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': {'video_list': {'V_720P': {'url': 'https://v1.pinimg.com/v.mp4'}}},
      });
      expect(pin.hasVideo, isTrue);
      expect(pin.videoUrl!.url, 'https://v1.pinimg.com/v.mp4');
      expect(pin.videoUrl!.quality, '720P');
      expect(pin.videoUrl!.needConvert, isFalse);
      expect(pin.videoUrl!.isHls, isFalse);
    });
  });

  group('HLS-only (V_HLSV3_MOBILE / V_HLSV4)', () {
    test('V_HLSV4 preferred (Phase 07 flip: JS ranks V_HLSV4 first), needConvert', () {
      final pin = PinItem.fromUserPinJson({
        'id': '333333333333333333',
        'title': 'hls3',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': {'video_list': {
          'V_HLSV3_MOBILE': {'url': 'https://v.pinimg.com/hls3.m3u8'},
          'V_HLSV4': {'url': 'https://v.pinimg.com/hls4.m3u8'},
        }},
      });
      expect(pin.hasVideo, isTrue);
      // FLIPPED in Phase 07 (07.2): was V_HLSV3_MOBILE-first; JS parity and
      // the audit mark V_HLSV4 the newer master (audits/parity/media.md).
      expect(pin.videoUrl!.url, 'https://v.pinimg.com/hls4.m3u8');
      expect(pin.videoUrl!.quality, 'HLS');
      expect(pin.videoUrl!.needConvert, isTrue);
      expect(pin.videoUrl!.isHls, isTrue);
    });

    test('V_HLSV4 used when V_HLSV3_MOBILE absent', () {
      final pin = PinItem.fromUserPinJson({
        'id': '333333333333333334',
        'title': 'hls4',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': {'video_list': {'V_HLSV4': {'url': 'https://v.pinimg.com/hls4.m3u8'}}},
      });
      expect(pin.videoUrl!.url, 'https://v.pinimg.com/hls4.m3u8');
      expect(pin.videoUrl!.needConvert, isTrue);
    });
  });

  group('V_720P without .mp4 extension', () {
    test('m3u8 720P marked needConvert', () {
      final pin = PinItem.fromUserPinJson({
        'id': '444444444444444444',
        'title': 'hls720',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': {'video_list': {'V_720P': {'url': 'https://v1.pinimg.com/720p.m3u8'}}},
      });
      expect(pin.videoUrl!.url, 'https://v1.pinimg.com/720p.m3u8');
      expect(pin.videoUrl!.needConvert, isTrue);
    });
  });

  group('story_pin_data fallback (videos null)', () {
    test('extracts video_list from story_pin_data.pages[0].blocks[0].video', () {
      final pin = PinItem.fromUserPinJson({
        'id': '555555555555555555',
        'title': 'story',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': null,
        'story_pin_data': {
          'pages': [
            {'blocks': [
              {'video': {'video_list': {'V_720P': {'url': 'https://v1.pinimg.com/story.mp4'}}}},
            ]},
          ],
        },
      });
      expect(pin.hasVideo, isTrue);
      expect(pin.videoUrl!.url, 'https://v1.pinimg.com/story.mp4');
      expect(pin.videoUrl!.needConvert, isFalse);
    });
  });

  group('any-quality fallback', () {
    test('unknown variant key used when known ones absent', () {
      final pin = PinItem.fromUserPinJson({
        'id': '666666666666666666',
        'title': 'other',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': {'video_list': {'V_EXP': {'url': 'https://v1.pinimg.com/exp.mp4'}}},
      });
      expect(pin.hasVideo, isTrue);
      expect(pin.videoUrl!.quality, 'V_EXP');
      expect(pin.videoUrl!.needConvert, isFalse);
    });
  });

  group('upload date parsing', () {
    test('RFC 2822 date parsed', () {
      final pins = PinterestParserBridge.parse(Fixtures.userPinsPage1());
      final img = pins.firstWhere((p) => p.pinId == '111111111111111111');
      expect(img.uploadDate, DateTime.utc(2025, 12, 11, 4, 4, 36));
    });

    test('ISO 8601 fallback parsed', () {
      // CHARACTERIZATION (defect, Phase 03 target): _parseRfc2822Date RETURNS null
      // on non-RFC input instead of throwing, so the catch-based ISO fallback in
      // PinItem.fromUserPinJson is unreachable and uploadDate stays null for
      // ISO-only created_at values. Pinned as current behavior; Phase 03 will
      // flip this pin deliberately when fixing date fallback.
      final pin = PinItem.fromUserPinJson({
        'id': '777777777777777777',
        'title': 'iso',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': [],
        'created_at': '2025-12-11T04:04:36Z',
      });
      expect(pin.uploadDate, isNull); // defect pin: ISO fallback unreachable
    });
  });

  group('round-trip (toJson/fromJson)', () {
    test('video pin survives serialization', () {
      final pin = PinItem.fromUserPinJson({
        'id': '222222222222222222',
        'title': 'mp4',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/a.jpg'}},
        'videos': {'video_list': {'V_720P': {'url': 'https://v1.pinimg.com/v.mp4'}}},
      });
      final restored = PinItem.fromJson(pin.toJson());
      expect(restored, equals(pin)); // Equatable
    });
  });
}

/// Bridge to reuse the API fixture without re-importing the parser here.
class PinterestParserBridge {
  static List<PinItem> parse(Map<String, dynamic> response) {
    // ignore: avoid_dynamic_calls
    final data = (response['resource_response'] as Map)['data'] as List;
    return data
        .whereType<Map<String, dynamic>>()
        .map(PinItem.fromUserPinJson)
        .toList();
  }
}
