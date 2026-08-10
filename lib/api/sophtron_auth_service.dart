import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class MissingSophtronCreds implements Exception {
  @override
  String toString() =>
      'SOPHTRON_USER_ID / SOPHTRON_ACCESS_KEY not configured. Build with '
      '--dart-define=SOPHTRON_USER_ID=<id> --dart-define=SOPHTRON_ACCESS_KEY=<key>.';
}

/// Sophtron HMAC credentials baked into the build via `--dart-define`.
///
/// The three values here serve **three separate purposes** — historically
/// the first two were conflated which produced "every install shares the
/// same Sophtron Customer" behaviour; that's now untangled:
///
/// - [userId] — the API account *principal* baked into the HMAC
///   `Authorization` header (`FIApiAUTH:<userId>:<sig>:<path>`). Shared
///   across every install of the same APK; identifies *the application*
///   making the call to Sophtron's billing / rate-limit layer.
/// - [accessKey] — the HMAC signing secret. Also shared across installs;
///   pairs with [userId] to authenticate the API call.
/// - [customerSalt] — a build-time secret mixed into the per-user
///   `email → Customer uniqueId` derivation. See [deriveCustomerUniqueId].
///   The *Customer* uniqueId is per-install (derived from the user's
///   email at onboarding); the salt is per-build so the email-to-uniqueId
///   function isn't pre-computable by someone who only has the email.
///
/// Reverse-engineering note: `String.fromEnvironment` constants are inlined
/// into the compiled binary. `flutter build apk --obfuscate
/// --split-debug-info=...` makes them harder to find (function/class names
/// are mangled) but does not encrypt the literal — anyone with the APK and
/// determination can recover all three values. Acceptable for hobbyist /
/// closed-distribution scale; document the residual risk before any
/// open-distribution cutover.
class SophtronConfig {
  static const String apiBaseUrl = 'https://api.sophtron.com/api/';
  static const String userId = String.fromEnvironment('SOPHTRON_USER_ID');
  static const String accessKey = String.fromEnvironment('SOPHTRON_ACCESS_KEY');

  /// Build-time secret salt mixed into the per-user Customer uniqueId
  /// derivation. Empty in builds that haven't supplied it — those builds
  /// still work (the salt's protective value is marginal anyway given
  /// the rest of the APK is recoverable), but production builds should
  /// always set this so the derivation isn't reproducible from just the
  /// email.
  static const String customerSalt = String.fromEnvironment(
    'SOPHTRON_CUSTOMER_SALT',
  );

  static bool get isConfigured => userId.isNotEmpty && accessKey.isNotEmpty;

  /// Derives the per-install Customer uniqueId from the user's onboarding
  /// email. Sophtron's v2 Customer entity is keyed on this string —
  /// re-deriving the same value on a fresh install (because the user
  /// enters the same email) lets `resolveCustomerId` retrieve the
  /// existing Customer with all its Members intact. That's the reinstall-
  /// recovery path; no Google-account backup needed, no recovery code to
  /// save.
  ///
  /// The hash gives us:
  ///   - a canonical form (case + whitespace normalised) so
  ///     "Jacob@example.com" / "jacob@example.com" / " jacob@example.com "
  ///     all produce the same uniqueId,
  ///   - an opaque value at the Sophtron API boundary (Sophtron sees the
  ///     hex digest, not the literal email).
  /// The salt's contribution is documented on [customerSalt].
  static String deriveCustomerUniqueId(String email) {
    final normalised = email.trim().toLowerCase();
    final bytes = utf8.encode('$normalised|$customerSalt');
    return sha256.convert(bytes).toString();
  }
}

/// Builds the `Authorization: FIApiAUTH:...` header Sophtron's direct API
/// expects. Mirrors `python/apiClient.py` in github.com/sophtron/Sophtron-Integration.
///
/// The signed path is `fullUrl.substring(fullUrl.lastIndexOf('/'))` — the
/// trailing path segment + query string only. This is deliberately the
/// scheme Sophtron's reference impl uses; do not change without coordinating
/// with their side. The unit test in `test/api/sophtron_auth_service_test.dart`
/// pins the exact substring contract to a fixture URL.
String buildSophtronAuthHeader({
  required String fullUrl,
  required String httpMethod,
}) {
  if (!SophtronConfig.isConfigured) throw MissingSophtronCreds();
  final authPath = computeSophtronAuthPath(fullUrl);
  final plain = '${httpMethod.toUpperCase()}\n$authPath';
  final keyBytes = base64.decode(SophtronConfig.accessKey);
  final mac = Hmac(sha256, keyBytes).convert(utf8.encode(plain));
  final sig = base64.encode(mac.bytes);
  return 'FIApiAUTH:${SophtronConfig.userId}:$sig:$authPath';
}

/// Exposed so tests can pin the signing scope without invoking the HMAC
/// computation (which requires baked-in creds).
@visibleForTesting
String computeSophtronAuthPath(String fullUrl) {
  final idx = fullUrl.lastIndexOf('/');
  if (idx < 0) return fullUrl.toLowerCase();
  return fullUrl.substring(idx).toLowerCase();
}

class SophtronAuthService {
  SophtronAuthService({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const Duration _kHealthCheckTimeout = Duration(seconds: 15);

  /// Cheapest authenticated endpoint — returns `"Online"` on success, throws
  /// on bad creds. Use to verify the baked-in keys are still valid.
  Future<void> validateCredentials() async {
    final url = '${SophtronConfig.apiBaseUrl}Institution/HealthCheckAuth';
    try {
      final resp = await _http
          .get(
            Uri.parse(url),
            headers: {
              'Authorization': buildSophtronAuthHeader(
                fullUrl: url,
                httpMethod: 'GET',
              ),
            },
          )
          .timeout(_kHealthCheckTimeout);
      if (resp.statusCode != 200) {
        throw Exception(
          'Sophtron credential check failed (HTTP ${resp.statusCode})',
        );
      }
    } on TimeoutException {
      throw Exception(
        'Sophtron credential check timed out after ${_kHealthCheckTimeout.inSeconds}s',
      );
    } on SocketException catch (e) {
      throw Exception('Sophtron credential check network error: ${e.message}');
    }
  }
}
