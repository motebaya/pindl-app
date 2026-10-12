import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/media/carousel_slots.dart';
import 'package:pindl/core/persistence/board_resume.dart';
import 'package:pindl/core/persistence/metadata_schema.dart';
import 'package:pindl/data/controllers/download_coordinator.dart';
import 'package:pindl/data/models/author.dart';
import 'package:pindl/data/models/job_state.dart';
import 'package:pindl/data/models/pin_item.dart';
import 'package:pindl/data/parsers/pinterest_parser.dart';
import 'package:pindl/data/services/download_service.dart';

import '../helpers/fixture_loader.dart';

/// Feed/Board carousel migration (OQ-13) — OQ-13 asked whether a carousel pin
/// reached through a username/board feed should expand into one item per slide.
/// The answer (evidence-backed, live board-feed capture 2026-10-12) is yes:
/// feed rows DO carry every slide in `carousel_data.carousel_slots`, so the
/// expansion is implemented and these tests pin it:
///
///   * a carousel pin produces one download item per slide (feed AND board);
///   * a non-carousel pin keeps its byte-identical single-item behavior;
///   * completion is per ITEM, so a partially downloaded carousel can never be
///     recorded as complete (holes stay holes — D-04 truth table);
///   * the metadata write marks the item-plan coordinate space.
void main() {
  const carouselId = '1108518895813229220';
  const plainId = '222222222222222222';

  group('planFeedItems — carousel expansion (feed + board)', () {
    test('a 3-slide carousel pin becomes 3 items in slot order', () {
      final planned = DownloadCoordinator.planFeedItems(
        pins: [_carouselPin(carouselId, 3)],
        mediaType: MediaType.image,
        imagesFolder: 'PinDL/@u/Images',
        videosFolder: 'PinDL/@u/Videos',
      );

      expect(planned, hasLength(3));
      expect(planned.map((i) => i.slotIndex).toList(), [0, 1, 2]);
      expect(planned.map((i) => i.key).toList(),
          ['${carouselId}_img1', '${carouselId}_img2', '${carouselId}_img3']);
      expect(planned.every((i) => i.role == 'image' && !i.isVideo), isTrue);
      // Slots are resolved to their LARGEST rendition by rank (never map
      // insertion order). The shared upgrade helper deliberately leaves
      // >= 736 px renditions alone, so a 736x slot stays 736x here.
      expect(planned.first.url, contains('/736x/s0/'));
      expect(planned.first.url, isNot(contains('/60x60/')));
    });

    test('board runs reuse the identical planner with board-scoped folders', () {
      final planned = DownloadCoordinator.planFeedItems(
        pins: [_carouselPin(carouselId, 2)],
        mediaType: MediaType.image,
        imagesFolder: 'PinDL/@u/Boards/food-000001/Images',
        videosFolder: 'PinDL/@u/Boards/food-000001/Videos',
      );
      expect(planned, hasLength(2));
      expect(
          planned
              .every((i) => i.subFolder == 'PinDL/@u/Boards/food-000001/Images'),
          isTrue);
    });

    test('non-carousel pins are untouched (one item, pinId key, raw URL)', () {
      final pin = _plainPin(plainId);
      final planned = DownloadCoordinator.planFeedItems(
        pins: [pin],
        mediaType: MediaType.image,
        imagesFolder: 'PinDL/@u/Images',
        videosFolder: 'PinDL/@u/Videos',
      );

      expect(planned, hasLength(1));
      expect(planned.single.slotIndex, isNull);
      expect(planned.single.key, plainId, reason: 'key == pinId, as before');
      expect(planned.single.url, pin.imageUrl,
          reason: 'the single-item URL is NOT rewritten by the migration');
    });

    test('a one-slide carousel stays a single item (no <pinId>_image_1 name)',
        () {
      final planned = DownloadCoordinator.planFeedItems(
        pins: [_carouselPin(carouselId, 1)],
        mediaType: MediaType.image,
        imagesFolder: 'PinDL/@u/Images',
        videosFolder: 'PinDL/@u/Videos',
      );
      expect(planned, hasLength(1));
      expect(planned.single.slotIndex, isNull);
    });

    test('mixed job keeps pin order and shifts later indices by the slides', () {
      final planned = DownloadCoordinator.planFeedItems(
        pins: [
          _plainPin(plainId),
          _carouselPin(carouselId, 4),
          _plainPin('333'),
        ],
        mediaType: MediaType.image,
        imagesFolder: 'PinDL/@u/Images',
        videosFolder: 'PinDL/@u/Videos',
      );
      expect(planned.map((i) => i.pinId).toList(),
          [plainId, carouselId, carouselId, carouselId, carouselId, '333'],
          reason: 'indices are absolute over the expanded plan');
      expect(planned.last.key, '333');
    });

    test('video mode is NOT expanded (video items are one per pin)', () {
      final planned = DownloadCoordinator.planFeedItems(
        pins: [_carouselPin(carouselId, 3)],
        mediaType: MediaType.video,
        imagesFolder: 'PinDL/@u/Images',
        videosFolder: 'PinDL/@u/Videos',
      );
      expect(planned, isEmpty,
          reason: 'the image-only carousel pin carries no video');
    });
  });

  group('runFeedDownload — per-item completion', () {
    test('every slide counts as its own item and is recorded complete',
        () async {
      final service = _FakeFeedService();
      final run = await _run(service: service, pins: [_carouselPin(carouselId, 3)]);

      expect(service.processed, hasLength(3));
      expect(service.processed.map((t) => t.pinId).toList(),
          ['${carouselId}_img1', '${carouselId}_img2', '${carouselId}_img3']);
      expect(service.processed.map((t) => t.filename).toList(),
          ['${carouselId}_image_1.jpg', '${carouselId}_image_2.jpg',
           '${carouselId}_image_3.jpg']);
      expect(run.sessionCompleted, {0, 1, 2});
      expect(run.stats.downloaded, 3);
    });

    test('one failed slide leaves a HOLE — the carousel is not complete',
        () async {
      final service = _FakeFeedService(failKeys: {'${carouselId}_img2'});
      final run = await _run(service: service, pins: [_carouselPin(carouselId, 3)]);

      expect(run.sessionCompleted, {0, 2},
          reason: 'failed = incomplete (D-04); the set is NOT {0,1,2}');
      expect(run.stats.failed, 1);
      final json = run.metadataWrite!.json;
      expect(json['completed_indices'], [0, 2]);
      expect(maxContiguous(run.sessionCompleted), 0,
          reason: 'continue re-offers from the first hole');
    });

    test('an explicit skip IS complete (existing file), like before',
        () async {
      final service = _FakeFeedService(skipKeys: {'${carouselId}_img1'});
      final run = await _run(service: service, pins: [_carouselPin(carouselId, 3)]);
      expect(run.sessionCompleted, {0, 1, 2});
      expect(run.stats.skipped, 1);
      expect(run.stats.downloaded, 2);
    });

    test('cancel mid-run keeps only the completed prefix and reports it',
        () async {
      final service = _FakeFeedService(cancelAfter: 1);
      final run = await _run(service: service, pins: [_carouselPin(carouselId, 3)]);
      expect(run.wasInterrupted, isTrue);
      expect(run.sessionCompleted, {0});
      expect(run.stats.downloaded, 1);
    });

    test('the metadata write marks the expanded item plan', () async {
      final run = await _run(
        service: _FakeFeedService(),
        pins: [_plainPin(plainId), _carouselPin(carouselId, 2)],
      );
      final json = run.metadataWrite!.json;
      expect(json['item_plan'], MetadataReader.feedItemPlanExpanded);
      expect(json['completed_indices'], [0, 1, 2]);
      expect(json['last_index_downloaded'], 2);
    });
  });

  group('PinItem — feed-row slot extraction', () {
    test('snake_case row (board feed) keeps slot order and best rendition', () {
      final pin = PinItem.fromUserPinJson(_carouselRow(carouselId, 3));
      expect(pin.imageSlots, hasLength(3));
      expect(pin.imageSlots.first, 'https://i.pinimg.com/736x/s0/00/11/s0.jpg',
          reason: 'largest rendition wins (736x over 60x60)');
      expect(pin.imageSlots.toSet(), hasLength(3));
      expect(pin.imageSlots.last, contains('/s2/'));
    });

    test('camelCase SSR-page shape resolves flat images_<token> maps', () {
      final pin = PinItem.fromUserPinJson({
        'id': carouselId,
        'title': 't',
        'images': {'orig': {'url': 'https://i.pinimg.com/originals/aa/bb/cc/aabbcc.jpg'}},
        'carouselData': {
          'carouselSlots': [
            {
              'slotId': 's1',
              'images_236x': {'url': 'https://i.pinimg.com/236x/11/22/33/112233.jpg'},
              'images_736x': {'url': 'https://i.pinimg.com/736x/11/22/33/112233.jpg'},
            },
          ],
        },
      });
      expect(pin.imageSlots,
          ['https://i.pinimg.com/736x/11/22/33/112233.jpg'],
          reason: 'largest rendition wins, not insertion order');
    });

    test('a non-carousel row yields no slots', () {
      expect(PinItem.fromUserPinJson(_plainRow(plainId)).imageSlots, isEmpty);
    });

    test('slots survive the persist/read round trip; a legacy pin reads empty',
        () {
      final pin = PinItem.fromUserPinJson(_carouselRow(carouselId, 2));
      final restored = PinItem.fromJson(pin.toJson());
      expect(restored.imageSlots, pin.imageSlots);
      expect(restored, pin, reason: 'Equatable parity');

      // 3.1.0/3.1.1-era metadata: `pins` entries carry no `imageSlots` key.
      final legacyJson = _plainRow(plainId);
      final legacy = PinItem.fromUserPinJson(legacyJson);
      expect(legacy.toJson().containsKey('imageSlots'), isFalse,
          reason: 'empty slots are not serialized — no format noise');
      expect(PinItem.fromJson({'pinId': plainId, 'title': 't'}).imageSlots,
          isEmpty);
    });

    test('feed-row extraction agrees with the single-pin relay extraction',
        () {
      // Two entry points, ONE payload: the feed/board helper and the
      // single-pin parser's slot chain must not disagree about the URLs
      // (the fixture carries the camelCase relay shape with 3 slots).
      final html = Fixtures.pinCarousel();
      final record = _relayRecordOf(html);
      final fromParser = PinterestParser.parseMediaData(html, carouselId)!
          .slots
          .map((s) => s.imageUrl)
          .toList();
      final fromHelper = carouselSlotUrlsFromRow(record);
      expect(fromHelper, hasLength(3));
      expect(fromHelper, fromParser,
          reason: 'one slot list, two readers, same URLs in the same order');
    });
  });

  group('metadata + board resume coordinate markers', () {
    test('item_plan round-trips and defaults to absent for legacy files', () {
      final json = MetadataReader.buildV2Metadata(
        author: const Author(username: 'u', name: 'n', userId: '1'),
        pins: [_plainPin(plainId)],
        completedIndices: {0},
        totalImages: 1,
        totalVideos: 0,
        successDownloaded: 1,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
        itemPlan: MetadataReader.feedItemPlanExpanded,
      );
      expect(MetadataReader.read(json).itemPlan,
          MetadataReader.feedItemPlanExpanded);

      final legacy = MetadataReader.buildV2Metadata(
        author: const Author(username: 'u', name: 'n', userId: '1'),
        pins: const [],
        completedIndices: const {},
        totalImages: 0,
        totalVideos: 0,
        successDownloaded: 0,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
      );
      expect(legacy.containsKey('item_plan'), isFalse);
      expect(MetadataReader.read(legacy).itemPlan, isNull);

      // Malformed values are treated as ABSENT (never as "expanded").
      expect(
          MetadataReader.read({'schema': 2, 'item_plan': 7}).itemPlan, isNull);
      expect(MetadataReader.read({'schema': 2, 'item_plan': ''}).itemPlan,
          isNull);
    });

    test('board resume carries the planned item count + plan marker', () {
      const resume = BoardTypeResume(
        completedIndices: {0, 1, 2, 3},
        items: 6,
        plan: MetadataReader.feedItemPlanExpanded,
      );
      final parsed = BoardTypeResume.tryParse(resume.toJson())!;
      expect(parsed.items, 6);
      expect(parsed.plan, MetadataReader.feedItemPlanExpanded);
      expect(parsed.completedIndices, {0, 1, 2, 3});
    });

    test('legacy board resume block stays readable and untranslated', () {
      final parsed = BoardTypeResume.tryParse({
        'completed_indices': [0, 1],
        'success_downloaded': 2,
      })!;
      expect(parsed.items, isNull,
          reason: 'legacy entry → the pin-count comparison applies');
      expect(parsed.plan, isNull);
      // Malformed markers degrade to null (D-26 tolerant reader).
      expect(BoardTypeResume.tryParse({'items': 'six', 'plan': 5})!.items,
          isNull);
      expect(BoardTypeResume.tryParse({'items': 'six', 'plan': 5})!.plan,
          isNull);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Synthetic feed/board row: `carousel_data.carousel_slots[n]` as served by the
/// resource APIs (live-verified shape; URLs are synthetic per the fixtures
/// PII rule, the shape is the point).
Map<String, dynamic> _carouselRow(String pinId, int slides) => {
      'id': pinId,
      'title': 'carousel',
      'images': {
        'orig': {'url': 'https://i.pinimg.com/originals/aa/bb/cc/aaabbbccc.jpg'},
      },
      'carousel_data': {
        'carousel_slots': [
          for (var i = 0; i < slides; i++)
            {
              'id': 'slot$i',
              'images': {
                '60x60': {
                  'url': 'https://i.pinimg.com/60x60/s$i/00/11/s$i.jpg',
                  'width': 60,
                  'height': 60,
                },
                '736x': {
                  'url': 'https://i.pinimg.com/736x/s$i/00/11/s$i.jpg',
                  'width': 736,
                  'height': 981,
                },
              },
            },
        ],
      },
    };

Map<String, dynamic> _plainRow(String pinId) => {
      'id': pinId,
      'title': 'plain',
      'images': {
        'orig': {'url': 'https://i.pinimg.com/originals/aa/bb/cc/aabbcc.jpg'},
      },
      'videos': [],
    };

PinItem _carouselPin(String pinId, int slides) =>
    PinItem.fromUserPinJson(_carouselRow(pinId, slides));

PinItem _plainPin(String pinId) => PinItem.fromUserPinJson(_plainRow(pinId));

/// The relay record JSON embedded in an SSR fixture (the object the parser's
/// candidate-record scan walks), so the feed helper can be handed the exact
/// same input.
Map<String, dynamic> _relayRecordOf(String html) {      final match = RegExp(r'closeup:\d+"\s*,\s*(\{.*?\})\);', dotAll: true)
          .firstMatch(html);
  final decoded = jsonDecode(match!.group(1)!) as Map<String, dynamic>;
  final data = decoded['data'] as Map<String, dynamic>;
  final closeup = data['pin_closeup'] as Map<String, dynamic>;
  return closeup['data'] as Map<String, dynamic>;
}

Future<FeedDownloadResult> _run({
  required DownloadService service,
  required List<PinItem> pins,
  bool isContinue = false,
  Set<int> previousCompleted = const {},
  int lastIndex = -1,
}) {
  final token = CancelToken();
  (service as _FakeFeedService).cancelToken ??= token;
  final coordinator = DownloadCoordinator(
    downloadService: service,
    hooks: DownloadCoordinatorHooks(
      queue: (_) {},
      downloading: (_) {},
      saved: (_) {},
      skipped: (_) {},
      failed: (_) {},
      parse: (_) {},
      error: (_) {},
      interrupted: (_) {},
      complete: (_) {},
      onFfmpegLog: (_) {},
      onHistory:
          ({required filename, required url, required success, errorMessage}) {},
      mapError: (e) => e.toString(),
    ),
  )..cancelToken = token;
  return coordinator.runFeedDownload(
    pins: pins,
    author: const Author(username: 'u', name: 'n', userId: '1'),
    mediaType: MediaType.image,
    outputPath: 'Downloads/PinDL',
    overwrite: true,
    saveMetadata: true,
    isContinueMode: isContinue,
    lastIndexDownloaded: lastIndex,
    previousMediaType: isContinue ? 'image' : null,
    previousCompletedIndices: previousCompleted,
    totalImages: pins.length,
    totalVideos: 0,
    previousDownloaded: 0,
    previousSkipped: 0,
    previousFailed: 0,
    nextBookmark: null,
    bookmarkContext: null,
    onStats: ({downloadedDelta, skippedDelta, failedDelta, indexDelta}) {},
  );
}

class _Queued {
  final String id;
  final String pinId;
  final String filename;
  final String url;
  final String subFolder;

  _Queued({
    required this.id,
    required this.pinId,
    required this.filename,
    required this.url,
    required this.subFolder,
  });
}

/// Queue-shaped fake: mirrors what `DownloadService.processQueue` reports back
/// (item key = the `pinId` the coordinator queued) so completion math is
/// exercised end to end without any I/O.
class _FakeFeedService extends DownloadService {
  _FakeFeedService({
    this.failKeys = const {},
    this.skipKeys = const {},
    this.cancelAfter,
  }) : super(dio: Dio());

  final Set<String> failKeys;
  final Set<String> skipKeys;
  final int? cancelAfter;

  /// The coordinator's live cancel token (mirrors `provider.cancelToken`):
  /// the fake cancels it mid-queue to reproduce a user cancel.
  CancelToken? cancelToken;

  final List<_Queued> queued = [];

  /// Every task the fake was asked to enqueue (the queue drains into
  /// [processed] when `processQueue` runs, exactly like the real service).
  final List<_Queued> processed = [];

  @override
  Future<bool> fileExistsInDownloads(String filename, String subFolder) async =>
      false;

  @override
  void enqueue({
    required String id,
    required String pinId,
    required String title,
    required String url,
    required String outputPath,
    required String filename,
    required bool overwrite,
    String? subFolder,
  }) {
    queued.add(_Queued(
      id: id,
      pinId: pinId,
      filename: filename,
      url: url,
      subFolder: subFolder ?? '',
    ));
  }

  @override
  Future<void> processQueue({
    required void Function(String pinId) onCompleted,
    required void Function(String pinId, String reason) onSkipped,
    required void Function(String pinId, String error) onFailed,
    required bool overwrite,
    void Function(int current, int total)? onProgress,
    String subFolder = 'PinDL',
  }) async {
    final batch = List<_Queued>.from(queued);
    processed.addAll(batch);
    queued.clear();
    var handled = 0;
    for (final task in batch) {
      if (cancelAfter != null && handled >= cancelAfter!) {
        cancelToken?.cancel('user cancelled');
        return;
      }
      handled++;
      if (failKeys.contains(task.pinId)) {
        onFailed(task.pinId, 'synthetic failure');
      } else if (skipKeys.contains(task.pinId)) {
        onSkipped(task.pinId, 'File exists');
      } else {
        onCompleted(task.pinId);
      }
    }
  }
}
