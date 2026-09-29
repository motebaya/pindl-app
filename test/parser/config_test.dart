import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/data/parsers/pinterest_parser.dart';

import '../helpers/fixture_loader.dart';

/// Characterization: PinterestConfig extraction (3 userId strategies).
/// Pins CURRENT behavior (Phase 02 contract — fixes belong to later phases
/// with deliberate pin updates).
void main() {
  group('parseConfig — profile_page.html (strategies 1–3 present)', () {
    test('extracts appVersion', () {
      final config = PinterestParser.parseConfig(Fixtures.profilePage());
      expect(config, isNotNull);
      expect(config!.appVersion, 'd0f0e6b');
    });

    test('strategy 1 wins: profile_cover.id', () {
      final config = PinterestParser.parseConfig(Fixtures.profilePage());
      expect(config!.userId, '111222333444555666');
    });
  });

  group('parseConfig — strategy 2 (/users/ID/pins)', () {
    test('extracts userId when profile_cover absent', () {
      // appVersion key MUST be quoted: _appVersionPattern requires ['"]appVersion['"]
      const html = "<script>var x = {'appVersion': 'abc123'}; "
          'var opts = {url: "/users/999888777666555/pins/"};</script>';
      final config = PinterestParser.parseConfig(html);
      expect(config, isNotNull);
      expect(config!.appVersion, 'abc123');
      expect(config.userId, '999888777666555');
    });
  });

  group('parseConfig — strategy 3 (__PWS_INITIAL_PROPS__)', () {
    test('extracts userId from initialReduxState when 1–2 absent', () {
      const html = "<script>{\"appVersion\": \"def456\"}</script>"
          '<script id="__PWS_INITIAL_PROPS__" type="application/json">'
          '{"initialReduxState":{"users":{"777666555444333222111":{"id":"x"}}}}'
          '</script>';
      final config = PinterestParser.parseConfig(html);
      expect(config, isNotNull);
      expect(config!.userId, '777666555444333222111');
    });
  });

  group('parseConfig — failure shapes', () {
    test('returns null when no config present', () {
      expect(PinterestParser.parseConfig(Fixtures.profileNoConfig()), isNull);
    });
  });
}
