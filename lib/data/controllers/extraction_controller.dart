import 'package:dio/dio.dart';

import '../../core/exceptions/pinterest_exception.dart';
import '../../core/persistence/metadata_schema.dart';
import '../../core/utils/pin_url_validator.dart';
import '../models/author.dart';
import '../models/job_state.dart';
import '../models/media_result.dart';
import '../models/pinterest_config.dart';
import '../models/pin_item.dart';
import '../services/pinterest_extractor_service.dart';

/// Classified log sinks — the concrete LogService lives above this seam; the
/// controller emits on the same channels the inline code used to, so console
/// output is identical. Keeps this file widget-free and channel-free (G2).
class ControllerLog {
  final void Function(String message) init;
  final void Function(String message) fetch;
  final void Function(String message) parse;
  final void Function(String message) config;
  final void Function(String message) queue;
  final void Function(String message) complete;
  const ControllerLog({
    required this.init,
    required this.fetch,
    required this.parse,
    required this.config,
    required this.queue,
    required this.complete,
  });
}

/// Which phase of [ExtractionController.extract] is running — lets the
/// provider keep the phase-specific console/error copy from the inline era
/// ('Short URL resolution…' vs 'Info loading…') verbatim.
enum ExtractionPhase { resolve, extract }

/// Result of a completed extraction flow — everything JobNotifier needs to
/// transition state. Pure data; no Flutter types.
class ExtractionOutcome {
  final Author? author;
  final List<PinItem> pins;
  final int totalImages;
  final int totalVideos;
  final MediaResult? singlePinResult;

  /// Short-URL policy: resolved to a USERNAME — the run stopped after
  /// resolution; the user adjusts settings before a manual submit
  /// (pre-existing behavior, preserved verbatim).
  final bool stoppedAfterResolve;

  /// Phase 07 (D-34): capped-extraction continuation, present only on a
  /// cap exit; travels with its provenance context or not at all.
  final String? nextBookmark;
  final BookmarkContext? bookmarkContext;

  /// Parse-time metadata write payload (null when the run has nothing to
  /// persist or the caller did not request a write). The channel-based
  /// write itself stays with the provider (G2: channel-free gateway).
  final ({
    String subFolder,
    String filename,
    Map<String, dynamic> json,
  })? metadataWrite;

  const ExtractionOutcome({
    required this.author,
    required this.pins,
    required this.totalImages,
    required this.totalVideos,
    this.singlePinResult,
    this.stoppedAfterResolve = false,
    this.nextBookmark,
    this.bookmarkContext,
    this.metadataWrite,
  });

  /// The stop-after-username-resolve result (no extraction ran).
  static const ExtractionOutcome idle = ExtractionOutcome(
    author: null,
    pins: [],
    totalImages: 0,
    totalVideos: 0,
    stoppedAfterResolve: true,
  );
}

/// Phase 08 (08.1) — extraction gateway: the extraction pipeline (input
/// routing, short-URL resolution policy, user-feed pagination + bookmark
/// provenance, single-pin extraction) as pure Dart.
///
/// Reason trace (contract 08.1): responsibility (extraction isolated) ·
/// testability (fixture-testable without Flutter bindings) · evidence
/// (ARC-1/ARC-2; P3 widget-free principle).
///
/// Widget-free + channel-free by construction: no `package:flutter` imports,
/// no method channels, no file I/O. Persistence writes are returned as data
/// ([ExtractionOutcome.metadataWrite]); setup side effects (state reset,
/// Hive persist, foreground-service notify) fire through [onReadyToExtract]
/// at exactly the point the inline code used to run them.
class ExtractionController {
  final PinterestExtractorService extractor;
  final ControllerLog log;

  /// Fires when a short URL starts resolving (provider sets the early
  /// fetchingInfo state here, exactly where the inline code did).
  void Function(String input)? onResolving;

  /// Fires after a short URL resolved (provider updates the input field via
  /// onInputResolved — both stop and continue paths, as before).
  void Function({
    required String resolvedInput,
    required bool isUsername,
  })? onResolved;

  /// Fires after resolution, right before extraction dispatch — the point
  /// where the provider historically reset state, persisted the Hive task,
  /// notified the foreground service, and logged the init line.
  void Function({
    required String resolvedInput,
    required bool isUsername,
    required bool viaShortUrl,
    required MediaType mediaType,
    required int maxPages,
  })? onReadyToExtract;

  /// Extraction page progress (raw pagination counters) — notification +
  /// Hive progress plumbing stays provider-owned; this only forwards.
  void Function({
    required String username,
    required int itemCount,
    required int currentPage,
    required int maxPage,
  })? onProgress;

  /// Session config captured during the last user-feed extraction.
  PinterestConfig? lastConfig;

  /// Current phase (for phase-faithful error copy in the provider's catch).
  ExtractionPhase lastPhase = ExtractionPhase.extract;

  ExtractionController({
    required this.extractor,
    required this.log,
  });

  CancelToken? _cancelToken;

  /// Live extraction token — the provider mirrors it into its own field so
  /// cancelExtraction keeps a single source of truth.
  CancelToken? get cancelToken => _cancelToken;

  void cancel() => _cancelToken?.cancel('User cancelled');

  /// Full extraction flow for [input] (username or pin URL/ID), including
  /// short-URL resolution policy. The caller has already rejected unknown
  /// input types (provider pre-flight, same copy as before).
  /// Throws [CancelledException] on cancel; all other failures propagate
  /// for the caller to classify (phase via [lastPhase]).
  Future<ExtractionOutcome> extract({
    required String input,
    required MediaType mediaType,
    required bool saveMetadata,
    required int maxPages,
  }) async {
    _cancelToken = CancelToken();
    String resolvedInput = input;
    var isUsername = PinUrlValidator.detectInputType(input) == 'username';
    var viaShortUrl = false;

    if (PinUrlValidator.isShortUrl(input)) {
      lastPhase = ExtractionPhase.resolve;
      viaShortUrl = true;
      onResolving?.call(input);
      log.fetch('Resolving short URL: $input');
      final rawRedirectUrl = await extractor.resolveShortUrl(
        input,
        _cancelToken,
      );
      log.fetch('Redirected to: $rawRedirectUrl');

      final cleaned = PinUrlValidator.cleanRedirectedUrl(rawRedirectUrl);
      if (cleaned == null) {
        throw ValidationException(
            'Could not parse redirected URL: $rawRedirectUrl');
      }
      resolvedInput = cleaned.value;
      isUsername = cleaned.type == 'username';
      log.parse('Resolved to ${cleaned.type}: $resolvedInput');
      onResolved?.call(resolvedInput: resolvedInput, isUsername: isUsername);

      // Pre-existing policy: short URL → username STOPS after resolution;
      // the user adjusts settings (max pages, media type) before submitting.
      if (isUsername) {
        log.complete(
            'Short URL resolved to username: @$resolvedInput — submit manually to extract.');
        return ExtractionOutcome.idle;
      }
    }

    lastPhase = ExtractionPhase.extract;
    onReadyToExtract?.call(
      resolvedInput: resolvedInput,
      isUsername: isUsername,
      viaShortUrl: viaShortUrl,
      mediaType: mediaType,
      maxPages: maxPages,
    );
    log.init('Loading info for: $resolvedInput');

    if (isUsername) {
      return _extractUserPins(
        resolvedInput,
        mediaType,
        saveMetadata: saveMetadata,
        maxPages: maxPages,
      );
    }
    return _extractSinglePin(resolvedInput);
  }

  Future<ExtractionOutcome> _extractUserPins(
    String username,
    MediaType mediaType, {
    required bool saveMetadata,
    required int maxPages,
  }) async {
    final normalizedUsername = PinUrlValidator.normalizeUsername(username);

    log.config('Getting config for @$normalizedUsername');
    lastConfig = await extractor.getConfigInfo(
      username: normalizedUsername,
      cancelToken: _cancelToken,
    );
    log.config('App version: ${lastConfig!.appVersion}');
    log.config('User ID: ${lastConfig!.userId}');

    log.fetch('Fetching pins for @$normalizedUsername (max $maxPages pages)');
    final result = await extractor.getUserPins(
      username: normalizedUsername,
      maxPages: maxPages,
      cancelToken: _cancelToken,
      onProgress: (count, currentPage, maxPage) {
        log.fetch('Fetched $count pins (page $currentPage/$maxPage)...');
        onProgress?.call(
          username: normalizedUsername,
          itemCount: count,
          currentPage: currentPage,
          maxPage: maxPage,
        );
      },
    );

    log.parse('Parsed ${result.pins.length} pins');
    log.parse('Images: ${result.totalImages}, Videos: ${result.totalVideos}');

    // Phase 07 (07.5, D-34): capture the capped-extraction cursor WITH its
    // request context; the provider clears stale state on fresh extractions.
    BookmarkContext? newContext;
    if (result.bookmark != null) {
      newContext = BookmarkContext(
        username: normalizedUsername,
        resource: BookmarkContext.resourceUserPins,
        requestOptions: extractor.canonicalRequestOptions(normalizedUsername),
        extractionMode: mediaType.name,
        maxPages: maxPages,
        bookmark: result.bookmark!,
      );
      log.queue(
          'Page cap reached — more items may be available (use Fetch More)');
    }

    return ExtractionOutcome(
      author: result.author,
      pins: result.pins,
      totalImages: result.totalImages,
      totalVideos: result.totalVideos,
      nextBookmark: result.bookmark,
      bookmarkContext: newContext,
      metadataWrite: saveMetadata
          ? (
              subFolder: 'PinDL/@$normalizedUsername',
              filename: '${result.author.userId}.json',
              json: MetadataReader.buildV2Metadata(
                author: result.author,
                pins: result.pins,
                completedIndices: const {},
                totalImages: result.totalImages,
                totalVideos: result.totalVideos,
                successDownloaded: 0,
                skipDownloaded: 0,
                failedDownloaded: 0,
                wasInterrupted: false,
                mediaType: mediaType.name,
                status: 'parsed',
                nextBookmark: result.bookmark,
                bookmarkContext: newContext,
              ),
            )
          : null,
    );
  }

  Future<ExtractionOutcome> _extractSinglePin(String pinInput) async {
    final pinInfo = PinUrlValidator.parse(pinInput);
    if (pinInfo == null) {
      throw ValidationException('Invalid pin URL or ID');
    }

    log.fetch('Fetching pin: ${pinInfo.id}');
    final result = await extractor.getPinMedia(
      pinIdOrUrl: pinInput,
      cancelToken: _cancelToken,
    );

    log.parse('Found media for pin: ${result.title}');
    if (result.hasImage) log.parse('Image available: ${result.imageUrl}');
    if (result.hasVideoContent) {
      log.parse('Video available: ${result.videoUrl}');
    }

    final pin = PinItem(
      pinId: result.pinId,
      title: result.title,
      imageUrl: result.imageUrl,
      hasImage: result.hasImage,
      hasVideo: result.hasVideoContent,
    );

    return ExtractionOutcome(
      author: result.author,
      pins: [pin],
      singlePinResult: result,
      totalImages: result.hasImage ? 1 : 0,
      totalVideos: result.hasVideoContent ? 1 : 0,
    );
  }
}
