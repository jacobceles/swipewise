import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/util/stored_time.dart';

/// SQLite `CURRENT_TIMESTAMP` is UTC with no zone designator; read as local
/// time, every bank connection looked hours newer than it was west of UTC.
void main() {
  test('a CURRENT_TIMESTAMP value is read as UTC', () {
    final t = parseStoredUtc('2026-10-15 04:04:14');
    expect(t, DateTime.utc(2026, 10, 15, 4, 4, 14));
    expect(t!.isUtc, isTrue, reason: 'checked even on a UTC machine');
  });

  test('a value that names its zone keeps it', () {
    expect(
      parseStoredUtc('2026-10-15T04:04:14.5Z'),
      DateTime.utc(2026, 10, 15, 4, 4, 14, 500),
    );
    expect(
      parseStoredUtc('2026-10-15T00:04:14-04:00'),
      DateTime.utc(2026, 10, 15, 4, 4, 14),
    );
  });

  test('garbage is null, not a throw', () {
    expect(parseStoredUtc('not a date'), isNull);
  });
}
