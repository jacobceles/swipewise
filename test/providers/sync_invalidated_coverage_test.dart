import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static-analysis style coverage test for the
/// `syncInvalidatedProviders` registry in `lib/providers/data_providers.dart`.
///
/// The registry is a manually-maintained list of providers that read
/// sync-replaced tables and have to be invalidated after a successful
/// sync. Audit §F3 flagged the "forgot to add it to the list" failure
/// mode: a new sync-derived provider lands without an entry, the UI
/// keeps serving stale data after a sync, and nothing fails loudly.
///
/// Strategy: parse `data_providers.dart` as text. Every
/// `final <name> = FutureProvider...` or `AsyncNotifierProvider...`
/// declaration is a candidate. Each candidate must either:
///   - appear in the `syncInvalidatedProviders` list, or
///   - be annotated with the `// sync: opt-out — &lt;reason&gt;` marker on
///     the line directly above its declaration.
///
/// This is a source-scanning check, not a runtime one. It catches the
/// drift case but won't catch a provider that's listed in the registry
/// but doesn't actually need to be (false positive — acceptable: extra
/// invalidations are wasteful but not wrong).
void main() {
  final file = File('lib/providers/data_providers.dart');
  if (!file.existsSync()) {
    fail('data_providers.dart not found at ${file.absolute.path}');
  }

  final source = file.readAsStringSync();
  final lines = source.split('\n');

  // Pull the registry contents.
  final registry = _extractRegistry(source);

  final candidates = _candidates(source);

  test('parser includes multiline declarations and their opt-out markers', () {
    final parsed = _candidates('''
final singleProvider = FutureProvider<int>((ref) async => 1);
// sync: opt-out — fixture
final splitProvider =
    NotifierProvider<Queue, Set<String>>(Queue.new);
final untrackedProvider =
    AsyncNotifierProvider<Loader, int>(Loader.new);
''');
    expect(parsed.map((c) => c.name), [
      'singleProvider',
      'splitProvider',
      'untrackedProvider',
    ]);
    expect(parsed.map((c) => c.optOut), [false, true, false]);
    expect(parsed.map((c) => c.line), [1, 3, 5]);
  });

  test(
    'rotating schedule is invalidated and reconciliation explicitly opts out',
    () {
      expect(registry, contains('cardRotatingScheduleProvider'));
      final line = lines.indexWhere(
        (l) => l.startsWith('final pendingReconciliationProvider'),
      );
      expect(line, greaterThanOrEqualTo(0));
      expect(_hasOptOutAbove(lines, line), isTrue);
    },
  );

  test('every sync-derived provider in data_providers.dart is either in '
      'syncInvalidatedProviders or has a `// sync: opt-out` marker', () {
    final missing = <String>[];
    for (final c in candidates) {
      if (c.optOut) continue;
      if (registry.contains(c.name)) continue;
      missing.add('${c.name} (line ${c.line})');
    }
    expect(
      missing,
      isEmpty,
      reason:
          'These providers aren\'t in `syncInvalidatedProviders` and '
          'have no `// sync: opt-out` marker. Either add them to the '
          'registry, or annotate the declaration line above with:\n'
          '    // sync: opt-out — <why this doesn\'t need invalidation>\n'
          '\nUntracked:\n  ${missing.join('\n  ')}',
    );
  });

  test('the parser found at least one provider — guard against the regex '
      'silently matching nothing if the file is restructured', () {
    expect(
      candidates,
      isNotEmpty,
      reason:
          'No FutureProvider / AsyncNotifierProvider / NotifierProvider '
          'declarations were detected. The declRegex in this test is '
          'likely stale.',
    );
  });
}

class _Candidate {
  const _Candidate({
    required this.name,
    required this.line,
    required this.optOut,
  });
  final String name;
  final int line;
  final bool optOut;
}

List<_Candidate> _candidates(String source) {
  final lines = source.split('\n');
  final declarations = RegExp(
    r'^final\s+(\w+Provider)\s*=\s*(FutureProvider|AsyncNotifierProvider|NotifierProvider)',
    multiLine: true,
  );
  return [
    for (final match in declarations.allMatches(source))
      _Candidate(
        name: match.group(1)!,
        line: '\n'.allMatches(source.substring(0, match.start)).length + 1,
        optOut: _hasOptOutAbove(
          lines,
          '\n'.allMatches(source.substring(0, match.start)).length,
        ),
      ),
  ];
}

bool _hasOptOutAbove(List<String> lines, int declLine) {
  // Scan backwards through comment lines until we hit code or run out.
  for (var i = declLine - 1; i >= 0; i--) {
    final l = lines[i].trim();
    if (l.isEmpty) return false;
    if (l.startsWith('///') || l.startsWith('//')) {
      if (l.contains('sync: opt-out')) return true;
      continue;
    }
    return false;
  }
  return false;
}

Set<String> _extractRegistry(String source) {
  // Find the start of the registry literal.
  final start = source.indexOf('syncInvalidatedProviders');
  if (start < 0) {
    throw StateError(
      'syncInvalidatedProviders declaration not found in data_providers.dart',
    );
  }
  // Find the opening `[` after the declaration.
  final openBracket = source.indexOf('[', start);
  final closeBracket = source.indexOf('];', openBracket);
  if (openBracket < 0 || closeBracket < 0) {
    throw StateError(
      'Could not locate the syncInvalidatedProviders list bounds.',
    );
  }
  final body = source.substring(openBracket + 1, closeBracket);
  final entries = body
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  return entries;
}
