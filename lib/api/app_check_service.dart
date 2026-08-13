import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

import '../util/logger.dart';

/// Firebase App Check — device attestation for calls to the SwipeWise Worker.
///
/// ## Why this exists
///
/// The Google Places key used to ship inside the APK, where it was protected by
/// GCP's Android application restriction. That restriction is worth nothing:
/// `X-Android-Package` and `X-Android-Cert` are headers the caller sets, and the
/// key, the package name and the cert SHA all travel in the same binary.
/// Measured 2026-08-10 — a plain `curl` from a laptop, forging both headers,
/// returned 200 with real Places data.
///
/// So the key moves to a Worker secret and the Worker decides who may call it.
/// Play Integrity attestation is the control that replaces the header check,
/// and unlike a header it cannot be copied out of the binary.
///
/// ## Two things that make this fail silently, both handled here
///
/// 1. **The headless isolate.** Geofence re-registration runs in its own
///    isolate (`geofenceReregisterEntrypoint`), builds its own
///    `GooglePlacesProvider`, and calls Places directly. App Check state is
///    per-isolate, so activating only in `main()` leaves that path tokenless —
///    it would 401 once enforcement is on, geofences would stop re-registering,
///    and arrival notifications would simply stop. No crash, no log.
/// 2. **Debug builds have no Play Integrity.** `flutter run` installs an
///    unsigned debug APK that Play Integrity cannot attest, so debug uses the
///    debug provider, whose token must be registered in the Firebase console
///    (App Check → Manage debug tokens). Without that registration a developer
///    locks themselves out of the very path they are trying to test.
class AppCheckService {
  const AppCheckService._();

  static bool _activated = false;

  /// Neither call may block indefinitely.
  ///
  /// Both talk to Google over the network — `activate` registers the provider
  /// and `getToken` performs a token exchange (for the debug provider, a round
  /// trip that swaps the debug secret for a real App Check token). Awaiting
  /// either without a bound turns a slow or unreachable attestation service
  /// into a hung app: `activate` is awaited before `runApp`, and `token` is
  /// awaited before every nearby search — which showed up as a Stores tab that
  /// spun forever while the 15s HTTP timeout, sitting *after* the token fetch,
  /// never got the chance to fire.
  static const _timeout = Duration(seconds: 5);

  /// Above this, the call went to the network rather than the SDK's cache. The
  /// SDK caches in storage, so a warm call returns in single-digit ms.
  static const _slowAttestationMs = 250;

  /// Activates App Check for the current isolate. Safe to call more than once
  /// and safe to call in a process that never reaches the network.
  ///
  /// Never throws: App Check is an access-control layer, and a failure to
  /// attest must degrade to "no token" — which the Worker can reject on its own
  /// terms — rather than take down app startup or a background worker.
  static Future<void> activate() async {
    if (_activated) return;
    try {
      await FirebaseAppCheck.instance
          .activate(
            // Play Integrity in release; the debug provider cannot be attested
            // and is rejected by an enforcing Worker unless its token is
            // registered.
            providerAndroid: kDebugMode
                ? const AndroidDebugProvider()
                : const AndroidPlayIntegrityProvider(),
          )
          .timeout(_timeout);
      _activated = true;
    } catch (e) {
      // Swallowed deliberately — see the class doc. A missing token is a
      // recoverable state; a crashed isolate is not.
      Log.w('appcheck', 'activate failed', e);
    }
  }

  /// Starts an attestation now so a later caller doesn't wait for a cold one.
  ///
  /// We do NOT cache tokens ourselves. `getToken()` already "will use a cached
  /// token if found in storage" and "attaches to the most recent in-flight
  /// request if one is present" — storage, so the cache survives an isolate,
  /// and in-flight attaching, so concurrent callers share one round trip. A
  /// second cache on top would only fight the SDK's own refresh.
  ///
  /// What is left to fix is *when* the cold round trip happens. A Play Integrity
  /// attestation was measured at ~2.2 s, and the token fetch sits **before** the
  /// HTTP timeout in `GooglePlacesProvider` — so paying it inside the user's
  /// first nearby search reads as a Stores tab that hangs. Kicking it off at
  /// activation moves that cost next to startup, and any search that fires
  /// meanwhile attaches to it rather than starting a second one.
  ///
  /// Deliberately fire-and-forget: a warm-up that blocks startup would cost more
  /// than the latency it removes.
  static void warm() => unawaited(token());

  /// The current App Check token, or null if attestation is unavailable.
  ///
  /// Null is a normal outcome (no Play Services, an emulator with no debug
  /// token registered, an offline device), so callers must treat it as "send no
  /// header" rather than as an error worth surfacing.
  static Future<String?> token() async {
    final started = DateTime.now();
    String? token;
    try {
      token = await FirebaseAppCheck.instance.getToken().timeout(_timeout);
      return token;
    } catch (e) {
      Log.w('appcheck', 'getToken failed', e);
      return null;
    } finally {
      final ms = DateTime.now().difference(started).inMilliseconds;
      // The outcome is part of the measurement, not decoration. Duration alone is
      // ambiguous in exactly the case you most want to read: once the SDK enters
      // its backoff after a failed exchange it rejects locally in single-digit
      // milliseconds, which is indistinguishable from a cache hit unless the line
      // also says whether a token came back.
      final outcome = token == null ? 'FAILED' : 'ok';
      // WARN so it survives a RELEASE build — the only place Play Integrity runs,
      // since `activate` picks the debug provider under kDebugMode. A cold round
      // trip and any failure are both worth a line; a warm hit is not.
      if (ms >= _slowAttestationMs || token == null) {
        Log.w('appcheck', 'getToken $outcome in ${ms}ms (cold round trip or failure — not a cached hit)');
      } else {
        Log.d('appcheck', 'getToken ok in ${ms}ms (cached)');
      }
    }
  }

  @visibleForTesting
  static void resetForTest() => _activated = false;
}
