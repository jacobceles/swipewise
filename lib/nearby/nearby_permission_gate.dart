import 'package:material_ui/material_ui.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../util/logger.dart';

/// Every OS permission store alerts need, asked one at a time.
///
/// The first-run setup flow (`lib/screens/onboarding/setup_flow.dart`) calls
/// these from its own screens, each of which explains the ask right before
/// Android's dialog. They replaced `ensureAll`, which fired four OS dialogs
/// back to back on the first Home paint with no explanation but one.
///
/// **Location is asked through Geolocator, never `permission_handler`.** The
/// Stores tab requests foreground location through Geolocator too; if the two
/// plugins' requests overlap, the OS silently nulls one of them. The setup flow
/// holds `permissionGateCompleteProvider` while it is on screen, so the Stores
/// tab and geofence registration stay idle until it is done.
enum AskResult { granted, denied, blocked }

class NearbyPermissionGate {
  /// Notifications (POST_NOTIFICATIONS, Android 13+). [AskResult.blocked]
  /// when Android won't show its dialog any more: Settings is the only way.
  static Future<AskResult> askNotifications() async {
    final before = await Permission.notification.status;
    if (before.isGranted) return AskResult.granted;
    if (before.isPermanentlyDenied) return AskResult.blocked;
    final after = await Permission.notification.request();
    Log.i('permissions', 'Notifications: before=$before → after=$after');
    if (after.isGranted) return AskResult.granted;
    return after.isPermanentlyDenied ? AskResult.blocked : AskResult.denied;
  }

  /// Foreground location ("While using the app").
  static Future<AskResult> askLocation() async {
    final before = await Geolocator.checkPermission();
    if (_foreground(before)) return AskResult.granted;
    if (before == LocationPermission.deniedForever) return AskResult.blocked;
    final after = await Geolocator.requestPermission();
    Log.i(
      'permissions',
      'Location (Geolocator): before=$before → after=$after',
    );
    if (_foreground(after)) {
      if (await Geolocator.getLocationAccuracy() ==
          LocationAccuracyStatus.reduced) {
        Log.w(
          'permissions',
          'location granted as Approximate (reduced accuracy); '
              'geofencing needs Precise',
        );
      }
      return AskResult.granted;
    }
    return after == LocationPermission.deniedForever
        ? AskResult.blocked
        : AskResult.denied;
  }

  /// Background location ("Allow all the time"). On Android 11+ this opens
  /// the app's location page in Settings. The caller must have shown the
  /// prominent disclosure ([disclosureTitle] and the two paragraphs) on screen
  /// first, with an affirmative tap on it; the setup flow's screen is that
  /// disclosure, and [requestBackgroundLocation] shows it as a dialog.
  static Future<bool> askLocationAlways() async {
    final before = await Permission.locationAlways.status;
    if (before.isGranted) return true;
    final after = await Permission.locationAlways.request();
    Log.i('permissions', 'Background location: before=$before → after=$after');
    return after.isGranted;
  }

  /// Physical activity: tells driving from walking, so a store passed in the
  /// car doesn't alert.
  static Future<bool> askActivity() async {
    final before = await Permission.activityRecognition.status;
    if (before.isGranted) return true;
    if (before.isPermanentlyDenied) {
      await openAppSettings();
      return (await Permission.activityRecognition.status).isGranted;
    }
    final after = await Permission.activityRecognition.request();
    Log.i('permissions', 'Physical activity: before=$before → after=$after');
    return after.isGranted;
  }

  static Future<bool> askExactAlarms() async {
    final after = await Permission.scheduleExactAlarm.request();
    Log.i('permissions', 'Exact alarms → $after');
    return after.isGranted;
  }

  static Future<bool> askBattery() async {
    final after = await Permission.ignoreBatteryOptimizations.request();
    Log.i('permissions', 'Ignore battery optimizations → $after');
    return after.isGranted;
  }

  static bool _foreground(LocationPermission p) =>
      p == LocationPermission.always || p == LocationPermission.whileInUse;

  /// Play's prominent disclosure for background location, worded once and
  /// shown on every path that asks for it: the setup flow's "All the time"
  /// screen and its blocked variant, and [requestBackgroundLocation]'s dialog.
  ///
  /// Google's Location Permissions policy sets the shape: it has to name the
  /// data ("location"), say it is collected in the background ("even when the
  /// app is closed or not in use"), say what the feature is, sit outside the
  /// privacy policy, and require an affirmative tap. Rejections on this policy
  /// are common and cost a review cycle each, so keep it close to Google's own
  /// phrasing. The Google Places clause is not padding: location does leave the
  /// device, and the disclosure has to match the hosted privacy policy; change
  /// both together.
  static const disclosureTitle =
      'SwipeWise uses your location in the background';
  static const disclosureCollect =
      'SwipeWise collects location data in the background to send you store '
      'alerts — even when the app is closed or not in use.';
  static const disclosureUse =
      "Your location is used only to find the store you're in: an "
      'approximate location is sent to Google Places to look up stores near '
      'you. SwipeWise does not keep a location history.';

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

  /// [disclosureTitle]'s wording as a dialog, for the paths that ask from
  /// outside the setup flow (the Stores banner, Profile's Fix). The policy
  /// requires an affirmative tap, hence `barrierDismissible: false` and two
  /// explicit buttons: a dialog the user can swipe away doesn't count as
  /// consent.
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
            '$disclosureCollect\n\n$disclosureUse\n\n'
            "Without this the app still works; you'll just miss the alerts.",
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
}
