import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../util/logger.dart';

/// One-shot up-front gate that prompts for every permission the nearby
/// stores feature needs. Fired exactly once per install - on the first
/// paint of HomeScreen after login.
///
/// Order (intentional - see prompt-race notes below):
///   1. Notifications        (POST_NOTIFICATIONS,    Android 13+)
///   2. Activity recognition (ACTIVITY_RECOGNITION,  Android 10+)
///   3. Foreground location  (ACCESS_FINE_LOCATION)  - via Geolocator
///   4. Explainer dialog     - "we need always-allow to alert you near
///      stores in the background"
///   5. Background location  (ACCESS_BACKGROUND_LOCATION) - on Android
///      11+ this deep-links into Settings → "Allow all the time".
///
/// **Why location is asked AFTER notifications + activity-recognition**:
/// The rest of the app (Stores tab) uses `Geolocator` to request
/// foreground location. If `permission_handler`'s bulk request runs in
/// parallel with a Geolocator request, the OS silently nulls one of the
/// two. We block the Stores tab via `permissionGateCompleteProvider`
/// until the gate finishes, so by the time we get to step 3 there's no
/// Geolocator competitor in flight.
///
/// **Why the explainer dialog**: background location is intrusive; on
/// Android 11+ it punts to Settings. A short "here's why" gives the
/// user a chance to opt in deliberately instead of being yanked into
/// system Settings unannounced.
class NearbyPermissionGate {
  static Future<bool> ensureAll(BuildContext context) async {
    // Step 1 + 2: Notifications + Activity Recognition. Bulk request via
    // permission_handler - the only API on this plugin that reliably
    // sequences multiple dialogs without back-to-back individual calls
    // silently returning `denied`.
    final nonLocation = [
      Permission.notification,
      Permission.activityRecognition,
    ];
    final beforeNonLoc = {for (final p in nonLocation) p: await p.status};
    final nonLocResults = await nonLocation.request();
    for (final p in nonLocation) {
      Log.i(
        'permissions',
        '${_label(p)}: before=${beforeNonLoc[p]} → after=${nonLocResults[p]}',
      );
    }

    // Step 3: Foreground location via Geolocator (same plugin Stores tab
    // uses → no two-plugin race once we get here).
    final beforeLoc = await Geolocator.checkPermission();
    final locResult = await Geolocator.requestPermission();
    Log.i(
      'permissions',
      'Location (Geolocator): before=$beforeLoc → after=$locResult',
    );

    final fgGranted =
        locResult == LocationPermission.always ||
        locResult == LocationPermission.whileInUse;

    // Only show the always-allow explainer if foreground was JUST granted
    // (i.e., we actually prompted this run). If location was already
    // whileInUse on entry - e.g., user logged out and back in as a new
    // user, so `permissionsAsked` reset but OS-level grants persisted -
    // the bulk requests above are silent no-ops and the explainer would
    // otherwise pop up alone, which feels like a random nag.
    final justPromptedFg =
        beforeLoc == LocationPermission.denied ||
        beforeLoc == LocationPermission.deniedForever ||
        beforeLoc == LocationPermission.unableToDetermine;

    // Step 4 + 5: Explainer dialog → background location.
    // Only attempt if foreground was granted; without foreground the OS
    // won't show the background prompt at all.
    if (fgGranted &&
        locResult != LocationPermission.always &&
        justPromptedFg &&
        context.mounted) {
      final wantsAlways = await _showAlwaysAllowExplainer(context);
      if (wantsAlways) {
        final beforeBg = await Permission.locationAlways.status;
        final afterBg = await Permission.locationAlways.request();
        Log.i(
          'permissions',
          'Background location: before=$beforeBg → after=$afterBg',
        );
      } else {
        Log.i(
          'permissions',
          'user declined Always-Allow explainer; skipping background',
        );
      }
    } else if (!fgGranted) {
      Log.i(
        'permissions',
        'skipping Background location - foreground not granted',
      );
    } else if (!justPromptedFg) {
      Log.i(
        'permissions',
        'skipping Always-Allow explainer - foreground was already granted on entry',
      );
    }

    // Re-read for the final evaluation. Some OEMs flap status briefly
    // after a dialog dismiss; a fresh check is the only reliable signal.
    final statuses = <Permission, PermissionStatus>{
      Permission.notification: await Permission.notification.status,
      Permission.activityRecognition:
          await Permission.activityRecognition.status,
      Permission.locationWhenInUse: await Permission.locationWhenInUse.status,
      Permission.locationAlways: await Permission.locationAlways.status,
    };

    // Android 12+ (API 31+) lets the user grant "Approximate" location instead
    // of "Precise". Geolocator still reports whileInUse/always for an
    // approximate grant, so it sails past the isGranted checks below — but
    // geofences built on coarse (~1-3 km) fixes misfire. When location is
    // granted but only approximately, treat it as not-fully-granted for the
    // geofencing gate so the user is nudged to switch to Precise.
    final locationGranted =
        statuses[Permission.locationWhenInUse]?.isGranted ?? false;
    final approximateOnly =
        locationGranted &&
        (await Geolocator.getLocationAccuracy()) ==
            LocationAccuracyStatus.reduced;
    if (approximateOnly) {
      Log.w(
        'permissions',
        'location granted as Approximate (reduced accuracy); '
            'geofencing needs Precise',
      );
    }

    if (!approximateOnly && statuses.values.every((s) => s.isGranted)) {
      return true;
    }

    final permanent = <String>[];
    final denied = <String>[];
    statuses.forEach((perm, status) {
      if (status.isGranted) return;
      final label = _label(perm);
      if (status.isPermanentlyDenied || status.isRestricted) {
        permanent.add(label);
      } else {
        denied.add(label);
      }
    });
    // Approximate-only location is granted-but-degraded: surface it alongside
    // any outright-denied permissions so the same Settings nudge covers it.
    if (approximateOnly) {
      denied.add('Precise location');
    }

    if (!context.mounted) return false;

    if (permanent.isNotEmpty) {
      _showSettingsSnack(
        context,
        'Permission denied for: ${permanent.join(", ")}. '
        'Please enable in Settings to use nearby store alerts.',
      );
    } else if (denied.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 4),
          content: Text(
            'Permission denied for: ${denied.join(", ")}. '
            'Nearby store alerts will not work without these.',
          ),
        ),
      );
    }
    return false;
  }

  /// Requests the two background-reliability grants, skipping any already
  /// held:
  ///
  ///   1. Exact alarms (SCHEDULE_EXACT_ALARM) — denied by default on
  ///      Android 14+; powers the deterministic app-side dwell timers.
  ///      Routes through the system "Alarms & reminders" settings page.
  ///   2. Ignore battery optimizations — shows the system dialog directly.
  ///      Keeps OEM battery managers from killing the geofence receivers,
  ///      the top real-world cause of silently missed store alerts.
  ///
  /// Triggered by the Stores-view reliability banner, which detects the
  /// missing grants and re-checks after this returns — same
  /// detect-and-nudge pattern as [requestBackgroundLocation]. The banner
  /// press is the opt-in, so no extra explainer modal here.
  static Future<void> requestReliability() async {
    final alarmBefore = await Permission.scheduleExactAlarm.status;
    if (!alarmBefore.isGranted) {
      final after = await Permission.scheduleExactAlarm.request();
      Log.i('permissions', 'Exact alarms: before=$alarmBefore → after=$after');
    }
    final batteryBefore = await Permission.ignoreBatteryOptimizations.status;
    if (!batteryBefore.isGranted) {
      final after = await Permission.ignoreBatteryOptimizations.request();
      Log.i(
        'permissions',
        'Ignore battery optimizations: before=$batteryBefore → after=$after',
      );
    }
  }

  /// Single-step entry point for "request background location from the
  /// user *right now*", used by the Advisor → Stores nudge banner.
  ///
  /// Shows [_showAlwaysAllowExplainer] first. This used to skip it, on the
  /// reasoning that the banner already says why and a second modal is
  /// redundant friction — true as UX, wrong as compliance. Play requires the
  /// prominent disclosure before *any* background-location request, and a
  /// banner does not qualify: it isn't a standalone disclosure and tapping
  /// "Open" isn't affirmative consent to the specific wording. Having exactly
  /// one disclosure implementation on every path is also the only way this
  /// stays true as paths get added.
  ///
  /// Routing:
  ///   - Android 10 (API 29): `Permission.locationAlways.request()`
  ///     shows the system "Allow all the time" dialog inline.
  ///   - Android 11+ (API 30+): the same call deep-links straight to
  ///     **the per-app Location permission page** — that's the route
  ///     the Advisor nudge should be using (not
  ///     `Geolocator.openAppSettings()`, which lands on the generic
  ///     App Info page and was the source of the "Open" button going
  ///     to the wrong place).
  ///
  /// Returns true when background location ends up granted; false on
  /// denied or if the user backed out of Settings without flipping
  /// the toggle.
  static Future<bool> requestBackgroundLocation(BuildContext context) async {
    // Foreground is a hard prerequisite. The OS won't surface the
    // background prompt at all without it, and the nudge wouldn't be
    // visible anyway if foreground hadn't been granted upstream — but
    // guard explicitly so a future caller landing here from a different
    // entry point still gets the right error path.
    final fg = await Geolocator.checkPermission();
    final fgGranted =
        fg == LocationPermission.always || fg == LocationPermission.whileInUse;
    if (!fgGranted) {
      Log.w(
        'permissions',
        'requestBackgroundLocation called without foreground granted; '
            'skipping (caller should prompt for foreground first)',
      );
      return false;
    }
    if (!context.mounted) return false;
    if (!await _showAlwaysAllowExplainer(context)) {
      Log.i('permissions', 'user declined the disclosure on the advisor nudge');
      return false;
    }
    final before = await Permission.locationAlways.status;
    final after = await Permission.locationAlways.request();
    Log.i(
      'permissions',
      'Background location (advisor nudge): before=$before → after=$after',
    );
    return after.isGranted;
  }

  /// Play's **prominent disclosure** for background location. Must be shown
  /// before *every* path that asks for it, which is why both [ensureAll] and
  /// [requestBackgroundLocation] route through here.
  ///
  /// Google's Location Permissions policy sets the shape, not our taste:
  /// it has to name the data ("location"), say it is collected in the
  /// background ("even when the app is closed or not in use"), say what the
  /// feature is, sit outside the privacy policy, and require an affirmative
  /// tap. Hence `barrierDismissible: false` and two explicit buttons — a
  /// dialog the user can swipe away doesn't count as consent. Rejections on
  /// this policy are common and cost a review cycle each, so keep the wording
  /// close to Google's own phrasing when editing.
  ///
  /// The third paragraph is not padding: the disclosure has to be *accurate*,
  /// and location does leave the device — a coarse fix goes to Google Places.
  /// It must match the hosted privacy policy; change both together.
  ///
  /// `true` = user opted in (we then trigger the OS flow, which on this
  /// minSdk deep-links to the per-app Location settings page); `false` = user
  /// declined, and the Stores in-app banner can nudge them later.
  static Future<bool> _showAlwaysAllowExplainer(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Allow location all the time?'),
        content: const SingleChildScrollView(
          child: Text(
            'SwipeWise collects location data to alert you when you arrive '
            'at a store where one of your cards earns extra rewards — even '
            'when the app is closed or not in use.\n\n'
            'Your device watches for those stores locally. To find stores '
            'near you, an approximate location is sent to Google Places. '
            'SwipeWise keeps no history of where you have been and sends '
            'your location nowhere else.\n\n'
            "Without this the app still works — you'll just miss arrival "
            'alerts.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static void _showSettingsSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(message),
        action: SnackBarAction(
          label: 'OPEN SETTINGS',
          onPressed: openAppSettings,
        ),
      ),
    );
  }

  static String _label(Permission p) {
    if (p == Permission.notification) return 'Notifications';
    if (p == Permission.activityRecognition) return 'Activity recognition';
    if (p == Permission.locationWhenInUse) return 'Location';
    if (p == Permission.locationAlways) return 'Background location';
    return p.toString();
  }
}
