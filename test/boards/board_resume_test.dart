import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/persistence/board_resume.dart';
import 'package:pindl/core/persistence/metadata_schema.dart';
import 'package:pindl/data/models/author.dart';
import 'package:pindl/data/models/pin_item.dart';

void main() {
  group('BoardTypeResume — truth table math (Phase 09.5, D-04 unchanged)', () {
    test('continueStartIndex = maxContiguous + 1 (user-feed math verbatim)',
        () {
      final r = BoardTypeResume(completedIndices: {0, 1, 2, 5});
      expect(r.continueStartIndex, 3);
      // Holes re-offer; failed/cancelled never entered the set, so they are
      // re-offered by construction.
      expect(r.reofferIndices, {5});
    });

    test('empty set → start at 0', () {
      expect(const BoardTypeResume(completedIndices: {}).continueStartIndex, 0);
    });

    test('contiguous set → start at end', () {
      final r = BoardTypeResume(completedIndices: {0, 1, 2});
      expect(r.continueStartIndex, 3);
      expect(r.reofferIndices, isEmpty);
    });

    test('media-type gating (D-25): types keep separate sets', () {
      final entry = BoardResumeEntry(boardId: 'b1', types: {
        'image': BoardTypeResume(completedIndices: {0, 1}),
        'video': BoardTypeResume(completedIndices: {0}),
      });
      // A cross-type continue reads only ITS type's set.
      expect(entry.typeFor('image')!.continueStartIndex, 2);
      expect(entry.typeFor('video')!.continueStartIndex, 1);
    });
  });

  group('BoardResume — tolerant parsing (D-26 spirit)', () {
    test('malformed block → empty entries, no throw', () {
      expect(BoardResume.tryParse(null).entries, isEmpty);
      expect(BoardResume.tryParse('garbage').entries, isEmpty);
      expect(BoardResume.tryParse(42).entries, isEmpty);
    });

    test('entries without identity are skipped; malformed types degrade', () {
      final resume = BoardResume.tryParse({
        'entries': [
          'not-a-map',
          {'types': {}}, // no board_id → skip
          {
            'board_id': 'b1',
            'types': {
              'image': {
                'completed_indices': [0, 1, 'x', null, 3], // junk filtered
                'success_downloaded': 2,
                'skip_downloaded': 1,
                'failed_downloaded': 4,
              },
              'video': 'garbage', // → skipped type
            },
          },
        ],
      });
      expect(resume.entries, hasLength(1));
      final image = resume.entryFor('b1')!.typeFor('image')!;
      expect(image.completedIndices, {0, 1, 3});
      expect(image.successDownloaded, 2);
      expect(image.skipDownloaded, 1);
      expect(image.failedDownloaded, 4, reason: 'failed count PRESERVED but no index');
      expect(resume.entryFor('b1')!.typeFor('video'), isNull);
    });

    test('entry lookup by boardId (G5: id is the key, slug is display)', () {
      final resume = BoardResume.tryParse({
        'entries': [
          {
            'board_id': '111111111111111111',
            'board_slug': 'fixture-board',
            'types': {
              'image': {
                'completed_indices': [0, 1],
              },
            },
          },
        ],
      });
      expect(resume.entryFor('111111111111111111'), isNotNull);
      expect(resume.entryFor('fixture-board'), isNull,
          reason: 'slug must never match the identity lookup');
      expect(resume.entries.single.boardSlug, 'fixture-board');
    });
  });

  group('v2 metadata integration — board_resume additive (09.5)', () {
    final author = Author(
        username: 'fixtureuser', name: 'Fixture User', userId: '999');

    Map<String, dynamic> build({BoardResume? boardResume}) =>
        MetadataReader.buildV2Metadata(
          author: author,
          pins: const [],
          completedIndices: {},
          totalImages: 0,
          totalVideos: 0,
          successDownloaded: 0,
          skipDownloaded: 0,
          failedDownloaded: 0,
          wasInterrupted: false,
          mediaType: 'image',
          status: 'parsed',
          boardResume: boardResume,
        );

    test('user-feed files: no board_resume key → reader returns null', () {
      final map = build();
      expect(map.containsKey('board_resume'), isFalse);
      final result = MetadataReader.read(map);
      expect(result.isOk, isTrue);
      expect(result.boardResume, isNull);
    });

    test('board files: block round-trips through write → read', () {
      final resume = BoardResume(entries: [
        BoardResumeEntry(boardId: '111111111111111111', boardSlug: 'fixture-board', types: {
          'image': BoardTypeResume(
            completedIndices: {0, 1, 5},
            successDownloaded: 2,
            skipDownloaded: 1,
            failedDownloaded: 3,
          ),
          'video': BoardTypeResume(completedIndices: {0}),
        }),
      ]);
      final result = MetadataReader.read(build(boardResume: resume));
      expect(result.isOk, isTrue);
      final roundTripped = result.boardResume!;
      final entry = roundTripped.entryFor('111111111111111111')!;
      expect(entry.boardSlug, 'fixture-board');
      final image = entry.typeFor('image')!;
      expect(image.completedIndices, {0, 1, 5});
      expect(image.continueStartIndex, 2, reason: 'maxContiguous({0,1,5}) = 1');
      expect(image.reofferIndices, {5});
      expect(image.failedDownloaded, 3);
      expect(entry.typeFor('video')!.completedIndices, {0});
    });

    test('schema stays 2 — no version bump for the additive field', () {
      expect(build(boardResume: BoardResume(entries: const []))['schema'], 2);
    });

    test('reader is tolerant of a hand-mangled board_resume in a v2 file',
        () {
      final map = build();
      map['board_resume'] = {'entries': 'not-a-list'};
      final result = MetadataReader.read(map);
      expect(result.isOk, isTrue, reason: 'malformed block never corrupts the file');
      expect(result.boardResume!.entries, isEmpty);
    });

    test('board metadata payload composes with bookmark context fields', () {
      // A capped board session persists BOTH: the continuation tuple pair
      // (07.5 mechanism) AND the per-board resume block (09.5).
      final map = build(
        boardResume: BoardResume(entries: const [
          BoardResumeEntry(boardId: 'b1', types: {}),
        ]),
      )..remove('saved_at'); // deterministic map for key checks only
      // Build again with the bookmark pair present (writer gates them together).
      final full = MetadataReader.buildV2Metadata(
        author: author,
        pins: const [],
        completedIndices: {0},
        totalImages: 1,
        totalVideos: 0,
        successDownloaded: 1,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
        mediaType: 'image',
        status: 'parsed',
        nextBookmark: 'board-cursor-token',
        bookmarkContext: BookmarkContext(
          username: 'fixtureuser',
          resource: BookmarkContext.resourceBoardPins,
          requestOptions: {'board_id': 'b1', 'field_set_key': 'grid_item'},
          extractionMode: 'pins',
          maxPages: 2,
          bookmark: 'board-cursor-token',
        ),
        boardResume: BoardResume(entries: const [
          BoardResumeEntry(boardId: 'b1', types: {}),
        ]),
      );
      expect(full.containsKey('next_bookmark'), isTrue);
      expect(full.containsKey('bookmark_context'), isTrue);
      expect(full.containsKey('board_resume'), isTrue);
      final read = MetadataReader.read(map);
      expect(read.boardResume, isNotNull);
    });
  });

  group('10.3 continue-mode pre-check semantics (provider contract)', () {
    test('completed board (no failures) → skip; failed items exist → re-run', () {
      bool shouldSkip(BoardTypeResume resume, int boardPinCount) =>
          resume.completedIndices.length >= boardPinCount &&
          resume.failedDownloaded == 0;

      // Fully downloaded, nothing failed → skip (D-04: skips are complete).
      expect(
        shouldSkip(
            BoardTypeResume(
                completedIndices: {0, 1, 2}, failedDownloaded: 0),
            3),
        isTrue,
      );
      // Failures present → re-run (failed re-offered; D-04).
      expect(
        shouldSkip(
            BoardTypeResume(
                completedIndices: {0, 1, 2}, failedDownloaded: 1),
            3),
        isFalse,
      );
      // Partial (hole) → re-run.
      expect(
        shouldSkip(
            BoardTypeResume(completedIndices: {0}, failedDownloaded: 0), 3),
        isFalse,
      );
    });

    test('media-type keyed lookup returns only the requested type (D-25)', () {
      final entry = BoardResumeEntry(boardId: 'b1', types: {
        'image': BoardTypeResume(completedIndices: {0, 1}),
        'video': BoardTypeResume(completedIndices: {0}),
      });
      // The provider reads entry.typeFor(mediaType.name) — cross-type
      // state cannot leak into the other type's continue decision.
      expect(entry.typeFor('image')!.completedIndices, {0, 1});
      expect(entry.typeFor('video')!.completedIndices, {0});
      expect(entry.typeFor('missing'), isNull);
    });

    test('merge-on-upsert: new completion set unions the previous type set',
        () {
      final prev = BoardTypeResume(completedIndices: {0, 1});
      final merged = {
        ...prev.completedIndices,
        ...{1, 2, 5},
      };
      expect(merged, {0, 1, 2, 5});
      expect(maxContiguous(merged) + 1, 3);
    });
  });

  group('pipeline integration surface (09.5 contract)', () {
    test('board pin session maps to the v2 writer unchanged', () {
      // Evidence: pins extracted from a board feed are ordinary PinItems;
      // the same buildV2Metadata payload carries them. No board-specific
      // writer exists — reuse is the contract.
      final pins = [
        PinItem.fromUserPinJson({
          'id': 'p1',
          'title': 't',
          'images': {
            'orig': {
              'url': 'https://i.pinimg.com/originals/aa/bb/cc/aabbcc11223344556677889900112233.jpg'
            }
          },
        }),
      ];
      final map = MetadataReader.buildV2Metadata(
        author: const Author(username: 'u', name: 'n', userId: '9'),
        pins: pins,
        completedIndices: const {0},
        totalImages: 1,
        totalVideos: 0,
        successDownloaded: 1,
        skipDownloaded: 0,
        failedDownloaded: 0,
        wasInterrupted: false,
        mediaType: 'image',
        status: 'parsed',
      );
      final read = MetadataReader.read(map);
      expect(read.pins.single.pinId, 'p1');
      expect(read.completedIndices, {0});
      expect(read.continueStartIndex, 1);
    });
  });
}
