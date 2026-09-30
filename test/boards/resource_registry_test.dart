import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/constants/pinterest_constants.dart';
import 'package:pindl/data/pinterest/resources.dart';

void main() {
  group('resource registry — completeness (Phase 09.1)', () {
    test('exposes exactly the four contract resources', () {
      expect(
        PinterestResources.all.map((d) => d.name).toList(),
        ['user.boards', 'board.sections', 'board.sectionPins', 'board.pins'],
      );
    });

    test('endpoints match the constants file (single source of truth)', () {
      expect(PinterestResources.userBoards.resourcePath,
          PinterestConstants.boardsResource);
      expect(PinterestResources.boardSections.resourcePath,
          PinterestConstants.boardSectionsResource);
      expect(PinterestResources.boardSectionPins.resourcePath,
          PinterestConstants.boardSectionPinsResource);
      expect(PinterestResources.boardPins.resourcePath,
          PinterestConstants.boardFeedResource);
    });

    test('per-resource pwsHandler variation is preserved', () {
      // Profile-scoped resources use the username handler; board-scoped ones
      // use the board handler (audit extraction.md: per-resource variation).
      expect(PinterestResources.userBoards.pwsHandler, 'www/[username].js');
      expect(PinterestResources.boardSections.pwsHandler, 'www/board/[slug].js');
      expect(
          PinterestResources.boardSectionPins.pwsHandler, 'www/board/[slug].js');
      expect(PinterestResources.boardPins.pwsHandler, 'www/board/[slug].js');
    });

    test('source_url templates carry the right placeholders', () {
      expect(PinterestResources.userBoards.sourceUrl, '/:username/');
      expect(PinterestResources.boardSections.sourceUrl, '/:username/:board_slug/');
      expect(
          PinterestResources.boardSectionPins.sourceUrl, '/:username/:board_slug/');
      expect(PinterestResources.boardPins.sourceUrl, '/:username/:board_slug/');
    });
  });

  group('request construction — same machinery as user pins', () {
    const ts = 1730000000000;

    test('buildUrl produces the byte-exact user-pins URL convention', () {
      // The user-pins machinery builds:
      //   <path>?source_url=<enc>&data=<enc({"options":…,"context":{}})>&_=<ts>
      final url = PinterestResources.boardPins.buildUrl(
        options: {'board_id': 'fixture-board-id', 'page_size': 25},
        sourceUrlOverride: '/fixtureuser/fixture-board/',
        timestampMs: ts,
      );
      final expectedData = jsonEncode({
        'options': {'board_id': 'fixture-board-id', 'page_size': 25},
        'context': {},
      });
      final expected =
          '${PinterestConstants.boardFeedResource}'
          '?source_url=${Uri.encodeComponent('/fixtureuser/fixture-board/')}'
          '&data=${Uri.encodeComponent(expectedData)}'
          '&_=$ts';
      expect(url, expected);
    });

    test('data envelope decodes back to {options, context:{}}', () {
      final url = PinterestResources.userBoards.buildUrl(
        options: PinterestResourceOptions.userBoards(
          userId: '111222333444555666',
          username: 'fixtureuser',
        ),
        timestampMs: ts,
      );
      final dataParam = Uri
          .splitQueryString(Uri.parse(url).query)['data']!;
      final decoded = jsonDecode(dataParam) as Map<String, dynamic>;
      expect(decoded.keys, ['options', 'context']);
      expect(decoded['context'], isEmpty);
      final options = decoded['options'] as Map<String, dynamic>;
      expect(options, {
        'user_id': '111222333444555666',
        'username': 'fixtureuser',
        'field_set_key': 'profile_grid_item',
        'fetch_board_owner': true,
      });
    });

    test('option builders produce the probe-validated option sets', () {
      expect(
        PinterestResourceOptions.boardSections(boardId: 'fixture-board-id'),
        {'board_id': 'fixture-board-id', 'field_set_key': 'board_section_grid_item'},
      );
      expect(
        PinterestResourceOptions.boardSectionPins(sectionId: 'fixture-sec-id'),
        {
          'section_id': 'fixture-sec-id',
          'field_set_key': 'grid_item',
          'redux_normalize_feed': true,
        },
      );
      expect(
        PinterestResourceOptions.boardPins(boardId: 'fixture-board-id'),
        {
          'board_id': 'fixture-board-id',
          'page_size': 25,
          'field_set_key': 'grid_item',
          'redux_normalize_feed': true,
        },
      );
    });

    test('source_url defaults resolve from the template', () {
      expect(
        resolveSourceUrl(
          PinterestResources.userBoards,
          username: 'fixtureuser',
        ),
        '/fixtureuser/',
      );
      expect(
        resolveSourceUrl(
          PinterestResources.boardSections,
          username: 'fixtureuser',
          boardSlug: 'fixture-board',
        ),
        '/fixtureuser/fixture-board/',
      );
    });

    test('resolveSourceUrl tolerates missing substitutions (empty, not crash)',
        () {
      expect(
        resolveSourceUrl(PinterestResources.boardPins, username: 'fixtureuser'),
        '/fixtureuser//',
      );
    });
  });

  group('domain purity (G3 — zero UI, G2-style import hygiene)', () {
    test('registry file imports nothing UI- or channel-shaped', () {
      final src =
          RegExp(r'\b(widgets|material|cupertino|MethodChannel|dio)\b');
      final lines = fileLines('lib/data/pinterest/resources.dart');
      final importLines = lines.where((l) => l.trim().startsWith('import'));
      expect(importLines, isNotEmpty);
      for (final line in importLines) {
        expect(src.hasMatch(line), isFalse, reason: 'impure import: $line');
      }
      // Exactly one import expected: dart:convert.
      expect(importLines.length, 1);
    });
  });
}

List<String> fileLines(String path) {
  // Test files run from the repo root; keep it dependency-free.
  final f = File(path);
  return f.existsSync() ? f.readAsLinesSync() : <String>[];
}
