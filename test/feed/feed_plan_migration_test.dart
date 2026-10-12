import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/persistence/metadata_schema.dart';
import 'package:pindl/data/controllers/download_coordinator.dart';
import 'package:pindl/data/controllers/feed_plan_migration.dart';
import 'package:pindl/data/models/job_state.dart';
import 'package:pindl/data/models/pin_item.dart';

/// Feed/Board carousel migration — backward compatibility of the resume
/// contract (the "will this break someone's half-finished job?" question).
///
/// The completion record is a set of ABSOLUTE indices into the planned item
/// list. Expanding carousel pins changes that list, so a stored record written
/// before the migration means something different. These tests pin the
/// translation, the identity paths, and the conservative failure direction:
/// anything the translation cannot PROVE is re-offered, never skipped.
void main() {
  const carouselId = '1108518895813229220';
  const plainA = '111';
  const plainB = '222';

  List<PlannedDownload> plan(List<PinItem> pins) =>
      DownloadCoordinator.planFeedItems(
        pins: pins,
        mediaType: MediaType.image,
        imagesFolder: 'PinDL/@u/Images',
        videosFolder: 'PinDL/@u/Videos',
      );

  StoredCompletionMapping mapped({
    required List<PinItem> pins,
    required Set<int> stored,
    String? storedItemPlan,
  }) =>
      mapStoredCompletionToPlan(
        plannedItems: plan(pins),
        pins: pins,
        storedCompleted: stored,
        storedItemPlan: storedItemPlan,
        mediaType: MediaType.image,
      );

  group('legacy pin-level record + expanded plan (the upgrade path)', () {
    test('a completed pin maps to its FIRST slide — later slides stay undone',
        () {
      // Legacy plan: [pin0(plain), pin1(carousel 3 slides), pin2(plain)]
      // → indices 0,1,2. Expanded: 0, 1..3 (slots), 4.
      final pins = [
        _plainPin(plainA),
        _carouselPin(carouselId, 3),
        _plainPin(plainB),
      ];
      final result =
          mapped(pins: pins, stored: {0, 1, 2}, storedItemPlan: null);

      expect(result.translated, isTrue);
      expect(result.completedIndices, {0, 1, 4},
          reason: 'the carousel pin maps to slide 1 only — slides 2/3 were '
              'never downloaded by the old version and must be offered');
      expect(result.dropped, 0);
    });

    test('a legacy HOLE stays a hole and everything after is offered', () {
      final pins = [_carouselPin(carouselId, 3), _plainPin(plainA)];
      final result = mapped(pins: pins, stored: {1}, storedItemPlan: null);

      expect(result.completedIndices, {3});
      expect(maxContiguous(result.completedIndices), -1,
          reason: 'nothing before the first hole is provably complete');
    });

    test('the legacy item sequence is the PIN sequence, not raw pin order',
        () {
      // pin1 carries no image at all → the old planner emitted no item for
      // it, so legacy index 1 is pin2, NOT pin1.
      final pins = [
        _plainPin(plainA),
        _videoOnlyPin('333'),
        _plainPin(plainB),
      ];
      final result = mapped(pins: pins, stored: {0, 1}, storedItemPlan: null);

      expect(result.completedIndices, {0, 1},
          reason: 'no carousels here → identity path anyway');
      expect(result.translated, isFalse);
    });

    test('a video pin\'s thumbnail item keeps its own legacy position', () {
      // Legacy plan (image mode): plainA(0), videoThumb(1), carousel(2),
      // plainB(3). Expanded: plainA(0), videoThumb(1), carousel 2..4,
      // plainB(5) — the thumbnail item is a real item in both spaces.
      final pins = [
        _plainPin(plainA),
        _videoOnlyPin('333'),
        _carouselPin(carouselId, 3),
        _plainPin(plainB),
      ];
      final result =
          mapped(pins: pins, stored: {0, 1, 2, 3}, storedItemPlan: null);

      expect(result.translated, isTrue);
      expect(result.completedIndices, {0, 1, 2, 5},
          reason: 'legacy index 2 = the carousel → its first slide; '
              'legacy index 3 = plainB → shifted to 5 by the carousel slides');
    });

    test('an unprovable identity is dropped (re-offered), never assumed', () {
      // Slot 0 of the row resolves to a DIFFERENT image than the pin's
      // primary: the old run downloaded the primary, so slide 1 cannot be
      // called complete.
      final pin = PinItem.fromUserPinJson({
        'id': carouselId,
        'title': 'mismatch',
        'images': {
          'orig': {'url': 'https://i.pinimg.com/originals/aa/00/bb/primary.jpg'},
        },
        'carousel_data': {
          'carousel_slots': [
            {
              'images': {
                '736x': {'url': 'https://i.pinimg.com/736x/cc/11/dd/other.jpg'},
              },
            },
            {
              'images': {
                '736x': {'url': 'https://i.pinimg.com/736x/ee/22/ff/second.jpg'},
              },
            },
          ],
        },
      });
      final result = mapped(pins: [pin], stored: {0}, storedItemPlan: null);

      expect(result.completedIndices, isEmpty);
      expect(result.dropped, 1,
          reason: 'unknown identity → re-download, never a silent skip');
    });

    test('out-of-range legacy indices are dropped (tolerant reader)', () {
      final pins = [_carouselPin(carouselId, 2), _plainPin(plainA)];
      final result =
          mapped(pins: pins, stored: {0, 5, -1, 1}, storedItemPlan: null);

      expect(result.completedIndices, {0, 2});
      expect(result.dropped, 2);
    });

    test('a legacy record for a media type that is not in the plan is dropped',
        () {
      // Video mode plan → no image items at all; a legacy IMAGE record cannot
      // be carried over.
      final pins = [_carouselPin(carouselId, 3)];
      final result = mapStoredCompletionToPlan(
        plannedItems: DownloadCoordinator.planFeedItems(
          pins: pins,
          mediaType: MediaType.video,
          imagesFolder: 'PinDL/@u/Images',
          videosFolder: 'PinDL/@u/Videos',
        ),
        pins: pins,
        storedCompleted: {0},
        storedItemPlan: null,
        mediaType: MediaType.video,
      );
      expect(result.translated, isFalse,
          reason: 'no multi-item pin → identity (the video plan is unchanged)');
      expect(result.completedIndices, {0});
    });
  });

  group('identity paths (no translation)', () {
    test('a plan without carousels resumes byte-identically', () {
      final pins = [_plainPin(plainA), _plainPin(plainB)];
      final result =
          mapped(pins: pins, stored: {0, 1}, storedItemPlan: null);
      expect(result.translated, isFalse);
      expect(result.completedIndices, {0, 1});
      expect(result.dropped, 0);
    });

    test('expanded coordinates are trusted as-is (item_plan marker)', () {
      final pins = [_carouselPin(carouselId, 3), _plainPin(plainA)];
      final result = mapped(
        pins: pins,
        stored: {0, 1, 2, 3},
        storedItemPlan: MetadataReader.feedItemPlanExpanded,
      );
      expect(result.translated, isFalse);
      expect(result.completedIndices, {0, 1, 2, 3},
          reason: 'this version wrote those indices in expanded space');
    });

    test('a legacy record on a legacy-shaped plan is never re-projected', () {
      // The realistic "resume an old job" case: the pins come from the old
      // metadata (no slots) → the plan is pin-level → identity.
      final pins = [
        PinItem.fromJson({
          'pinId': plainA,
          'title': 'legacy',
          'imageUrl': 'https://i.pinimg.com/originals/aa/bb/cc/x.jpg',
          'hasImage': true,
        }),
        PinItem.fromJson({
          'pinId': plainB,
          'title': 'legacy',
          'imageUrl': 'https://i.pinimg.com/originals/aa/bb/cc/y.jpg',
          'hasImage': true,
        }),
      ];
      final result = mapped(pins: pins, stored: {0}, storedItemPlan: null);

      expect(pins.every((p) => p.imageSlots.isEmpty), isTrue);
      expect(result.translated, isFalse);
      expect(result.completedIndices, {0});
    });
  });

  group('legacyPlanItems — the pre-migration planner model', () {
    test('parity with planFeedItems on pins without carousels (image)', () {
      final pins = [
        _plainPin(plainA),
        _videoOnlyPin('333'),
        _plainPin(plainB),
      ];
      final legacy = legacyPlanItems(pins: pins, mediaType: MediaType.image);
      final planned = plan(pins);

      expect(legacy.map((i) => i.pinId).toList(),
          planned.map((i) => i.pinId).toList());
      expect(legacy.map((i) => i.url).toList(),
          planned.map((i) => i.url).toList(),
          reason: 'the legacy model must not drift from the old planner');
    });

    test('parity on video mode (HLS and MP4 pins alike)', () {
      final pins = [
        _videoOnlyPin('v1'),
        _plainPin(plainA),
        _videoOnlyPin('v2'),
      ];
      final legacy = legacyPlanItems(pins: pins, mediaType: MediaType.video);
      final planned = DownloadCoordinator.planFeedItems(
        pins: pins,
        mediaType: MediaType.video,
        imagesFolder: 'PinDL/@u/Images',
        videosFolder: 'PinDL/@u/Videos',
      );
      expect(legacy.map((i) => i.pinId).toList(),
          planned.map((i) => i.pinId).toList());
    });

    test('a video pin in image mode falls back to its thumbnail', () {
      final legacy = legacyPlanItems(
        pins: [_videoOnlyPin('333')],
        mediaType: MediaType.image,
      );
      expect(legacy.single.url, contains('/60x60/'),
          reason: 'thumbnail fallback is part of the legacy item shape');
    });
  });

  group('image identity helper', () {
    test('rendition token is not part of the identity', () {
      expect(
        pinterestImageIdentity('https://i.pinimg.com/736x/aa/bb/cc/abc.jpg'),
        pinterestImageIdentity('https://i.pinimg.com/originals/aa/bb/cc/abc.jpg'),
      );
    });

    test('different files, different identities; junk → null', () {
      expect(
        pinterestImageIdentity('https://i.pinimg.com/736x/aa/bb/cc/one.jpg'),
        isNot(pinterestImageIdentity(
            'https://i.pinimg.com/736x/aa/bb/cc/two.jpg')),
      );
      expect(pinterestImageIdentity(''), isNull);
      expect(pinterestImageIdentity(null), isNull);
      expect(pinterestImageIdentity('https://i.pinimg.com/videos/iht/hls'), isNull,
          reason: 'no file name → no provable identity');
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

PinItem _plainPin(String pinId) => PinItem.fromUserPinJson({
      'id': pinId,
      'title': 'plain',
      'images': {
        'orig': {'url': 'https://i.pinimg.com/originals/aa/bb/cc/$pinId.jpg'},
      },
      'videos': [],
    });

PinItem _videoOnlyPin(String pinId) => PinItem.fromUserPinJson({
      'id': pinId,
      'title': 'video',
      // Real feed rows for story pins carry video data ONLY under
      // story_pin_data (the `videos` key is null), which is exactly the shape
      // the model's HLS fallback chain handles.
      'videos': null,
      'story_pin_data': {
        'pages': [
          {
            'blocks': [
              {
                'video': {
                  'video_list': {
                    'V_720P': {
                      'url': 'https://v1.pinimg.com/videos/$pinId/00/11/x_720w.mp4',
                      'thumbnail':
                          'https://i.pinimg.com/60x60/$pinId/00/11/$pinId.jpg',
                    },
                  },
                },
              },
            ],
          },
        ],
      },
    });

/// Carousel pin as feed/board rows serve it. Slot 0 shares the row's PRIMARY
/// image file name — the live-verified relationship (board-feed capture
/// 2026-10-12: `images.orig` and `carousel_slots[0].images.736x` are the same
/// hash, and both answer 200 with the same image) that makes the legacy
/// re-projection provable instead of assumed.
PinItem _carouselPin(String pinId, int slides) => PinItem.fromUserPinJson({
      'id': pinId,
      'title': 'carousel',
      'images': {
        'orig': {'url': 'https://i.pinimg.com/originals/aa/bb/cc/$pinId.jpg'},
      },
      'carousel_data': {
        'carousel_slots': [
          for (var i = 0; i < slides; i++)
            {
              'images': {
                '736x': {
                  'url': i == 0
                      ? 'https://i.pinimg.com/736x/aa/bb/cc/$pinId.jpg'
                      : 'https://i.pinimg.com/736x/aa/bb/cc/${pinId}_s$i.jpg',
                },
              },
            },
        ],
      },
    });
