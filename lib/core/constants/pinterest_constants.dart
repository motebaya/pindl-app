/// Pinterest API constants ported from Node.js Helper.js
class PinterestConstants {
  PinterestConstants._();

  /// Base Pinterest host URL
  static const String host = 'https://id.pinterest.com';

  /// Short URL host for pin.it links
  static const String shortHost = 'https://pin.it';

  /// Pin-page hosts attempted in order for single-pin extraction.
  ///
  /// 3.1.1 device evidence: the SSR relay payload is host-specific — pin
  /// 3025924747245513 ships ZERO relay invocations on `id.pinterest.com/pin/…`
  /// but two on `www.pinterest.com/pin/…`, which surfaced as `E_NO_DATA` for a
  /// public pin. See reports/3.1.1-device-bugfix.md.
  static const List<String> pinHosts = [host, 'https://www.pinterest.com'];

  /// User agent for requests
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

  /// Chrome version for sec-ch-ua header
  static const String chromeVersion = '136.0.7049.115';

  /// Sec-CH-UA header value
  static const String secChUa =
      '"Google Chrome";v="136.0.7049.115", "Not-A.Brand";v="8.0.0.0", "Chromium";v="136.0.7049.115"';

  /// Generate oembed URL for a pin
  static String oembedUrl(String pinId) {
    return '$host/oembed.json?url=$host/pin/$pinId/&ref=oembed-discovery';
  }

  /// User pins resource endpoint
  static const String userPinsResource = '/resource/UserActivityPinsResource/get/';

  /// Boards (user.boards) resource endpoint — Phase 09 (live-validated shape;
  /// see lib/data/pinterest/resources.dart for the evidence basis).
  static const String boardsResource = '/resource/BoardsResource/get/';

  /// Board sections (board.sections) resource endpoint — Phase 09.
  static const String boardSectionsResource = '/resource/BoardSectionsResource/get/';

  /// Board section pins (board.sectionPins) resource endpoint — Phase 09.
  static const String boardSectionPinsResource = '/resource/BoardSectionPinsResource/get/';

  /// Whole-board feed (board.pins) resource endpoint — Phase 09.
  static const String boardFeedResource = '/resource/BoardFeedResource/get/';
}
