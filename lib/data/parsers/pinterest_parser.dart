import 'dart:convert';
import '../models/author.dart';
import '../models/media_result.dart';
import '../models/pin_item.dart';
import '../models/pinterest_config.dart';
import '../models/user_pins_result.dart';

// PORTED from my Node.js CLI tool
// - https://github.com/motebaya/pinterest-js
class PinterestParser {
  PinterestParser._();
  
  // REGEX Patterns
  static final RegExp _appVersionPattern =
      RegExp(r'''['"]appVersion['"]\s*:\s*['"](\w+?)['"]''');
  static final RegExp _userId1Pattern = RegExp(
      r'''['"]profile_cover['"]\s*:\s*\{['"]id['"]\s*:\s*['"](\d+?)['"]''',
      caseSensitive: false);
  static final RegExp _userId2Pattern = RegExp(r'/users/(\d+)/pins');
  static final RegExp _userId3Pattern = RegExp(
      r'<script\s+[^>]*id="__PWS_INITIAL_PROPS__"\s+[^>]*type="application/json"[^>]*>(.*?)</script>',
      dotAll: true);
  static final RegExp _mediaDataPattern = RegExp(
      r'window\.__PWS_RELAY_REGISTER_COMPLETED_REQUEST__\(\s*"(?<payload>(?:\\.|[^"\\])*)"\s*,\s*(?<json>\{[\s\S]*?\})\s*\)\s*;?');

  /// Extract Pinterest config (appVersion and userId) from profile HTML
  static PinterestConfig? parseConfig(String html) {
    // Extract appVersion
    final appVersionMatch = _appVersionPattern.firstMatch(html);
    if (appVersionMatch == null) return null;
    final appVersion = appVersionMatch.group(1);
    if (appVersion == null) return null;

    // Try multiple strategies for userId
    String? userId;

    // Strategy 1: profile_cover
    final userId1Match = _userId1Pattern.firstMatch(html);
    if (userId1Match != null) {
      userId = userId1Match.group(1);
    }

    // Strategy 2: /users/ID/pins
    if (userId == null) {
      final userId2Match = _userId2Pattern.firstMatch(html);
      if (userId2Match != null) {
        userId = userId2Match.group(1);
      }
    }

    // Strategy 3: __PWS_INITIAL_PROPS__ JSON
    if (userId == null) {
      final userId3Match = _userId3Pattern.firstMatch(html);
      if (userId3Match != null) {
        try {
          final jsonStr = userId3Match.group(1);
          if (jsonStr != null) {
            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            final users =
                json['initialReduxState']?['users'] as Map<String, dynamic>?;
            if (users != null) {
              userId = users.keys.firstWhere(
                (k) => k.isNotEmpty,
                orElse: () => '',
              );
            }
          }
        } catch (_) {}
      }
    }

    if (userId == null || userId.isEmpty) return null;

    return PinterestConfig(appVersion: appVersion, userId: userId);
  }

  /// Parses the JSON response from the Pinterest user pins API.
  ///
  /// [response] is the raw JSON map returned by the Pinterest API.
  /// [existingAuthor] is an optional [Author] object to be associated with the parsed pins.
  ///
  /// Returns a [UserPinsResult] containing the list of pins and pagination data,
  /// or `null` if the response structure is invalid or missing required fields.
  static UserPinsResult? parseUserPinsResponse(Map<String, dynamic> response, {Author? existingAuthor}) {
    try {
      final resourceResponse =
          response['resource_response'] as Map<String, dynamic>?;
      if (resourceResponse == null) {
        print('[PARSER] No resource_response in response');
        return null;
      }

      // Check status, code, and message like Node.js does
      final status = resourceResponse['status'] as String?;
      final code = resourceResponse['code'];
      final message = resourceResponse['message'] as String?;
      
      // Node.js: status.toLowerCase() !== 'success' && code !== 0 && message.toLowerCase() !== 'ok'
      if (status?.toLowerCase() != 'success') {
        print('[PARSER] API returned non-success status: $status, code: $code, message: $message');
        return null;
      }

      final data = resourceResponse['data'] as List<dynamic>?;
      
      // Get bookmark for pagination - check if it exists (Node.js line 219)
      final bookmark = resourceResponse['bookmark'] as String?;
      
      // Empty data is valid - it means no more pages
      // But we need author info. If data is empty and no existing author, return null
      if (data == null || data.isEmpty) {
        print('[PARSER] Empty data array in response');
        // Return empty result with no bookmark (signals end of pagination)
        if (existingAuthor != null) {
          return UserPinsResult.fromApiResponse(
            author: existingAuthor,
            pins: [],
            bookmark: null, // No more pages
          );
        }
        return null;
      }

      // Parse pins exactly like Node.js:
      // { title, images: i?.images ?? [], videos: i?.videos ?? [], pinId: i.id, uploadDate: i.created_at }
      final pins = <PinItem>[];
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          pins.add(PinItem.fromUserPinJson(item));
        }
      }

      // Extract author from first pin's native_creator
      Author? author = existingAuthor;
      if (author == null) {
        final firstItem = data.first as Map<String, dynamic>?;
        final nativeCreator =
            firstItem?['native_creator'] as Map<String, dynamic>?;
        if (nativeCreator != null) {
          author = Author(
            username: nativeCreator['username'] as String? ?? '',
            name: nativeCreator['full_name'] as String? ?? '',
            userId: nativeCreator['id']?.toString() ?? '',
          );
        }
      }

      if (author == null) {
        print('[PARSER] Could not extract author from response');
        return null;
      }

      return UserPinsResult.fromApiResponse(
        author: author,
        pins: pins,
        bookmark: bookmark,
      );
    } catch (e) {
      print('[PARSER] Exception parsing user pins: $e');
      return null;
    }
  }

  /// Parse image data from single pin page HTML
  /// Ported from Pinterest.getImages() with new regex
  /// Expected output format:
  /// {
  ///   "status": true,
  ///   "author": { "username", "name", "userId" },
  ///   "result": { "title", "url", "entityId" },
  ///   "message": "image found for -> {pinId}"
  /// }
  static MediaResult? parseImageData(String html, String pinId) {
    final match = _mediaDataPattern.firstMatch(html);
    if (match == null) return null;

    try {
      final jsonStr = match.namedGroup('json');
      if (jsonStr == null) return null;

      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final dataWrapper = json['data'] as Map<String, dynamic>?;
      if (dataWrapper == null) return null;

      // Get first key's data
      final firstKey = dataWrapper.keys.first;
      final pinData = dataWrapper[firstKey]?['data'] as Map<String, dynamic>?;
      if (pinData == null) return null;

      // Check for imageLargeUrl
      final imageUrl = pinData['imageLargeUrl'] as String?;
      if (imageUrl == null) return null;

      // Extract author info
      final pinner = pinData['pinner'] as Map<String, dynamic>?;
      final closeupAttribution = pinData['closeupAttribution'] as Map<String, dynamic>?;

      return MediaResult(
        author: Author(
          username: pinner?['username'] as String? ?? '-',
          name: closeupAttribution?['fullName'] as String? ?? '-',
          userId: pinner?['entityId'] as String? ?? '-',
        ),
        title: pinData['title'] as String? ?? '-',
        pinId: pinId,
        imageUrl: imageUrl,
        isVideo: false,
        message: 'image found for -> $pinId',
      );
    } catch (_) {
      return null;
    }
  }

  /// Parse video data from single pin page HTML
  /// Ported from Pinterest.getVideos() with new regex
  /// Expected output format:
  /// {
  ///   "status": true,
  ///   "author": { "username", "name", "userId" },
  ///   "result": { "thumbnail", "url" }
  /// }
  static MediaResult? parseVideoData(String html, String pinId) {
    final match = _mediaDataPattern.firstMatch(html);
    if (match == null) return null;

    try {
      final jsonStr = match.namedGroup('json');
      if (jsonStr == null) return null;

      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final dataWrapper = json['data'] as Map<String, dynamic>?;
      if (dataWrapper == null) return null;

      // Get first key's data
      final firstKey = dataWrapper.keys.first;
      final pinData = dataWrapper[firstKey]?['data'] as Map<String, dynamic>?;
      if (pinData == null) return null;

      // Navigate to video data: storyPinData.pages[0].blocks[0].videoDataV2
      final storyPinData = pinData['storyPinData'] as Map<String, dynamic>?;
      if (storyPinData == null) return null;

      final pages = storyPinData['pages'] as List<dynamic>?;
      if (pages == null || pages.isEmpty) return null;

      final blocks = (pages[0] as Map<String, dynamic>?)?['blocks'] as List<dynamic>?;
      if (blocks == null || blocks.isEmpty) return null;

      final videoDataV2 = (blocks[0] as Map<String, dynamic>?)?['videoDataV2'] as Map<String, dynamic>?;
      if (videoDataV2 == null) return null;

      // Get 720P video
      final videoList720P = videoDataV2['videoList720P'] as Map<String, dynamic>?;
      if (videoList720P == null) return null;

      final v720P = videoList720P['v720P'] as Map<String, dynamic>?;
      if (v720P == null) return null;

      final videoUrl = v720P['url'] as String?;
      final thumbnail = v720P['thumbnail'] as String?;

      if (videoUrl == null) return null;

      // Extract author info
      final pinner = pinData['pinner'] as Map<String, dynamic>?;
      final closeupAttribution = pinData['closeupAttribution'] as Map<String, dynamic>?;

      return MediaResult(
        author: Author(
          username: pinner?['username'] as String? ?? '-',
          name: closeupAttribution?['fullName'] as String? ?? '-',
          userId: pinner?['entityId'] as String? ?? '-',
        ),
        title: pinData['title'] as String? ?? '-',
        pinId: pinId,
        videoUrl: videoUrl,
        thumbnail: thumbnail,
        isVideo: true,
        message: 'video found for -> $pinId',
      );
    } catch (_) {
      return null;
    }
  }

  /// Try to get both image and video data from a pin
  /// Returns MediaResult with both imageUrl and videoUrl if available
  static MediaResult? parseMediaData(String html, String pinId) {
    final match = _mediaDataPattern.firstMatch(html);
    if (match == null) return null;

    try {
      final jsonStr = match.namedGroup('json');
      if (jsonStr == null) return null;

      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final dataWrapper = json['data'] as Map<String, dynamic>?;
      if (dataWrapper == null) return null;

      // Get first key's data
      final firstKey = dataWrapper.keys.first;
      final pinData = dataWrapper[firstKey]?['data'] as Map<String, dynamic>?;
      if (pinData == null) return null;

      // Extract entityId from pinData
      final entityId = pinData['entityId'] as String?;

      // Extract author info
      final pinner = pinData['pinner'] as Map<String, dynamic>?;
      final closeupAttribution = pinData['closeupAttribution'] as Map<String, dynamic>?;

      final author = Author(
        username: pinner?['username'] as String? ?? '-',
        name: closeupAttribution?['fullName'] as String? ?? '-',
        userId: pinner?['entityId'] as String? ?? '-',
      );

      // Try to get image URL
      final imageUrl = pinData['imageLargeUrl'] as String?;

      // Try to get video data
      String? videoUrl;
      String? thumbnail;
      bool hasVideo = false;

      final storyPinData = pinData['storyPinData'] as Map<String, dynamic>?;
      if (storyPinData != null) {
        final pages = storyPinData['pages'] as List<dynamic>?;
        if (pages != null && pages.isNotEmpty) {
          final blocks = (pages[0] as Map<String, dynamic>?)?['blocks'] as List<dynamic>?;
          if (blocks != null && blocks.isNotEmpty) {
            final videoDataV2 = (blocks[0] as Map<String, dynamic>?)?['videoDataV2'] as Map<String, dynamic>?;
            if (videoDataV2 != null) {
              final videoList720P = videoDataV2['videoList720P'] as Map<String, dynamic>?;
              if (videoList720P != null) {
                final v720P = videoList720P['v720P'] as Map<String, dynamic>?;
                if (v720P != null) {
                  videoUrl = v720P['url'] as String?;
                  thumbnail = v720P['thumbnail'] as String?;
                  hasVideo = videoUrl != null;
                }
              }
            }
          }
        }
      }

      // If neither image nor video found, return null
      if (imageUrl == null && videoUrl == null) return null;

      return MediaResult(
        author: author,
        title: pinData['title'] as String? ?? '-',
        pinId: pinId,
        entityId: entityId, // Added entityId
        imageUrl: imageUrl,
        videoUrl: videoUrl,
        thumbnail: thumbnail,
        isVideo: hasVideo,
        hasImage: imageUrl != null,
        hasVideoContent: hasVideo,
        rawJson: pinData, // Store raw JSON for metadata export
        message: hasVideo 
            ? 'video found for -> $pinId' 
            : 'image found for -> $pinId',
      );
    } catch (_) {
      return null;
    }
  }
}
