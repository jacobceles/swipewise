import 'package:flutter/services.dart';

import 'logger.dart';

/// Dart wrapper around the native `LinkProgressPlugin` on Android. Posts
/// and updates the in-progress notification that surfaces stage changes
/// during a bank link while the user has the app backgrounded.
///
/// Single ongoing notification; updates are in-place at a fixed
/// notification id on the native side. Use [show] to post / update,
/// [dismiss] to clear (on success / failure / cancel).
///
/// `alert: true` fires sound + vibration on the resulting update.
/// Reserve it for actionable transitions (security question, OTP,
/// captcha, token approval) and terminals (success / failure); status-
/// only ticks (polling, submitting an answer) should pass `alert:
/// false` so the user isn't pinged repeatedly while the flow churns
/// through internal state.
///
/// All methods no-op cleanly on platforms without the plugin registered
/// (iOS, Flutter web) — they log a warning the first time and otherwise
/// stay quiet. The Add Bank flow doesn't need to feature-detect.
class LinkProgressNotifier {
  LinkProgressNotifier._();

  static const _channel = MethodChannel('com.appsoflife/link_progress');

  static bool _unavailableLogged = false;

  /// Posts (or updates) the link-progress notification.
  ///
  /// [title] is the bold first line ("Linking your bank", "Chase link"
  /// — keep short, OS truncates aggressively).
  /// [body] is the per-stage detail line, also used as the expanded
  /// BigText style content.
  /// [alert] controls whether this specific update fires sound +
  /// vibration. The notification channel itself is IMPORTANCE_HIGH so
  /// alerts are allowed; the per-update `setOnlyAlertOnce` flag is
  /// inverted from this on the native side.
  /// [ongoing] keeps the notification persistent (can't be swiped
  /// away). Defaults to true while the flow is mid-link; the success /
  /// failure terminals call [dismiss] separately so the value here
  /// rarely needs to change.
  /// [indeterminate] shows the indeterminate progress bar. Pass false
  /// for the terminal "Linked" / "Couldn't link" surfaces if you want
  /// to drop the bar (the notification is normally dismissed at that
  /// point anyway).
  static Future<void> show({
    required String title,
    required String body,
    required bool alert,
    bool ongoing = true,
    bool indeterminate = true,
  }) async {
    try {
      await _channel.invokeMethod<void>('show', <String, dynamic>{
        'title': title,
        'body': body,
        'alert': alert,
        'ongoing': ongoing,
        'indeterminate': indeterminate,
      });
    } on MissingPluginException {
      _logUnavailableOnce();
    } catch (e, st) {
      Log.e('link-notif', 'show failed', e, st);
    }
  }

  /// Cancels the link-progress notification. Idempotent.
  static Future<void> dismiss() async {
    try {
      await _channel.invokeMethod<void>('dismiss');
    } on MissingPluginException {
      _logUnavailableOnce();
    } catch (e, st) {
      Log.e('link-notif', 'dismiss failed', e, st);
    }
  }

  static void _logUnavailableOnce() {
    if (_unavailableLogged) return;
    _unavailableLogged = true;
    Log.w(
      'link-notif',
      'native LinkProgressPlugin not available on this platform; '
          'notifications will no-op for the rest of this session',
    );
  }
}
