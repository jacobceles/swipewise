import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/sophtron_auth_service.dart';

/// Pins the HMAC signing-scope contract: only the path segment AFTER the
/// last `/` (plus query string) is signed, lowercased. Documented in
/// Sophtron's reference implementation; this test exists so a careless
/// refactor (pre-lowercasing, pre-trimming, switching to full-path
/// signing) breaks here loudly rather than silently invalidating every
/// production request.
void main() {
  group('computeSophtronAuthPath', () {
    test('strips everything before the last "/"', () {
      expect(
        computeSophtronAuthPath('https://api.sophtron.com/api/v2/customers'),
        '/customers',
      );
    });

    test('lowercases the signed path', () {
      expect(
        computeSophtronAuthPath('https://api.sophtron.com/api/V2/Customers'),
        '/customers',
      );
    });

    test('preserves the query string after the last "/"', () {
      expect(
        computeSophtronAuthPath(
          'https://api.sophtron.com/api/v2/customers?uniqueID=alice',
        ),
        '/customers?uniqueid=alice',
      );
    });

    test('handles trailing-slash URLs (signed path = "/")', () {
      expect(computeSophtronAuthPath('https://api.sophtron.com/api/'), '/');
    });

    test('handles a URL with no slash by lowercasing the whole input', () {
      // Defensive — not a real Sophtron URL, but the helper should never
      // throw on weird input.
      expect(
        computeSophtronAuthPath('weird-no-slash-URL'),
        'weird-no-slash-url',
      );
    });

    test('per-job path: last segment is the jobId, query none', () {
      expect(
        computeSophtronAuthPath('https://api.sophtron.com/api/v2/job/abc-123'),
        '/abc-123',
      );
    });
  });
}
