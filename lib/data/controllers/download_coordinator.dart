import 'package:dio/dio.dart';

import '../../core/config/build_config.dart';
import '../../core/persistence/metadata_schema.dart';
import '../../core/utils/format_utils.dart';
import '../models/author.dart';
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
  const PlannedDownload({
    required this.pinId,
    required this.title,
    required this.url,
    required this.isVideo,
    required this.isHls,
    required this.subFolder,
    required this.role,
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

  /// Cancel token mirror — the provider assigns its live token so
  /// cancelDownload keeps a single source of truth.
  CancelToken? cancelToken;

  DownloadCoordinator({
    required this.downloadService,
    required this.hooks,
    this.hlsService,
    this.hlsConverter,
  });

  /// Plans the download items for a feed (Node.js logic, verbatim):
  /// video mode → videos only; image mode → images, falling back to video
  /// thumbnails for video pins without a separate image.
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
        if (pin.hasImage && pin.imageUrl != null) {
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
      hooks.queue('Remaining to download: $imageCount images, $videoCount videos (${mp4Count} MP4, $hlsCount HLS), total ${itemsToDownload.length} items');
    } else {
      hooks.queue('To be downloaded: $imageCount images, $videoCount videos (${mp4Count} MP4, $hlsCount HLS)');
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

    // Build a map of pinId -> (url, filename) for history tracking.
    final Map<String, (String url, String filename)> pinUrlMap = {};

    // Separate HLS items (need special processing) from regular items.
    final hlsItems = itemsToDownload.where((i) => i.isHls).toList();
    final regularItems = itemsToDownload.where((i) => !i.isHls).toList();

    // Add regular items to download queue.
    for (var i = 0; i < regularItems.length; i++) {
      final item = regularItems[i];
      final filename = FormatUtils.pinFilename(
          pinId: item.pinId, role: item.role, url: item.url);
      pinUrlMap[item.pinId] = (item.url, filename);

      downloadService.enqueue(
        id: '${item.pinId}_${startIndex + i}',
        pinId: item.pinId,
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
    final regularIndexByPin = <String, int>{
      for (var i = 0; i < regularItems.length; i++)
        regularItems[i].pinId: startIndex + i,
    };

    // Process regular queue first (sliding-window contract unchanged).
    if (regularItems.isNotEmpty) {
      await downloadService.processQueue(
        overwrite: overwrite,
        subFolder: isVideoOnly ? videosFolder : imagesFolder,
        onCompleted: (pinId) {
          hooks.saved('Saved: $pinId');
          // D-04: success = complete → enters the completion set.
          final idx = regularIndexByPin[pinId];
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
          final idx = regularIndexByPin[pinId];
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

    // Process HLS items — strategy depends on build flavor.
    if (BuildConfig.enableFfmpeg && hlsService != null && hlsConverter != null) {
      // ── FFmpeg build: HLS parsing + FFmpeg conversion ──
      for (var i = 0; i < hlsItems.length; i++) {
        if (cancelToken?.isCancelled ?? false) break;

        final item = hlsItems[i];
        final outputFilename = FormatUtils.pinFilename(
            pinId: item.pinId, role: 'video', url: item.url); // HLS -> MP4
        pinUrlMap[item.pinId] = (item.url, outputFilename);

        hooks.downloading('HLS video: Fetching playlist for ${item.pinId}...');

        try {
          // Step 1: Check if output file already exists (skip if !overwrite).
          if (!overwrite) {
            final exists = await downloadService.fileExistsInDownloads(
                outputFilename, videosFolder);
            if (exists) {
              hooks.skipped('Skipped ${item.pinId}: File exists');
              sessionCompleted.add(startIndex + regularItems.length + i);

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
            sessionCompleted.add(startIndex + regularItems.length + i);

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
        sessionCompleted.add(startIndex + regularItems.length + i);
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
              ),
            )
          : null,
    );
  }
}
