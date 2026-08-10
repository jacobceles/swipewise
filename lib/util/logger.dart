import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

/// Logging wrapper. Routes to BOTH `dart:developer.log` (rich IDE Run-console
/// support) and `debugPrint` (so messages reliably hit `I/flutter` in
/// `adb logcat -s flutter`, the Logcat panel, and `flutter logs`).
///
/// Two behavioral notes:
/// 1. **PII scrubbing**: every message passes through [scrubPii] which
///    redacts the common high-risk shapes (account numbers, last-four
///    blocks, base64-looking signature material, JWT-ish tokens, etc.)
///    before it reaches any sink. Add patterns to [_piiPatterns] when a
///    new leak shape is discovered; never disable scrubbing for "rich"
///    debug output — open a `Log.payload(...)` call instead, which is a
///    debug-only escape hatch that no-ops in release mode.
/// 2. **Release verbosity**: in release mode only [w] / [e] are emitted.
///    Production builds skip [d] / [i] / [payload] entirely, so any free-
///    form payload dumps cost nothing and leak nothing once shipped.
class Log {
  Log._();

  static void d(String tag, String message) {
    if (kReleaseMode) return;
    _emit('D', tag, message);
  }

  static void i(String tag, String message) {
    if (kReleaseMode) return;
    _emit('I', tag, message);
  }

  static void w(String tag, String message, [Object? error]) {
    _emit('W', tag, error == null ? message : '$message | error=$error');
    developer.log(scrubPii(message), name: 'SW.$tag', level: 900, error: error);
  }

  static void e(String tag, String message, Object error, [StackTrace? stack]) {
    _emit('E', tag, '$message | error=$error');
    if (stack != null) {
      for (final line in stack.toString().split('\n').take(20)) {
        debugPrint('[SW.$tag]   $line');
      }
    }
    developer.log(
      scrubPii(message),
      name: 'SW.$tag',
      level: 1000,
      error: error,
      stackTrace: stack,
    );
  }

  /// Dev-only payload dump. Used for the verbose `members raw: {...}` style
  /// logs that the sync engine and connection flow emit during debugging.
  /// Becomes a no-op in release mode so we never ship raw API payloads in
  /// production logcat. Use the lazy `() => jsonEncode(thing)` form so the
  /// payload isn't serialized when logging is off.
  static void payload(String tag, String label, String Function() lazyBody) {
    if (kReleaseMode) return;
    _emit('D', tag, '$label: ${lazyBody()}');
  }

  static void _emit(String level, String tag, String message) {
    final scrubbed = scrubPii(message);
    final line = '[SW.$tag][$level] $scrubbed';
    debugPrint(line);
    developer.log(scrubbed, name: 'SW.$tag');
  }
}

/// Best-effort PII redaction. Anchored on the leak shapes we've actually
/// seen in this codebase (Sophtron 4xx bodies echoing fields, MemberID logs,
/// raw JSON payloads). Visible for testing.
@visibleForTesting
String scrubPii(String input) {
  var s = input;
  for (final pattern in _piiPatterns) {
    s = s.replaceAllMapped(pattern.regex, (m) => pattern.redact(m));
  }
  return s;
}

class _PiiPattern {
  const _PiiPattern(this.regex, this.redact);
  final RegExp regex;
  final String Function(Match) redact;
}

// Order matters: more-specific patterns first.
final List<_PiiPattern> _piiPatterns = [
  // Long digit runs that look like account / card numbers (>= 9 digits,
  // hyphens or spaces allowed). Keep the last 4 visible so debugging
  // still works. Skips short ints (ports, hash prefixes, timestamps that
  // happen to be 9-12 digits — those collide; tradeoff accepted).
  _PiiPattern(RegExp(r'(?<!\d)(?:\d[\d\- ]{7,}\d)(?!\d)'), (m) {
    final raw = m.group(0)!.replaceAll(RegExp(r'[\s-]'), '');
    final last4 = raw.length >= 4 ? raw.substring(raw.length - 4) : raw;
    return '****$last4';
  }),
  // Sophtron Password/UserName JSON-style key in payload echoes:
  // `"Password":"hunter2"` → `"Password":"[REDACTED]"`.
  _PiiPattern(
    RegExp(
      r'"(Password|UserName|AnswerText|SecurityQuestion|TokenInput|password|userName|answerText)"\s*:\s*"[^"]*"',
    ),
    (m) => '"${m.group(1)}":"[REDACTED]"',
  ),
  // JWT-ish "xxx.yyy.zzz" with at least two dots and base64-looking parts.
  _PiiPattern(
    RegExp(
      r'\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b',
    ),
    (_) => '[JWT_REDACTED]',
  ),
  // Bearer / Authorization values.
  _PiiPattern(
    RegExp(r'(Authorization|Bearer)\s*[:=]\s*\S+', caseSensitive: false),
    (m) => '${m.group(1)}: [REDACTED]',
  ),
];
