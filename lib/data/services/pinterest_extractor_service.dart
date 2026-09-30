import 'dart:async';
import 'dart:convert';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import '../../core/constants/pinterest_constants.dart';
import '../../core/exceptions/pinterest_exception.dart';
import '../../core/network/media_hosts.dart';
import '../../core/network/retry.dart';
import '../../core/utils/pin_url_validator.dart';
import '../../core/utils/trace_id_generator.dart';
import '../models/author.dart';
import '../models/media_result.dart';
import '../models/pin_item.dart';
import '../models/pinterest_config.dart';
import '../models/user_pins_result.dart';
import '../parsers/pinterest_parser.dart';
import '../pinterest/resources.dart';
import 'log_service.dart';

/// Pinterest extraction service
/// Ported from Node.js Pinterest.js
class PinterestExtractorService {
  final Dio _dio;
  bool verbose;
  final CookieJar _cookieJar;
  final LogService? _logService;

  /// Default max pages (can be overridden per request)
  static const int defaultMaxPages = 50;

  PinterestConfig? _config;

  PinterestExtractorService({
    Dio? dio,
    this.verbose = false,
    LogService? logService,
  })  : _cookieJar = CookieJar(),
        _logService = logService,
        _dio = dio ?? Dio() {
    _initializeDio();
  }

  /// Console-panel telemetry (retry lines land in the LogService console
  /// per extraction/03 step 4; LogService-only keeps the analyzer print
  /// baseline unchanged).
  void _logFetch(String message) {
    _logService?.fetch(message);
  }

  /// Username of the currently cached config, if any.
  String? get cachedUsername => _cachedUsername;
  String? _cachedUsername;

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

  /// Get headers for Pinterest API calls with trace ID spoofing.
  /// [pwsHandler] is per-resource (Phase 09 registry); the default keeps the
  /// historical user-pins value so existing call sites are unchanged.
  Map<String, String> _getApiHeaders(String sourceUrl, {String? pwsHandler}) {
    final traceHeaders = TraceIdGenerator.generateHeaders();
    return {
      ...traceHeaders,
      'x-requested-with': 'XMLHttpRequest',
      'x-pinterest-source-url': sourceUrl,
      'x-pinterest-appstate': 'active',
      'x-pinterest-pws-handler': pwsHandler ?? 'www/[username].js',
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
      final response = await retry(
        () => _dio.get<String>(
          '/$username',
          cancelToken: cancelToken,
        ),
        cancelToken: cancelToken,
        onLog: _logFetch,
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
      _cachedUsername = username;

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
    
    // Get config if not already fetched — or if it belongs to a DIFFERENT
    // username. PAR-X1 fix (plan extraction/04, option 2): the service owns
    // its cache invariant, so a user switch (A then B in one session) refetches
    // config with B's identity instead of silently reusing A's userId.
    if (_config == null || _cachedUsername != username) {
      if (_cachedUsername != null && _cachedUsername != username) {
        _logFetch('session user switch: $_cachedUsername -> $username (refetching config)');
      }
      await getConfigInfo(username: username, cancelToken: cancelToken);
    }

    // Accumulated data (like Node.js this.userData)
    final List<PinItem> allPins = [];
    final Set<String> seenPinIds = {};
    Author? author;
    String? currentBookmark = bookmark;
    // The bookmark the NEXT page would use — non-null only when the feed
    // actually has more pages (distinguishes cap-exit from natural end).
    String? pendingBookmark;
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
      // The pending continuation is ALWAYS the last served page's answer —
      // a null here proves the feed ended naturally, regardless of history.
      pendingBookmark = (nextBookmark != null && nextBookmark.isNotEmpty)
          ? nextBookmark
          : null;
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
      
      // Parse pins from data array (like Node.js line 195-206), deduped by
      // id (JS dedupeById — Phase 07 G5): overlapping bookmarks can repeat
      // rows; first occurrence wins.
      for (final item in data) {
        if (item is Map<String, dynamic>) {
          final pin = PinItem.fromUserPinJson(item);
          if (seenPinIds.contains(pin.pinId)) continue;
          seenPinIds.add(pin.pinId);
          allPins.add(pin);
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

    // Phase 07 (07.5, D-34): a bookmark is returned ONLY when the loop ended
    // because the page CAP was reached while the feed still has pages —
    // that cursor + its request context is the "Fetch more" re-entry. Every
    // other exit (natural end, empty pages, parse stop) returns null, exactly
    // like before.
    final bool capped =
        currentPage >= effectiveMaxPages &&
        pendingBookmark != null &&
        pendingBookmark.isNotEmpty;
    if (capped && verbose) {
      _logFetch('page cap reached ($effectiveMaxPages); bookmark retained for fetch-more');
    }
    return UserPinsResult.fromApiResponse(
      author: author,
      pins: allPins,
      bookmark: capped ? pendingBookmark : null,
    );
  }

  /// Canonical request options for the user-pins resource — the exact payload
  /// options `_fetchSinglePage` sends (D-34 provenance tuple). Call AFTER a
  /// getUserPins run so [_config] belongs to the same username (PAR-X1
  /// invariant: the service owns its cache identity).
  Map<String, dynamic> canonicalRequestOptions(String username) => {
        'exclude_add_pin_rep': true,
        'field_set_key': 'grid_item',
        'is_own_profile_pins': false,
        'redux_normalize_feed': true,
        'user_id': _config?.userId ?? '',
        'username': username,
      };

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
      final response = await retry(
        () => _dio.get<String>(
          url,
          options: Options(
            headers: _getApiHeaders(sourceUrl),
            responseType: ResponseType.plain,
          ),
          cancelToken: cancelToken,
        ),
        cancelToken: cancelToken,
        onLog: _logFetch,
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

  /// Phase 09.3 — registry-driven generic page fetch: the [_fetchSinglePage]
  /// envelope semantics (plain-text GET, success-status gate,
  /// resource_response extraction) applied to ANY registry resource, minus
  /// the user-pins-specific author extraction. Additive: user-pins flow is
  /// untouched. Failure returns null (mirroring [_fetchSinglePage]); cancel
  /// still throws [CancelledException]. No production prints (log sink only).
  Future<ResourcePage?> fetchResourcePage({
    required PinterestResourceDef def,
    required Map<String, dynamic> options,
    required String sourceUrl,
    String? bookmark,
    CancelToken? cancelToken,
  }) async {
    try {
      // Bookmark convention (user-pins parity): inject ONLY when present.
      final effectiveOptions = {
        ...options,
        if (bookmark != null) 'bookmarks': [bookmark],
      };
      final url = def.buildUrl(
        options: effectiveOptions,
        sourceUrlOverride: sourceUrl,
      );
      final response = await retry(
        () => _dio.get<String>(
          url,
          options: Options(
            headers: _getApiHeaders(sourceUrl, pwsHandler: def.pwsHandler),
            responseType: ResponseType.plain,
          ),
          cancelToken: cancelToken,
        ),
        cancelToken: cancelToken,
        onLog: _logFetch,
      );

      if (response.data == null || response.data!.isEmpty) {
        _logFetch('[ERROR] Empty response from ${def.name}');
        return null;
      }

      Map<String, dynamic> jsonResponse;
      try {
        jsonResponse = jsonDecode(response.data!) as Map<String, dynamic>;
      } on FormatException catch (e) {
        _logFetch('[ERROR] ${def.name} response is not valid JSON: ${e.message}');
        return null;
      }

      final resourceResponse =
          jsonResponse['resource_response'] as Map<String, dynamic>?;
      if (resourceResponse == null) {
        _logFetch('[PARSER] No resource_response in ${def.name} response');
        return null;
      }

      final status = resourceResponse['status'] as String?;
      if (status?.toLowerCase() != 'success') {
        _logFetch(
            '[PARSER] ${def.name} API returned non-success status: $status');
        return null;
      }

      return ResourcePage(
        data: resourceResponse['data'] as List<dynamic>? ?? [],
        bookmark: resourceResponse['bookmark'] as String?,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw CancelledException();
      }
      _logFetch(
          '[ERROR] Failed to fetch ${def.name}: ${e.message}');
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
      final response = await retry(
        () => _dio.get<String>(pinUrl, cancelToken: cancelToken),
        cancelToken: cancelToken,
        onLog: _logFetch,
      );

      if (response.data == null) {
        throw ExtractionException('Empty response from pin page');
      }

      final outcome = PinterestParser.parseImageDataOrNull(response.data!, pinId);
      if (outcome.isPinNotFound) {
        throw PinNotFoundException('Pin not found: $pinId', code: 'E_PIN_NOT_FOUND');
      }
      if (outcome.isSourceChanged) {
        throw SourceChangedException(
          'No relay payload on pin page: $pinId',
          code: 'E_NO_DATA',
        );
      }
      final result = outcome.result;
      if (result == null) {
        throw NoMediaException('No image found for pin: $pinId', code: 'E_NO_MEDIA');
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
      final response = await retry(
        () => _dio.get<String>(pinUrl, cancelToken: cancelToken),
        cancelToken: cancelToken,
        onLog: _logFetch,
      );

      if (response.data == null) {
        throw ExtractionException('Empty response from pin page');
      }

      final outcome = PinterestParser.parseVideoDataOrNull(response.data!, pinId);
      if (outcome.isPinNotFound) {
        throw PinNotFoundException('Pin not found: $pinId', code: 'E_PIN_NOT_FOUND');
      }
      if (outcome.isSourceChanged) {
        throw SourceChangedException(
          'No relay payload on pin page: $pinId',
          code: 'E_NO_DATA',
        );
      }
      final result = outcome.result;
      if (result == null) {
        throw NoMediaException('No video found for pin: $pinId', code: 'E_NO_MEDIA');
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
      final response = await retry(
        () => _dio.get<String>(pinUrl, cancelToken: cancelToken),
        cancelToken: cancelToken,
        onLog: _logFetch,
      );

      if (response.data == null) {
        throw ExtractionException('Empty response from pin page');
      }

      final outcome = PinterestParser.parseMediaDataOrNull(response.data!, pinId);
      if (outcome.isPinNotFound) {
        throw PinNotFoundException('Pin not found: $pinId', code: 'E_PIN_NOT_FOUND');
      }
      if (outcome.isSourceChanged) {
        throw SourceChangedException(
          'No relay payload on pin page: $pinId',
          code: 'E_NO_DATA',
        );
      }
      final result = outcome.result;
      if (result == null) {
        throw NoMediaException('No media found for pin: $pinId', code: 'E_NO_MEDIA');
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

      final finalUrl = response.realUri.toString();

      // SEC-2 (security/02): a resolved short URL must land in the
      // pinterest/pin.it family. Fail-closed with a diagnosable message.
      if (!MediaHosts.isAllowedRedirect(finalUrl)) {
        final host = Uri.tryParse(finalUrl)?.host ?? finalUrl;
        _logFetch('[SEC] unexpected redirect target host: $host');
        throw ValidationException(
          'Short URL redirected to an unexpected host: $host',
        );
      }

      return finalUrl;
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

/// One page of a registry resource response — [ResourcePage.data] rows plus
/// the next-page bookmark when the feed continues (null = natural end).
/// Pure data; board pagination (Phase 09.3) consumes it.
class ResourcePage {
  final List<dynamic> data;
  final String? bookmark;

  const ResourcePage({required this.data, this.bookmark});

  /// True when a next page exists (non-empty bookmark).
  bool get hasNext => bookmark != null && bookmark!.isNotEmpty;
}
