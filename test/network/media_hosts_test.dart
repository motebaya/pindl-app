import 'package:flutter_test/flutter_test.dart';
import 'package:pindl/core/network/media_hosts.dart';

/// Phase 03 — media host allowlist (SEC-2) with boundary matching (D-08).
/// Gate G5: lookalike domains must be rejected.
void main() {
  group('boundary matching (D-08)', () {
    test('exact host match allowed', () {
      expect(MediaHosts.isAllowed('i.pinimg.com'), isTrue);
      expect(MediaHosts.isAllowed('pinimg.com'), isTrue);
    });

    test('proper subdomain allowed (suffix boundary)', () {
      expect(MediaHosts.isAllowed('https://v1.pinimg.com/v.mp4'), isTrue);
      expect(MediaHosts.isAllowed('s-pinimg.com'.replaceFirst('s-', 'i.')), isTrue);
      expect(MediaHosts.isAllowed('a.b.pinimg.com'), isTrue);
    });

    test('lookalike domains REJECTED (the point of boundary matching)', () {
      for (final evil in MediaHosts.knownLookalikes) {
        expect(MediaHosts.isAllowed(evil), isFalse, reason: '$evil must not pass');
        expect(MediaHosts.isAllowed('https://$evil/x.jpg'), isFalse,
            reason: 'https://$evil must not pass');
      }
    });

    test('bare-host port/path and case handling', () {
      expect(MediaHosts.isAllowed('I.PINIMG.COM'), isTrue);
      expect(MediaHosts.isAllowed('i.pinimg.com:443'), isTrue);
      expect(MediaHosts.isAllowed('i.pinimg.com./'), isTrue);
    });

    test('garbage input rejected (fail-closed)', () {
      expect(MediaHosts.isAllowed(''), isFalse);
      expect(MediaHosts.isAllowed('not a url'), isFalse);
    });

    test('redirect targets: pinterest/pin.it family only', () {
      expect(MediaHosts.isAllowedRedirect('https://www.pinterest.com/pin/123/'), isTrue);
      expect(MediaHosts.isAllowedRedirect('https://id.pinterest.com/pin/123/'), isTrue);
      expect(MediaHosts.isAllowedRedirect('https://pin.it/abc'), isTrue);
      // Lookalikes and foreign hosts fail:
      expect(MediaHosts.isAllowedRedirect('https://evilpinterest.com/pin/1'), isFalse);
      expect(MediaHosts.isAllowedRedirect('https://pinterest.com.evil.io/x'), isFalse);
      expect(MediaHosts.isAllowedRedirect('https://i.pinimg.com/a.jpg'), isFalse);
    });
  });
}
