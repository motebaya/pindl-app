import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/controllers/download_coordinator.dart';
import 'package:pindl/data/models/board_selection.dart';
import 'package:pindl/data/models/job_state.dart';
import 'package:pindl/data/models/pin_item.dart';

void main() {
  group('boardFolder — D-39 layout (Phase 10.4 decision in code)', () {
    test('folder = PinDL/@user/Boards/<slug>-<id-suffix6>', () {
      expect(
        DownloadCoordinator.boardFolder(
          username: 'alice',
          slug: 'my-recipes',
          boardId: '111111222222333333',
        ),
        'PinDL/@alice/Boards/my-recipes-333333',
      );
    });

    test('slug is sanitized (STO-3 charset rules; spaces → dashes)', () {
      expect(
        DownloadCoordinator.boardFolder(
          username: 'alice',
          slug: 'weird:slug/with*chars',
          boardId: '111111222222333333',
        ),
        'PinDL/@alice/Boards/weirdslugwithchars-333333',
      );
      expect(
        DownloadCoordinator.boardFolder(
          username: 'alice',
          slug: 'two words',
          boardId: '111111222222333333',
        ),
        'PinDL/@alice/Boards/two-words-333333',
      );
    });

    test('empty slug falls back to "board"', () {
      expect(
        DownloadCoordinator.boardFolder(
          username: 'alice',
          slug: '***',
          boardId: '999999',
        ),
        'PinDL/@alice/Boards/board-999999',
      );
    });

    test('slug collision → deterministic longer id suffix (no drift)', () {
      // Two boards with the SAME slug but different ids.
      final a = DownloadCoordinator.boardFolder(
        username: 'alice', slug: 'food', boardId: '111111111111000001',
      );
      final b = DownloadCoordinator.boardFolder(
        username: 'alice', slug: 'food', boardId: '111111111111000002',
        usedFolders: {a.toLowerCase()},
      );
      expect(a, 'PinDL/@alice/Boards/food-000001');
      expect(b, isNot(a));
      expect(b, startsWith('PinDL/@alice/Boards/food-'));
      expect(b.endsWith('000002'), isTrue,
          reason: 'collision extends the identity suffix, still deterministic');
    });

    test('short boardId used whole as suffix', () {
      expect(
        DownloadCoordinator.boardFolder(
            username: 'u', slug: 'x', boardId: '42'),
        'PinDL/@u/Boards/x-42',
      );
    });
  });

  group('planBoardRuns — D-38 sequential run planning', () {
    test('skips are dropped; order = selection display order', () {
      final runs = DownloadCoordinator.planBoardRuns(
        username: 'alice',
        selection: BoardSelection(choices: [
          _choice('b1', mode: BoardDownloadMode.skip),
          _choice('b2', mode: BoardDownloadMode.whole),
          _choice('b3', mode: BoardDownloadMode.sections),
        ]),
      );
      expect(runs.map((r) => r.choice.boardId).toList(), ['b2', 'b3']);
    });

    test('every run gets a unique folder even with identical slugs', () {
      final runs = DownloadCoordinator.planBoardRuns(
        username: 'alice',
        selection: BoardSelection(choices: [
          _choice('111111111111000001', slug: 'food',
              mode: BoardDownloadMode.whole),
          _choice('111111111111000002', slug: 'food',
              mode: BoardDownloadMode.whole),
        ]),
      );
      final folders = runs.map((r) => r.baseFolder).toSet();
      expect(folders, hasLength(2));
    });
  });

  group('board pins reuse the feed planner (D-38 core claim)', () {
    test('planFeedItems maps board pins identically to feed pins', () {
      final pins = [
        _pin('p1', hasImage: true),
        _pin('p2', hasVideo: true),
        _pin('p3', hasImage: false),
      ];
      final planned = DownloadCoordinator.planFeedItems(
        pins: pins,
        mediaType: MediaType.image,
        imagesFolder: 'PinDL/@u/Boards/x-1/Images',
        videosFolder: 'PinDL/@u/Boards/x-1/Videos',
      );
      expect(planned, hasLength(2));
      expect(planned.every((i) =>
          i.subFolder.startsWith('PinDL/@u/Boards/x-1/')), isTrue,
          reason: 'board-scoped folders flow through the UNCHANGED planner');
    });
  });
}

BoardChoice _choice(String id,
        {String slug = 'food', BoardDownloadMode mode = BoardDownloadMode.skip}) =>
    BoardChoice(
      boardId: id,
      slug: slug,
      name: 'Food',
      mode: mode,
      boardPinCount: 3,
    );

PinItem _pin(String id, {bool hasImage = false, bool hasVideo = false}) {
  final pin = PinItem.fromUserPinJson({
    'id': id,
    'title': 't',
    if (hasImage)
      'images': {
        'orig': {'url': 'https://i.pinimg.com/originals/$id.jpg'}
      },
    if (hasVideo)
      'videos': {
        'video_list': {
          'V_720P': {
            'url': 'https://v1.pinimg.com/videos/mc/720p/$id.mp4',
            'thumbnail': 'https://i.pinimg.com/videos/thumbnails/$id.jpg',
          }
        }
      },
  });
  return pin;
}
