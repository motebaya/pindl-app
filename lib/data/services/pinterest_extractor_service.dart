import 'dart:async';
import 'dart:convert';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import '../../core/constants/pinterest_constants.dart';
import '../../core/exceptions/pinterest_exception.dart';
import '../../core/utils/pin_url_validator.dart';
import '../../core/utils/trace_id_generator.dart';
import '../models/author.dart';
import '../models/media_result.dart';
import '../models/pin_item.dart';
import '../models/pinterest_config.dart';
import '../models/user_pins_result.dart';
import '../parsers/pinterest_parser.dart';

/// Pinterest extraction service
/// Ported from Node.js Pinterest.js
class PinterestExtractorService {
  final Dio _dio;
  bool verbose;
  final CookieJar _cookieJar;
  
  /// Default max pages (can be overridden per request)
  static const int defaultMaxPages = 50;

  PinterestConfig? _config;

  PinterestExtractorService({
    Dio? dio,
    this.verbose = false,
  })  : _cookieJar = CookieJar(),
        _dio = dio ?? Dio() {
    _initializeDio();
  }

  void _initializeDio() {
    _dio.options = BaseOptions(
      baseUrl: PinterestConstants.host,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
      headers: {
        'User-Agent': PinterestConstants.userAgent,
      },
      followRedirects: true,
      maxRedirects: 5,
    );

    // Add cookie manager - this persists cookies across requests like axios.create() does
    _dio.interceptors.add(CookieManager(_cookieJar));

    if (verbose) {
      _dio.interceptors.add(LogInterceptor(
        requestBody: false,
        responseBody: false,
        logPrint: (o) => print('[DIO] $o'),
      ));
    }
  }

  /// Get headers for Pinterest API calls with trace ID spoofing
  Map<String, String> _getApiHeaders(String sourceUrl) {
    final traceHeaders = TraceIdGenerator.generateHeaders();
    return {
      ...traceHeaders,
      'x-requested-with': 'XMLHttpRequest',
      'x-pinterest-source-url': sourceUrl,
      'x-pinterest-appstate': 'active',
      'x-pinterest-pws-handler': 'www/[username].js',
      if (_config != null) 'x-app-version': _config!.appVersion,
      'accept': 'application/json, text/javascript, */*, q=0.01',
      'sec-ch-ua-full-version-list': PinterestConstants.secChUa,
      'sec-ch-ua-platform': 'Windows',
      'sec-fetch-site': 'same-origin',
      'sec-fetch-mode': 'cors',
      'sec-fetch-dest': 'empty',
      'referer': '${PinterestConstants.host}/',
      'accept-encoding': 'gzip, deflate',
      'accept-language': 'en-US,en;q=0.9',
    };
  }

  /// Get config info (appVersion and userId) from profile page
  /// Ported from Pinterest.getConfigInfo()
  Future<PinterestConfig> getConfigInfo({
    required String username,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get<String>(
        '/$username',
        cancelToken: cancelToken,
      );

      if (response.data == null) {
        throw ExtractionException('Empty response from profile page');
      }

      final config = PinterestParser.parseConfig(response.data!);
      if (config == null) {
        throw ExtractionException(
            'Could not extract config from profile page, Make sure you enter the correct username and it is publicly visible.');
      }

      _config = config;
      
      print('[INFO] appversion::${config.appVersion}');
      print('[INFO] userid::${config.userId}');
      
      return config;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw CancelledException();
      }
      throw NetworkException(
        'Failed to fetch profile: ${e.message}',
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  /// Get user pins with pagination
  /// Ported from Pinterest.getUserPin() - uses iterative loop with proper pagination
  /// [maxPages] - Maximum pages to fetch (default: 50, max: 100)
  Future<UserPinsResult> getUserPins({
    required String username,
    String? bookmark,
    int maxPages = defaultMaxPages,
    CancelToken? cancelToken,
    void Function(int currentCount, int currentPage, int maxPage)? onProgress,
  }) async {
    // Clamp maxPages to valid range
    final effectiveMaxPages = maxPages.clamp(1, 100);
    
    // Get config if not already fetched
    if (_config == null) {
      await getConfigInfo(username: username, cancelToken: cancelToken);
    }

    // Accumulated data (like Node.js this.userData)
    final List<PinItem> allPins = [];
    Author? author;
    String? currentBookmark = bookmark;
    int currentPage = 0;
    int consecutiveEmptyPages = 0;

    // Pagination loop
    while (currentPage < effectiveMaxPages) {
      currentPage++;
      
      // Fetch single page
      final pageData = await _fetchSinglePage(
        username: username,
        bookmark: currentBookmark,
        cancelToken: cancelToken,
      );
      
      // Check if request failed completely
      if (pageData == null) {
        if (allPins.isEmpty) {
          throw ParseException('Failed to parse user pins response');
        }
        // We have some pins, return what we have
        print('[INFO] no more page found for $username with last length: ${allPins.length}');
        break;
      }
      
      final List<dynamic> data = pageData['data'] ?? [];
      final String? nextBookmark = pageData['bookmark'];
      final Author? pageAuthor = pageData['author'];
      
      // Set author from first page with data (like Node.js line 211-217)
      if (author == null && pageAuthor != null) {
        author = pageAuthor;
      }
      
      // Check if data is empty
      if (data.isEmpty) {
        consecutiveEmptyPages++;
        print('[PARSER] Empty data array in response');
        
        // Safety: if bookmark exists but data is empty, might be an issue
        if (nextBookmark != null && nextBookmark.isNotEmpty) {
          if (consecutiveEmptyPages >= 3) {
            print('[WARN] empty page received while bookmark exists; stopping to avoid infinite loop');
            break;
          }
          // Continue to next page
          currentBookmark = nextBookmark;
          continue;
        } else {
          // No bookmark and empty data = end of pagination
          break;
        }
      }
      
      // Reset empty page counter since we got data
      consecutiveEmptyPages = 0;
      
      // Parse pins from data array (like Node.js line 195-206)
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          allPins.add(PinItem.fromUserPinJson(item));
        }
      }
      
      // Log: "User pins fetched -> X, page: N/M" (enhanced with max pages)
      print('[INFO] User pins fetched -> ${allPins.length}, page: $currentPage/$effectiveMaxPages');
      
      // Notify progress with page info
      onProgress?.call(allPins.length, currentPage, effectiveMaxPages);
      
      // Check bookmark for next page (like Node.js line 219)
      // Node.js: if (page.bookmark !== undefined)
      if (nextBookmark != null && nextBookmark.isNotEmpty) {
        if (verbose) {
          print('[DEBUG] fetching next page -> $nextBookmark');
        }
        currentBookmark = nextBookmark;
      } else {
        // No more pages (like Node.js line 226-236)
        print('[INFO] no more page found for $username with last length: ${allPins.length}');
        break;
      }
    }
    
    // Safety guard hit
    if (currentPage >= effectiveMaxPages) {
      print('[WARN] Reached maximum page limit ($effectiveMaxPages); stopping pagination');
    }
    
    // Must have author to return result
    if (author == null) {
      throw ParseException('Could not extract author from any page');
    }
    
    return UserPinsResult.fromApiResponse(
      author: author,
      pins: allPins,
      bookmark: null, // Final result has no bookmark
    );
  }

  /// Fetch a single page and return raw parsed data
  /// Returns: { 'data': List, 'bookmark': String?, 'author': Author? }
  Future<Map<String, dynamic>?> _fetchSinglePage({
    required String username,
    String? bookmark,
    CancelToken? cancelToken,
  }) async {
    try {
      final data = {
        'options': {
          'exclude_add_pin_rep': true,
          'field_set_key': 'grid_item',
          'is_own_profile_pins': false,
          'redux_normalize_feed': true,
          'user_id': _config!.userId,
          'username': username,
          // Only add bookmarks if we have one (like Node.js line 144-147)
          if (bookmark != null) 'bookmarks': [bookmark],
        },
        'context': {},
      };

      final sourceUrl = '/$username/';
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Construct URL exactly like Node.js (line 152-157)
      final encodedSourceUrl = Uri.encodeComponent(sourceUrl);
      final encodedData = Uri.encodeComponent(jsonEncode(data));
      final url =
          '${PinterestConstants.userPinsResource}?source_url=$encodedSourceUrl&data=$encodedData&_=$timestamp';

      // Get response as String first
      final response = await _dio.get<String>(
        url,
        options: Options(
          headers: _getApiHeaders(sourceUrl),
          responseType: ResponseType.plain,
        ),
        cancelToken: cancelToken,
      );

      if (response.data == null || response.data!.isEmpty) {
        print('[ERROR] Empty response from pins API');
        return null;
      }

      // Debug: print first 200 chars
      if (verbose) {
        final preview = response.data!.length > 200
            ? response.data!.substring(0, 200)
            : response.data!;
        print('[DEBUG] Response preview: $preview');
      }

      // Parse JSON
      Map<String, dynamic> jsonResponse;
      try {
        jsonResponse = jsonDecode(response.data!) as Map<String, dynamic>;
      } on FormatException catch (e) {
        print('[ERROR] Response is not valid JSON: ${e.message}');
        return null;
      }

      // Extract resource_response
      final resourceResponse = jsonResponse['resource_response'] as Map<String, dynamic>?;
      if (resourceResponse == null) {
        print('[PARSER] No resource_response in response');
        return null;
      }

      // Check status (like Node.js line 183-193)
      final status = resourceResponse['status'] as String?;
      final code = resourceResponse['code'];
      final message = resourceResponse['message'] as String?;
      
      if (status?.toLowerCase() != 'success') {
        print('[PARSER] API returned non-success status: $status, code: $code, message: $message');
        return null;
      }

      // Get data array and bookmark
      final dataArray = resourceResponse['data'] as List<dynamic>? ?? [];
      final nextBookmark = resourceResponse['bookmark'] as String?;
      
      // Extract author from first item if available
      // Including avatar URL from native_creator.image_large_url
      Author? author;
      if (dataArray.isNotEmpty) {
        final firstItem = dataArray.first as Map<String, dynamic>?;
        final nativeCreator = firstItem?['native_creator'] as Map<String, dynamic>?;
        if (nativeCreator != null) {
          // Extract avatar URL: native_creator.image_large_url
          final avatarUrl = nativeCreator['image_large_url'] as String?;
          
          author = Author(
            username: nativeCreator['username'] as String? ?? '',
            name: nativeCreator['full_name'] as String? ?? '',
            userId: nativeCreator['id']?.toString() ?? '',
            avatarUrl: avatarUrl,
          );
        }
      }

      return {
        'data': dataArray,
        'bookmark': nextBookmark,
        'author': author,
      };
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw CancelledException();
      }

      // Provide more detailed error info
      String errorDetail = e.message ?? 'Unknown error';
      if (e.response != null) {
        errorDetail += ' (Status: ${e.response?.statusCode})';
      }
      print('[ERROR] Failed to fetch user pins: $errorDetail');
      return null;
    }
  }

  /// Get image from a single pin
  /// Ported from Pinterest.getImages()
  /// If no image but has video, returns thumbnail URL in imageUrl field
  Future<MediaResult> getPinImage({
    required String pinIdOrUrl,
    CancelToken? cancelToken,
  }) async {
    final pinInfo = PinUrlValidator.parse(pinIdOrUrl);
    if (pinInfo == null) {
      throw ValidationException('Invalid pin ID or URL: $pinIdOrUrl');
    }

    // Resolve short URL if needed
    String pinUrl = pinInfo.url;
    String pinId = pinInfo.id;

    if (pinInfo.isShortUrl) {
      final resolved = await _resolveShortUrl(pinInfo.url, cancelToken);
      pinUrl = resolved.url;
      pinId = resolved.id;
    }

    try {
      final response = await _dio.get<String>(
        pinUrl,
        cancelToken: cancelToken,
      );

      if (response.data == null) {
        throw ExtractionException('Empty response from pin page');
      }

      final result = PinterestParser.parseImageData(response.data!, pinId);
      if (result == null) {
        throw ParseException('No image found for pin: $pinId');
      }

      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw CancelledException();
      }
      throw NetworkException(
        'Failed to fetch pin: ${e.message}',
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  /// Get video from a single pin
  /// Ported from Pinterest.getVideos()
  Future<MediaResult> getPinVideo({
    required String pinIdOrUrl,
    CancelToken? cancelToken,
  }) async {
    final pinInfo = PinUrlValidator.parse(pinIdOrUrl);
    if (pinInfo == null) {
      throw ValidationException('Invalid pin ID or URL: $pinIdOrUrl');
    }

    // Resolve short URL if needed
    String pinUrl = pinInfo.url;
    String pinId = pinInfo.id;

    if (pinInfo.isShortUrl) {
      final resolved = await _resolveShortUrl(pinInfo.url, cancelToken);
      pinUrl = resolved.url;
      pinId = resolved.id;
    }

    try {
      final response = await _dio.get<String>(
        pinUrl,
        cancelToken: cancelToken,
      );

      if (response.data == null) {
        throw ExtractionException('Empty response from pin page');
      }

      final result = PinterestParser.parseVideoData(response.data!, pinId);
      if (result == null) {
        throw ParseException('No video found for pin: $pinId');
      }

      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw CancelledException();
      }
      throw NetworkException(
        'Failed to fetch pin: ${e.message}',
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  /// Get all media (image and video) from a single pin
  /// Returns MediaResult with both imageUrl and videoUrl if available
  Future<MediaResult> getPinMedia({
    required String pinIdOrUrl,
    CancelToken? cancelToken,
  }) async {
    final pinInfo = PinUrlValidator.parse(pinIdOrUrl);
    if (pinInfo == null) {
      throw ValidationException('Invalid pin ID or URL: $pinIdOrUrl');
    }

    // Resolve short URL if needed
    String pinUrl = pinInfo.url;
    String pinId = pinInfo.id;

    if (pinInfo.isShortUrl) {
      final resolved = await _resolveShortUrl(pinInfo.url, cancelToken);
      pinUrl = resolved.url;
      pinId = resolved.id;
    }

    try {
      final response = await _dio.get<String>(
        pinUrl,
        cancelToken: cancelToken,
      );

      if (response.data == null) {
        throw ExtractionException('Empty response from pin page');
      }

      final result = PinterestParser.parseMediaData(response.data!, pinId);
      if (result == null) {
        throw ParseException('No media found for pin: $pinId');
      }

      return result;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw CancelledException();
      }
      throw NetworkException(
        'Failed to fetch pin: ${e.message}',
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  /// Resolve short pin.it URL to the final redirect URL (raw, uncleaned).
  ///
  /// Returns the raw redirected URL string. Caller is responsible for cleaning
  /// via [PinUrlValidator.cleanRedirectedUrl].
  Future<String> resolveShortUrl(
      String shortUrl, CancelToken? cancelToken) async {
    try {
      final response = await _dio.get<String>(
        shortUrl,
        options: Options(
          followRedirects: true,
          maxRedirects: 5,
        ),
        cancelToken: cancelToken,
      );

      return response.realUri.toString();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw CancelledException();
      }
      throw NetworkException(
        'Failed to resolve short URL: ${e.message}',
        statusCode: e.response?.statusCode,
        originalError: e,
      );
    }
  }

  /// Resolve short pin.it URL to full Pinterest pin URL (legacy internal use).
  /// For pin URLs only — throws if resolved URL is not a pin.
  Future<PinUrlInfo> _resolveShortUrl(
      String shortUrl, CancelToken? cancelToken) async {
    final finalUrl = await resolveShortUrl(shortUrl, cancelToken);
    
    // Try cleaning first (handles /sent/ and query params)
    final cleaned = PinUrlValidator.cleanRedirectedUrl(finalUrl);
    if (cleaned != null && cleaned.type == 'pin') {
      final parsed = PinUrlValidator.parse(cleaned.value);
      if (parsed != null) return parsed;
    }
    
    // Fallback: try direct parse
    final parsed = PinUrlValidator.parse(finalUrl);
    if (parsed == null) {
      throw ValidationException(
          'Could not parse redirected URL: $finalUrl');
    }
    return parsed;
  }

  /// Clear cookies (useful for fresh session)
  Future<void> clearCookies() async {
    await _cookieJar.deleteAll();
  }

  /// Dispose resources
  void dispose() {
    _dio.close();
  }
}
