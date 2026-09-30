import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Loads test fixtures from test/fixtures/.
///
/// All fixtures are synthetic (no real user data) and versioned with the repo
/// so the suite runs offline and deterministically (Phase 02 contract).
class Fixtures {
  static String _load(String relPath) {
    final file = File('test/fixtures/$relPath');
    if (!file.existsSync()) {
      fail('Missing fixture: test/fixtures/$relPath');
    }
    return file.readAsStringSync();
  }

  // HTML fixtures
  static String profilePage() => _load('html/profile_page.html');
  static String profileNoConfig() => _load('html/profile_no_config.html');
  static String pinImage() => _load('html/pin_image.html');
  static String pinVideo() => _load('html/pin_video.html');
  static String pinNotFound() => _load('html/pin_notfound.html');
  static String pinStubOnly() => _load('html/pin_stub_only.html');
  static String pinStubThenRich() => _load('html/pin_stub_then_rich.html');
  static String pinFlatImages() => _load('html/pin_flat_images.html');
  static String pinCarousel() => _load('html/pin_carousel.html');

  // API fixtures
  static Map<String, dynamic> userPinsPage1() =>
      jsonDecode(_load('api/user_pins_page1.json')) as Map<String, dynamic>;
  static Map<String, dynamic> userPinsLast() =>
      jsonDecode(_load('api/user_pins_last.json')) as Map<String, dynamic>;
  static Map<String, dynamic> userPinsEmpty() =>
      jsonDecode(_load('api/user_pins_empty.json')) as Map<String, dynamic>;
  static Map<String, dynamic> userPinsBadStatus() =>
      jsonDecode(_load('api/user_pins_badstatus.json')) as Map<String, dynamic>;

  // Board fixtures (Phase 09 — synthetic, shapes mirror live-validated
  // registry rows; see lib/data/pinterest/resources.dart)
  static Map<String, dynamic> boardsPage1() =>
      jsonDecode(_load('api/boards_page1.json')) as Map<String, dynamic>;
  static Map<String, dynamic> boardSectionsPage1() =>
      jsonDecode(_load('api/board_sections_page1.json')) as Map<String, dynamic>;

  // HLS fixtures
  static String masterVariants() => _load('hls/master_variants.m3u8');
  static String masterMuxed() => _load('hls/master_muxed.m3u8');
  static String mediaPlaylist() => _load('hls/media_playlist.m3u8');

  // Metadata fixtures
  static Map<String, dynamic> v1UserMetadata() =>
      jsonDecode(_load('metadata/v1_user_metadata.json')) as Map<String, dynamic>;
}
