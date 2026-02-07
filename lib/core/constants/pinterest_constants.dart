/// Pinterest API constants ported from Node.js Helper.js
class PinterestConstants {
  PinterestConstants._();

  /// Base Pinterest host URL
  static const String host = 'https://id.pinterest.com';

  /// Short URL host for pin.it links
  static const String shortHost = 'https://pin.it';

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
}
