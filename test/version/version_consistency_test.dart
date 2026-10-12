import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Version reconciliation (3.1.1).
///
/// The reported problem: the bugfix work was labelled 3.1.1 in the changelog and
/// the commit history while the shipped APK still identified itself as
/// `3.1.0+7`. `pubspec.yaml` is the CANONICAL source — Android's
/// `versionCode`/`versionName` are `flutter.versionCode`/`flutter.versionName`
/// (android/app/build.gradle.kts) and CI derives the release tag
/// `v<base>-b<build>` from it. These checks make the other surfaces *validated*
/// against that source instead of kept in sync by hand:
///
///   * the application-visible version string (About page),
///   * `RELEASE_NOTES.md` (current release only, per the adopted flow rule),
///   * `CHANGELOG.md` (must carry an entry for the release being shipped).
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final versionLine = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
      .firstMatch(pubspec)
      ?.group(1);
  final base = versionLine?.split('+').first;
  final build = versionLine != null && versionLine.contains('+')
      ? versionLine.split('+').last
      : '1';

  test('pubspec.yaml carries a canonical semver + build number', () {
    expect(versionLine, isNotNull, reason: 'pubspec must declare `version:`');
    expect(base, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(int.tryParse(build), isNotNull,
        reason: 'the build number drives Android versionCode + the CI tag');
    expect(int.parse(build), greaterThan(0));
  });

  test('the About page shows the pubspec version', () {
    final about = File('lib/presentation/pages/about_page.dart').readAsStringSync();
    expect(about, contains("'Version $base'"),
        reason: 'the application-visible version must match the canonical '
            'source (this is the surface the device QA reads)');
  });

  test('RELEASE_NOTES.md describes the current release and only it', () {
    final notes = File('RELEASE_NOTES.md').readAsStringSync();
    final headings = RegExp(r'^## (\S+)', multiLine: true)
        .allMatches(notes)
        .map((m) => m.group(1)!)
        .toList();
    expect(headings, isNotEmpty, reason: 'notes must have a release heading');
    expect(headings.first, base);
    expect(headings.where((h) => h != base), isEmpty,
        reason: 'flow rule: the current release replaces the file wholesale');
  });

  test('CHANGELOG.md has an entry for the shipped version', () {
    final changelog = File('CHANGELOG.md').readAsStringSync();
    expect(changelog, contains('## [$base]'),
        reason: 'the changelog must document the version being released');
  });

  test('no public doc or source file still advertises the previous version',
      () {
    // Guard against the exact reported drift: a public surface claiming the
    // OLD version after the bump. (`CHANGELOG.md` legitimately keeps older
    // version headings, so it is excluded.)
    final offenders = <String>[];
    for (final path in [
      'RELEASE_NOTES.md',
      'README.md',
      'docs/architecture.md',
      'docs/boards.md',
      'docs/downloads.md',
      'docs/getting-started.md',
      'docs/troubleshooting.md',
      'docs/usage.md',
      'lib/presentation/pages/about_page.dart',
    ]) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final content = file.readAsStringSync();
      if (content.contains(previousBase)) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'these files still mention $previousBase');
  });
}

/// The version this release moved away from — kept explicit so the drift check
/// above fails loudly if a future bump forgets a surface (update it together
/// with `pubspec.yaml`).
const String previousBase = '3.1.0';
