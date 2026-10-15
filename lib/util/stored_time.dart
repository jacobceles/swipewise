/// Parses a timestamp read back from SQLite as UTC.
///
/// Columns defaulting to `CURRENT_TIMESTAMP` hold UTC with no zone designator
/// (`2026-10-15 04:04:14`), which [DateTime.tryParse] reads as *local* time.
/// West of UTC every bank connection then looked hours newer than it was: a
/// fresh link stayed "fresh", the drop pass was skipped on every sync, and a
/// bank asking for a verification code was never flagged (2026-10). East of
/// UTC the same mistake made a just-linked connection look old enough to drop.
/// Values that already carry a zone keep it.
DateTime? parseStoredUtc(String raw) {
  final hasZone = RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(raw);
  return DateTime.tryParse(hasZone ? raw : '${raw.replaceFirst(' ', 'T')}Z');
}
