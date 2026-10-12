import 'package:dio/dio.dart';

import '../../core/config/build_config.dart';
import '../../core/exceptions/pinterest_exception.dart';
import '../../core/media/image_selection.dart';
import '../../core/persistence/metadata_schema.dart';
import '../../core/utils/format_utils.dart';
import '../models/author.dart';
import '../models/media_result.dart';
import '../models/board_selection.dart';
import '../models/job_state.dart';
import '../models/pin_item.dart';
import '../services/download_service.dart';
import '../services/hls_converter.dart';
import '../services/hls_service.dart';

/// Progress/step hooks the provider maps onto LogService, Hive persistence,
/// history, and the foreground-service notification (channels stay
/// provider-side — G2 discipline).
class DownloadCoordinatorHooks {
  final void Function(String message) queue;
  final void Function(String message) downloading;
  final void Function(String message) saved;
  final void Function(String message) skipped;
  final void Function(String message) failed;
  final void Function(String message) parse;
  final void Function(String message) error;
  final void Function(String message) interrupted;
  final void Function(String message) complete;

  /// FFmpeg log line filter+sink (the provider keeps its verbose-frame skip).
  final void Function(String log) onFfmpegLog;

  /// History entry (provider forwards to the history provider callback).
  final void Function({
    required String filename,
    required String url,
    required bool success,
    String? errorMessage,
  }) onHistory;

  /// Error → user-copy mapping (pure function, injected so the coordinator
  /// does not import the presentation utils layer).
  final String Function(Object error) mapError;

  /// Persisted-progress mirror (Hive) — best-effort, provider-owned store.
  final void Function({
    required int currentIndex,
    int? skippedCount,
    int? failedCount,
    String? failedPinId,
  })? onPersistedProgress;

  const DownloadCoordinatorHooks({
    required this.queue,
    required this.downloading,
    required this.saved,
    required this.skipped,
    required this.failed,
    required this.parse,
    required this.error,
    required this.interrupted,
    required this.complete,
    required this.onFfmpegLog,
    required this.onHistory,
    required this.mapError,
    this.onPersistedProgress,
  });
}

/// One planned download item (pure data; mirrors the old inline record).
class PlannedDownload {
  final String pinId;
  final String title;
  final String url;
  final bool isVideo;
  final bool isHls;
  final String subFolder;
  final String role;

  /// 0-based slide index inside a carousel pin; null for every single-item
  /// pin. Feed/Board carousel migration: a pin whose row carries N>1 slides
  /// produces N items (`role: 'image'`), so N slides are downloaded and each
  /// one is tracked separately. Non-carousel items keep `slotIndex == null`
  /// and behave byte-identically to before.
  final int? slotIndex;

  /// Unique per-ITEM key. For a single-item pin this IS the pinId (so every
  /// existing key/callback/history path is unchanged); for a carousel slide it
  /// is `<pinId>_img<n>` (1-based, matching the single-pin carousel naming
  /// family). Completion indices, the queue id, the cancel-token key and the
  /// history map all key on this, so slides can never alias one another
  /// (which a pinId key would do).
  String get key => slotIndex == null ? pinId : '${pinId}_img${slotIndex! + 1}';

  const PlannedDownload({
    required this.pinId,
    required this.title,
    required this.url,
    required this.isVideo,
    required this.isHls,
    required this.subFolder,
    required this.role,
    this.slotIndex,
  });
}

/// Session-run counters. startDownload resets the provider state to zero, so
/// these session values are byte-identical to the old `state.downloadedCount`
/// etc. during a run — the provider applies deltas to its state via onStats.
class DownloadRunStats {
  int downloaded = 0;
  int skipped = 0;
  int failed = 0;
  int currentIndex = 0;
}

/// Outcome of a single-pin download run (3.1.1). Counters mirror the old
/// inline provider flow 1:1; [wasInterrupted] reports a user cancel observed
/// during the run (HLS conversion cancel included).
class SinglePinRunResult {
  final int downloaded;
  final int skipped;
  final int failed;
  final bool wasInterrupted;

  const SinglePinRunResult({
    required this.downloaded,
    required this.skipped,
    required this.failed,
    this.wasInterrupted = false,
  });
}

/// Early-exit classification (the provider replicates the exact old
/// edge-path semantics: which state fields are set, and which finalization
/// side effects are skipped).
enum FeedEarlyExit {
  /// Full run executed.
  none,
  /// No items matched the media type: old flow set completed (counters as-is)
  /// and returned WITHOUT _completePersistedTask/onTaskCompleted/final log.
  noItems,
  /// Continue-mode start index past the end: old flow set completed with the
  /// PREVIOUS counters and returned WITHOUT finalization side effects.
  allDownloaded,
}

/// Result of a completed feed download run — everything the provider needs
/// to finalize state and persist metadata.
class FeedDownloadResult {
  /// D-04 completion-set tracking: indices are absolute (planned-list
  /// coordinates). success + explicit skip enter the set; failed stays a hole.
  final Set<int> sessionCompleted;
  final String baseFolder;
  final DownloadRunStats stats;

  /// User-cancel during the run (mirrors the old `state.status == cancelled`
  /// read at the tail: the only cancel path flips the token).
  final bool wasInterrupted;

  /// Early-exit classification (none = full run).
  final FeedEarlyExit earlyExit;

  /// Download-time metadata write payload (null unless requested and the
  /// author is known). The channel-based write stays provider-side (G2).
  final ({
    String subFolder,
    String filename,
    Map<String, dynamic> json,
  })? metadataWrite;

  const FeedDownloadResult({
    required this.sessionCompleted,
    required this.baseFolder,
    required this.stats,
    required this.wasInterrupted,
    this.earlyExit = FeedEarlyExit.none,
    this.metadataWrite,
  });
}

/// Terminal states of the single-pin HLS leg.
enum _SinglePinHlsOutcome { saved, skipped, failed, cancelled }

/// Phase 08 (08.2) — download coordinator: queue planning (per-media
/// strategy), the feed download run (regular queue via DownloadService +
/// HLS conversion branches by flavor), and completion-set math as pure Dart.
///
/// Reason trace (contract 08.2): responsibility (queue/concurrency owner) ·
/// testability (local-HTTP tests already target DownloadService) · evidence
/// (ARC-1; CONC-1 sliding-window contract preserved by delegation).
///
/// Widget-free + channel-free by construction: DownloadService interactions
/// are preserved 1:1 via the injected service; metadata writes are returned
/// as data for the provider to execute.
class DownloadCoordinator {
  final DownloadService downloadService;
  final HlsService? hlsService;
  final HlsConverter? hlsConverter;
  final DownloadCoordinatorHooks hooks;

  /// Public for tests/probes: the single-pin HLS decision (no I/O).
  bool get hlsAvailable => hlsService != null && hlsConverter != null;

  /// Cancel token mirror — the provider assigns its live token so
  /// cancelDownload keeps a single source of truth.
  CancelToken? cancelToken;

  DownloadCoordinator({
    required this.downloadService,
    required this.hooks,
    this.hlsService,
    this.hlsConverter,
  });

  /// Plans the download items for a feed/board run: video mode → videos only
  /// (unchanged); image mode → images, falling back to video thumbnails for
  /// video pins without a separate image, and — Feed/Board carousel migration
  /// — ONE item per carousel slide when the pin's row carried N>1 slides.
  ///
  /// Index space: the returned list IS the absolute index space the D-04
  /// completion set and the v2 `completed_indices` array are keyed on. A pin
  /// with N slides therefore contributes N consecutive indices, in slot order,
  /// which is exactly what makes a partially downloaded carousel a set of
  /// holes (never counted complete). Legacy records written before this change
  /// are re-projected by `core/persistence/feed_plan_migration.dart`.
  static List<PlannedDownload> planFeedItems({
    required List<PinItem> pins,
    required MediaType mediaType,
    required String imagesFolder,
    required String videosFolder,
  }) {
    final isVideoOnly = mediaType == MediaType.video;
    final items = <PlannedDownload>[];
    for (final pin in pins) {
      if (isVideoOnly) {
        if (pin.hasVideo && pin.videoUrl?.url != null) {
          items.add(PlannedDownload(
            pinId: pin.pinId,
            title: pin.title,
            url: pin.videoUrl!.url,
            isVideo: true,
            isHls: pin.videoUrl!.isHls,
            subFolder: videosFolder,
            role: 'video',
          ));
        }
      } else {
        // Carousel first: a row with N>1 slides is N items (slot order =
        // display order). `imageSlots.length <= 1` falls through to the
        // single-image path unchanged.
        if (pin.imageSlots.length > 1) {
          for (var slot = 0; slot < pin.imageSlots.length; slot++) {
            items.add(PlannedDownload(
              pinId: pin.pinId,
              title: pin.title,
              url: upgradePinterestImageUrl(pin.imageSlots[slot]),
              isVideo: false,
              isHls: false,
              subFolder: imagesFolder,
              role: 'image',
              slotIndex: slot,
            ));
          }
        } else if (pin.hasImage && pin.imageUrl != null) {
          items.add(PlannedDownload(
            pinId: pin.pinId,
            title: pin.title,
            url: pin.imageUrl!,
            isVideo: false,
            isHls: false,
            subFolder: imagesFolder,
            role: 'image',
          ));
        } else if (pin.hasVideo && pin.thumbnail != null) {
          items.add(PlannedDownload(
            pinId: pin.pinId,
            title: pin.title,
            url: pin.thumbnail!,
            isVideo: false,
            isHls: false,
            subFolder: imagesFolder,
            role: 'thumbnail',
          ));
        }
      }
    }
    return items;
  }

  /// Continue-mode start index (Phase 04 contract): skip the completed
  /// prefix only when the media type matches the previous session's.
  static int startIndexFor({
    required bool isContinueMode,
    required int lastIndexDownloaded,
    required String? previousMediaType,
    required MediaType mediaType,
  }) {
    final sameMediaType =
        previousMediaType == null || previousMediaType == mediaType.name;
    return isContinueMode && lastIndexDownloaded >= 0 && sameMediaType
        ? lastIndexDownloaded + 1
        : 0;
  }

  /// Phase 10.4 — board output folder (layout decision, D-39):
  /// `PinDL/@<username>/Boards/<sanitized-slug>[-<boardId-suffix>]/`.
  /// Slug = display/path identity (D-37) — path use is legitimate — but
  /// slugs collide (boards-ux plan risk item), so a short boardId suffix is
  /// appended deterministically on collision. Sanitized per STO-3 charset
  /// rules (reuse [FormatUtils.sanitizeFilename] charset class).
  static String boardFolder({
    required String username,
    required String slug,
    required String boardId,
    Set<String> usedFolders = const {},
  }) {
    final safeSlug =
        FormatUtils.sanitizeFilename(slug).replaceAll(' ', '-');
    final visibleSlug = safeSlug.isEmpty ? 'board' : safeSlug;
    // Short identity suffix: last 6 chars of the numeric board id.
    final idSuffix = boardId.length > 6
        ? boardId.substring(boardId.length - 6)
        : boardId;
    var folder = 'PinDL/@$username/Boards/$visibleSlug-$idSuffix';
    // Deterministic collision handling: extend the id suffix.
    var take = 6;
    while (usedFolders.contains(folder.toLowerCase())) {
      take = (take + 2).clamp(6, boardId.length);
      folder =
          'PinDL/@$username/Boards/$visibleSlug-${boardId.substring(boardId.length - take)}';
    }
    return folder;
  }

  /// Plan sequential per-board runs from a [BoardSelection] (Phase 10.2,
  /// D-38): each active board becomes one feed-shaped run with its own
  /// base folder; sections mode resolves to the union of picked sections'
  /// pins by the CALLER (fetch happens per board before this is invoked —
  /// pure math here, no I/O). Order = selection display order.
  static List<({BoardChoice choice, String baseFolder})> planBoardRuns({
    required BoardSelection selection,
    required String username,
  }) {
    final used = <String>{};
    final runs = <({BoardChoice choice, String baseFolder})>[];
    for (final choice in selection.active) {
      final folder = boardFolder(
        username: username,
        slug: choice.slug,
        boardId: choice.boardId,
        usedFolders: used,
      );
      used.add(folder.toLowerCase());
      runs.add((choice: choice, baseFolder: folder));
    }
    return runs;
  }

  /// Runs a single-pin download (3.1.1): image / carousel slots, then video —
  /// with the HLS decision the flow previously lacked.
  ///
  /// Before this, the single-pin path handed every URL — m3u8 included — to
  /// [DownloadService.downloadFile], so an HLS pin produced a `<pinId>_video.mp4`
  /// containing the playlist text (device report: "920 B, HLS content, no error
  /// show in console"). Now:
  ///   * direct MP4 (or any progressive URL) -> normal byte-range download;
  ///   * HLS on the FFmpeg build -> parse master playlist, convert to MP4 with
  ///     FFmpeg, import the validated output;
  ///   * HLS on the lite build -> explicit, honest skip (same semantics as the
  ///     feed path), never a corrupt file.
  ///
  /// Image URLs are upgraded to the full-size Pinterest rendition before
  /// download (the 60x60/236x thumbnail bug).
  Future<SinglePinRunResult> runSinglePinDownload({
    required MediaResult result,
    required String outputPath,
    required bool overwrite,
    required bool downloadImage,
    required bool downloadVideo,
  }) async {
    var downloaded = 0;
    var skipped = 0;
    var failed = 0;
    var interrupted = false;

    Future<void> downloadOne({
      required String url,
      required String filename,
      required String id,
    }) async {
      hooks.downloading('Downloading $filename');
      try {
        await downloadService.downloadFile(
          url: url,
          outputPath: outputPath,
          filename: filename,
          pinId: id,
          overwrite: overwrite,
        );
        hooks.saved('Saved: $filename');
        downloaded++;
        hooks.onHistory(filename: filename, url: url, success: true);
      } on DownloadException catch (e) {
        if (e.message.contains('already exists')) {
          hooks.skipped('Skipped: $filename (exists)');
          skipped++;
        } else {
          hooks.failed('Failed: $filename - ${e.message}');
          failed++;
          hooks.onHistory(
            filename: filename,
            url: url,
            success: false,
            errorMessage: e.message,
          );
        }
      } catch (e) {
        if (e is CancelledException) {
          interrupted = true;
          hooks.interrupted('Cancelled: $filename');
          return;
        }
        hooks.failed('Failed: $filename - $e');
        failed++;
        hooks.onHistory(
          filename: filename,
          url: url,
          success: false,
          errorMessage: hooks.mapError(e),
        );
      }
    }

    if (downloadImage) {
      // Carousel: one download per slot, in slot order, deterministic indexed
      // names (<pinId>_image_<n>.<ext>, 1-based) — each slot an independent
      // history entry with its own counting.
      if (result.slots.length > 1) {
        hooks.queue('Carousel pin: ${result.slots.length} images to download');
        for (var i = 0; i < result.slots.length; i++) {
          final slotUrl = upgradePinterestImageUrl(result.slots[i].imageUrl);
          final filename = FormatUtils.pinFilename(
            pinId: result.pinId,
            role: 'image',
            url: slotUrl,
            imageIndex: i + 1,
          );
          await downloadOne(
            url: slotUrl,
            filename: filename,
            id: '${result.pinId}_img$i',
          );
          if (cancelToken?.isCancelled ?? false) break;
        }
      } else {
        final imageUrl = result.getImageDownloadUrl(useThumbnailForVideo: true);
        if (imageUrl != null) {
          final role =
              (result.hasVideoContent && !result.hasImage) ? 'thumbnail' : 'image';
          final url = upgradePinterestImageUrl(imageUrl);
          final filename =
              FormatUtils.pinFilename(pinId: result.pinId, role: role, url: url);
          await downloadOne(
            url: url,
            filename: filename,
            id: '${result.pinId}_img',
          );
        }
      }
    }

    if (downloadVideo && result.hasVideoContent) {
      final videoUrl = result.videoUrl;
      if (videoUrl != null) {
        final filename = FormatUtils.pinFilename(
            pinId: result.pinId, role: 'video', url: videoUrl);

        if (result.videoIsHls) {
          final hls = await _downloadSinglePinHls(
            videoUrl: videoUrl,
            filename: filename,
            overwrite: overwrite,
          );
          if (hls == _SinglePinHlsOutcome.saved) {
            downloaded++;
          } else if (hls == _SinglePinHlsOutcome.skipped) {
            skipped++;
          } else if (hls == _SinglePinHlsOutcome.failed) {
            failed++;
          } else {
            interrupted = true;
          }
        } else {
          await downloadOne(
            url: videoUrl,
            filename: filename,
            id: '${result.pinId}_vid',
          );
        }
      }
    }

    return SinglePinRunResult(
      downloaded: downloaded,
      skipped: skipped,
      failed: failed,
      wasInterrupted: interrupted,
    );
  }

  /// HLS leg of the single-pin flow. Returns the outcome class so the caller's
  /// counters stay identical to the pre-3.1.1 shape.
  Future<_SinglePinHlsOutcome> _downloadSinglePinHls({
    required String videoUrl,
    required String filename,
    required bool overwrite,
  }) async {
    const videosFolder = 'PinDL';

    // Capability check, not the compile-time flag: JobNotifier constructs the
    // HLS services ONLY when BuildConfig.enableFfmpeg is true (which is what
    // keeps HlsService/HlsConverter out of lite AOT binaries via tree-shaking),
    // so "services present" == "FFmpeg build" while this branch stays testable
    // with injected fakes.
    if (!hlsAvailable) {
      hooks.skipped('Skipped: $filename (HLS video — requires FFmpeg build)');
      return _SinglePinHlsOutcome.skipped;
    }

    // Skip-existing gate FIRST (overwrite=false), mirroring both the regular
    // download path (`downloadFile` throws 'File already exists') and the feed
    // HLS loop: without it a re-run would convert the whole playlist only to
    // let MediaStore auto-rename the duplicate.
    if (!overwrite) {
      final exists =
          await downloadService.fileExistsInDownloads(filename, videosFolder);
      if (exists) {
        hooks.skipped('Skipped: $filename (exists)');
        return _SinglePinHlsOutcome.skipped;
      }
    }

    try {
      hooks.downloading('HLS video: fetching playlist...');
      final parsed = await hlsService!.fetchAndParse(videoUrl);
      if (!parsed.success) {
        throw Exception('HLS parse failed: ${parsed.errorMessage}');
      }
      hooks.parse(
          'HLS variant: ${parsed.width}x${parsed.height} @ ${parsed.bandwidth ?? 0} bps');

      hooks.downloading('Converting HLS -> MP4...');
      final conversion = await hlsConverter!.convertToMp4(
        videoM3u8Url: parsed.videoVariantUrl!,
        audioM3u8Url: parsed.audioUrl,
        outputFilename: filename,
        onLog: hooks.onFfmpegLog,
        cancelToken: cancelToken,
      );

      if (!conversion.success) {
        if (conversion.wasCancelled) {
          hooks.interrupted('HLS conversion cancelled: $filename');
          return _SinglePinHlsOutcome.cancelled;
        }
        throw Exception('FFmpeg conversion failed: ${conversion.errorMessage}');
      }

      final saved = await downloadService.saveFileToDownloads(
        conversion.outputPath!,
        filename,
        videosFolder,
        overwrite: overwrite,
      );
      if (saved == null) {
        throw Exception('Failed to save converted file to Downloads');
      }
      hooks.saved('Saved: $filename');
      hooks.onHistory(filename: filename, url: videoUrl, success: true);
      return _SinglePinHlsOutcome.saved;
    } catch (e) {
      if (e is CancelledException) {
        hooks.interrupted('Cancelled: $filename');
        return _SinglePinHlsOutcome.cancelled;
      }
      hooks.failed('HLS failed: $filename - $e');
      hooks.onHistory(
        filename: filename,
        url: videoUrl,
        success: false,
        errorMessage: hooks.mapError(e),
      );
      return _SinglePinHlsOutcome.failed;
    }
  }

  /// Runs the feed download (regular queue first, then HLS by flavor).
  ///
  /// Phase 10 (D-38): board jobs reuse this method with
  /// [baseFolderOverride] (`PinDL/@user/Boards/<slug-id>/…`) — queue,
  /// sliding window, HLS branches, completion-set math all identical.
  /// Null (default) keeps the feed behavior byte-identical.
  /// [onStats] receives incremental deltas so the provider's copyWith state
  /// stays the single UI source of truth.
  Future<FeedDownloadResult> runFeedDownload({
    required List<PinItem> pins,
    required Author? author,
    required MediaType mediaType,
    required String outputPath,
    required bool overwrite,
    required bool saveMetadata,
    required bool isContinueMode,
    required int lastIndexDownloaded,
    required String? previousMediaType,
    required Set<int> previousCompletedIndices,
    required int totalImages,
    required int totalVideos,
    required int previousDownloaded,
    required int previousSkipped,
    required int previousFailed,    required String? nextBookmark,
    required BookmarkContext? bookmarkContext,
    String? baseFolderOverride,
    required void Function({
      int? downloadedDelta,
      int? skippedDelta,
      int? failedDelta,
      int? indexDelta,
    }) onStats,
  }) async {
    final stats = DownloadRunStats();
    final isVideoOnly = mediaType == MediaType.video;
    final username0 = author?.username ?? 'unknown';

    final baseFolder = baseFolderOverride ?? 'PinDL/@$username0';
    final imagesFolder = '$baseFolder/Images';
    final videosFolder = '$baseFolder/Videos';

    final downloadItems = planFeedItems(
      pins: pins,
      mediaType: mediaType,
      imagesFolder: imagesFolder,
      videosFolder: videosFolder,
    );

    if (downloadItems.isEmpty) {
      hooks.error('No ${mediaType.name}s found in pins');
      return FeedDownloadResult(
        sessionCompleted: const {},
        baseFolder: baseFolder,
        stats: stats,
        wasInterrupted: false,
        earlyExit: FeedEarlyExit.noItems,
      );
    }

    final startIndex = startIndexFor(
      isContinueMode: isContinueMode,
      lastIndexDownloaded: lastIndexDownloaded,
      previousMediaType: previousMediaType,
      mediaType: mediaType,
    );

    if (startIndex >= downloadItems.length) {
      hooks.complete('All items already downloaded!');
      return FeedDownloadResult(
        sessionCompleted: const {},
        baseFolder: baseFolder,
        stats: stats,
        wasInterrupted: false,
        earlyExit: FeedEarlyExit.allDownloaded,
      );
    }

    final itemsToDownload = downloadItems.sublist(startIndex);

    // Log aggregation stats (including HLS count) — verbatim copy.
    final videoCount = itemsToDownload.where((i) => i.isVideo).length;
    final hlsCount = itemsToDownload.where((i) => i.isHls).length;
    final mp4Count = videoCount - hlsCount;
    final imageCount = itemsToDownload.where((i) => !i.isVideo).length;

    if (isContinueMode) {
      hooks.queue('Continue mode: skipping first $startIndex items');
      hooks.queue('Remaining to download: $imageCount images, $videoCount videos ($mp4Count MP4, $hlsCount HLS), total ${itemsToDownload.length} items');
    } else {
      hooks.queue('To be downloaded: $imageCount images, $videoCount videos ($mp4Count MP4, $hlsCount HLS)');
    }
    if (hlsCount > 0) {
      if (BuildConfig.enableFfmpeg) {
        hooks.queue('HLS videos will be converted to MP4 using FFmpeg');
      } else {
        hooks.queue('Lite mode: HLS videos will be fetched via single-pin extraction');
      }
    }
    hooks.queue('Output: Downloads/$baseFolder');

    final sameMediaType =
        previousMediaType == null || previousMediaType == mediaType.name;

    // Build a map of item key -> (url, filename) for history tracking. The key
    // is the pinId for single-item pins (unchanged) and `<pinId>_img<n>` for a
    // carousel slide (Feed/Board carousel migration) — a pinId-keyed map would
    // make every slide of one pin alias the same entry.
    final Map<String, (String url, String filename)> pinUrlMap = {};

    // Separate HLS items (need special processing) from regular items.
    final hlsItems = itemsToDownload.where((i) => i.isHls).toList();
    final regularItems = itemsToDownload.where((i) => !i.isHls).toList();

    // Add regular items to download queue.
    for (var i = 0; i < regularItems.length; i++) {
      final item = regularItems[i];
      final filename = FormatUtils.pinFilename(
        pinId: item.pinId,
        role: item.role,
        url: item.url,
        // Carousel slide → `<pinId>_image_<n>` (1-based), the same naming the
        // single-pin carousel path uses (D-48); single-item pins keep the
        // plain `<pinId>_image.<ext>` name byte-for-byte.
        imageIndex: item.slotIndex == null ? null : item.slotIndex! + 1,
      );
      pinUrlMap[item.key] = (item.url, filename);

      downloadService.enqueue(
        id: '${item.key}_${startIndex + i}',
        pinId: item.key,
        title: item.title.isEmpty ? item.pinId : item.title,
        url: item.url,
        outputPath: outputPath,
        filename: filename,
        overwrite: overwrite,
        subFolder: item.subFolder,
      );
    }

    // D-04 completion-set tracking: indices are absolute (planned-list
    // coordinates). The previous session's set merges only when the media
    // type matches (otherwise indices refer to a different item list).
    final sessionCompleted = <int>{};
    // Absolute index of every planned item, keyed by ITEM key — never by
    // pinId (with carousel expansion one pin owns several indices). Derived
    // from the full planned list, so HLS and regular items interleaved in pin
    // order each report their OWN index (the old `regularItems.length + i`
    // arithmetic assumed HLS items sat in a tail block).
    final indexByKey = <String, int>{
      for (var i = 0; i < downloadItems.length; i++) downloadItems[i].key: i,
    };

    // Process regular queue first (sliding-window contract unchanged).
    if (regularItems.isNotEmpty) {
      await downloadService.processQueue(
        overwrite: overwrite,
        subFolder: isVideoOnly ? videosFolder : imagesFolder,
        onCompleted: (pinId) {
          // `pinId` here is the item key (== pinId for single-item pins).
          hooks.saved('Saved: $pinId');
          // D-04: success = complete → enters the completion set.
          final idx = indexByKey[pinId];
          if (idx != null) sessionCompleted.add(idx);

          stats.downloaded++;
          stats.currentIndex++;
          onStats(downloadedDelta: 1, indexDelta: 1);

          final info = pinUrlMap[pinId];
          if (info != null) {
            hooks.onHistory(
              filename: info.$2,
              url: info.$1,
              success: true,
            );
          }
        },
        onSkipped: (pinId, reason) {
          hooks.skipped('Skipped $pinId: $reason');
          // D-04: explicit skip = complete → enters the completion set.
          final idx = indexByKey[pinId];
          if (idx != null) sessionCompleted.add(idx);

          stats.skipped++;
          stats.currentIndex++;
          onStats(skippedDelta: 1, indexDelta: 1);
          hooks.onPersistedProgress?.call(
            currentIndex: stats.currentIndex,
            skippedCount: stats.skipped,
          );
        },
        onFailed: (pinId, error) {
          hooks.failed('Failed $pinId: $error');
          // D-04: failed = INCOMPLETE → hole; NOT in the completion set;
          // continue re-offers it. Index bookkeeping still advances.

          stats.failed++;
          stats.currentIndex++;
          onStats(failedDelta: 1, indexDelta: 1);
          hooks.onPersistedProgress?.call(
            currentIndex: stats.currentIndex,
            failedCount: stats.failed,
            failedPinId: pinId,
          );

          final info = pinUrlMap[pinId];
          if (info != null) {
            hooks.onHistory(
              filename: info.$2,
              url: info.$1,
              success: false,
              errorMessage: error,
            );
          }
        },
      );
    }

    // Process HLS items — strategy depends on build flavor. HLS items are
    // always video items (one per pin), so `item.key == item.pinId` here.
    if (BuildConfig.enableFfmpeg && hlsService != null && hlsConverter != null) {
      // ── FFmpeg build: HLS parsing + FFmpeg conversion ──
      for (var i = 0; i < hlsItems.length; i++) {
        if (cancelToken?.isCancelled ?? false) break;

        final item = hlsItems[i];
        final outputFilename = FormatUtils.pinFilename(
            pinId: item.pinId, role: 'video', url: item.url); // HLS -> MP4
        pinUrlMap[item.key] = (item.url, outputFilename);

        hooks.downloading('HLS video: Fetching playlist for ${item.pinId}...');

        try {
          // Step 1: Check if output file already exists (skip if !overwrite).
          if (!overwrite) {
            final exists = await downloadService.fileExistsInDownloads(
                outputFilename, videosFolder);
            if (exists) {
              hooks.skipped('Skipped ${item.pinId}: File exists');
              sessionCompleted.add(indexByKey[item.key]!);

              stats.skipped++;
              stats.currentIndex++;
              onStats(skippedDelta: 1, indexDelta: 1);
              continue;
            }
          }

          // Step 2: Fetch and parse HLS master playlist.
          final hlsResult = await hlsService!.fetchAndParse(item.url);
          if (!hlsResult.success) {
            throw Exception('HLS parse failed: ${hlsResult.errorMessage}');
          }

          hooks.parse(
              'HLS variant: ${hlsResult.width}x${hlsResult.height} @ ${hlsResult.bandwidth ?? 0} bps');

          // Step 3: Convert HLS to MP4 using FFmpeg.
          hooks.downloading('Converting HLS -> MP4...');
          final conversionResult = await hlsConverter!.convertToMp4(
            videoM3u8Url: hlsResult.videoVariantUrl!,
            audioM3u8Url: hlsResult.audioUrl,
            outputFilename: outputFilename,
            onLog: hooks.onFfmpegLog,
            cancelToken: cancelToken,
          );

          if (!conversionResult.success) {
            if (conversionResult.wasCancelled) {
              // Phase 05 truth table: cancelled = INCOMPLETE (re-offered on
              // continue) — never counted failed, no history entry.
              hooks.interrupted('HLS conversion cancelled: ${item.pinId}');
              continue;
            }
            throw Exception(
                'FFmpeg conversion failed: ${conversionResult.errorMessage}');
          }

          // Step 4: Move converted MP4 to public Downloads.
          final savedPath = await downloadService.saveFileToDownloads(
            conversionResult.outputPath!,
            outputFilename,
            videosFolder,
            overwrite: overwrite,
          );

          if (savedPath != null) {
            hooks.saved('Saved: $outputFilename');
            sessionCompleted.add(indexByKey[item.key]!);

            stats.downloaded++;
            stats.currentIndex++;
            onStats(downloadedDelta: 1, indexDelta: 1);

            hooks.onHistory(
              filename: outputFilename,
              url: item.url,
              success: true,
            );
          } else {
            throw Exception('Failed to save converted file to Downloads');
          }
        } catch (e) {
          hooks.failed('HLS failed ${item.pinId}: $e');

          stats.failed++;
          stats.currentIndex++;
          onStats(failedDelta: 1, indexDelta: 1);

          hooks.onHistory(
            filename: outputFilename,
            url: item.url,
            success: false,
            errorMessage: hooks.mapError(e),
          );
        }
      }
    } else {
      // ── Lite build: HLS conversion unsupported — honest skip (HLS-4/05.5);
      // explicit skip = complete per the truth table (in the set; not
      // re-offered on continue).
      if (hlsItems.isNotEmpty) {
        hooks.queue(
            '${hlsItems.length} HLS video(s) skipped — require the FFmpeg build');
      }
      for (var i = 0; i < hlsItems.length; i++) {
        if (cancelToken?.isCancelled ?? false) break;
        final item = hlsItems[i];
        hooks.skipped(
            'Skipped ${item.pinId}: HLS video — requires FFmpeg build');
        sessionCompleted.add(indexByKey[item.key]!);
        stats.skipped++;
        stats.currentIndex++;
        onStats(skippedDelta: 1, indexDelta: 1);
      }
    }

    // User-cancel during this run (the only cancel path flips the token —
    // same semantics as the old state.status == cancelled read).
    final wasInterrupted = cancelToken?.isCancelled ?? false;

    // Accumulate counts across sessions for the metadata write.
    final totalDownloaded = previousDownloaded + stats.downloaded;
    final totalSkipped = previousSkipped + stats.skipped;
    final totalFailed = previousFailed + stats.failed;

    return FeedDownloadResult(
      sessionCompleted: sessionCompleted,
      baseFolder: baseFolder,
      stats: stats,
      wasInterrupted: wasInterrupted,
      metadataWrite: saveMetadata && author != null
          ? (
              subFolder: baseFolder,
              filename: '${author.userId}.json',
              json: MetadataReader.buildV2Metadata(
                author: author,
                pins: pins,
                completedIndices: sessionCompleted.union(
                  sameMediaType ? previousCompletedIndices : const <int>{},
                ),
                totalImages: totalImages,
                totalVideos: totalVideos,
                successDownloaded: totalDownloaded,
                skipDownloaded: totalSkipped,
                failedDownloaded: totalFailed,
                wasInterrupted: wasInterrupted,
                mediaType: mediaType.name,
                nextBookmark: nextBookmark,
                bookmarkContext: bookmarkContext,
                // Feed/Board carousel migration: these indices are absolute
                // over the EXPANDED plan (one item per carousel slide) — the
                // marker is what stops a later continue from reading them as
                // pre-migration pin-level indices.
                itemPlan: MetadataReader.feedItemPlanExpanded,
              ),
            )
          : null,
    );
  }
}
