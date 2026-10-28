import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../nearby/nearby_permission_gate.dart';
import '../../providers/nearby_providers.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_theme.dart';
import 'alert_timing_page.dart';
import 'profile_ui.dart';

/// The store-alerts group: the master switch for the whole Nearby feature,
/// the phone settings an alert needs, and the way into alert timing.
///
/// Quiet when everything works — one row that says so. Only a missing setting
/// opens it up, one row each with its own fix, plus a line naming the ones
/// that are fine. Notifications or location missing means no alert can arrive
/// ("paused"); battery or alarms only make them late.
class StoreAlertsCard extends ConsumerStatefulWidget {
  const StoreAlertsCard({super.key});

  @override
  ConsumerState<StoreAlertsCard> createState() => _StoreAlertsCardState();
}

class _StoreAlertsCardState extends ConsumerState<StoreAlertsCard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Every fix leaves for Android settings; re-check on the way back so the
  // card never shows a setting the user has just changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    ref.invalidate(alertChecksProvider);
    ref.invalidate(locationPermissionProvider);
    ref.invalidate(locationReducedAccuracyProvider);
    ref.invalidate(reliabilityGrantsProvider);
  }

  Future<void> _fix(AlertCheck check) async {
    await fixAlertCheck(context, check);
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final enabled = ref.watch(nearbyEnabledProvider);
    final checks = ref.watch(alertChecksProvider).value;
    final reducedAccuracy =
        ref.watch(locationReducedAccuracyProvider).value ?? false;
    final missing = !enabled || checks == null
        ? const <AlertCheck>[]
        : [
            for (final c in AlertCheck.values)
              if (checks[c] == false) c,
          ];
    final fine = [
      for (final c in AlertCheck.values)
        if (!missing.contains(c)) c,
    ];
    final paused =
        missing.contains(AlertCheck.notifications) ||
        missing.contains(AlertCheck.location);
    final lateChecks = [
      for (final c in missing)
        if (c == AlertCheck.battery || c == AlertCheck.alarms) c,
    ];
    final late = !paused && lateChecks.isNotEmpty;
    final headerMissingCount = paused ? missing.length : lateChecks.length;

    final (title, subtitle, icon, tint, tintBg) = !enabled
        ? (
            'Store alerts',
            'Get your best card as you walk in',
            LucideIcons.store,
            AppColors.foreground,
            palette.secondary,
          )
        : !paused && !late
        ? (
            'Store alerts',
            "All set — we'll nudge you in stores",
            LucideIcons.store,
            AppColors.primary,
            palette.amberBg,
          )
        : (
            paused ? 'Store alerts are paused' : 'Alerts may be late',
            '${countOf(headerMissingCount, 'phone setting')} '
                '${headerMissingCount == 1 ? 'needs' : 'need'} a quick fix',
            paused ? LucideIcons.bellOff : LucideIcons.bellRing,
            paused ? palette.red : palette.amber,
            paused ? palette.redBg : palette.amberBg,
          );

    return SettingsGroup(
      children: [
        SettingsRow(
          iconTile: IconTile(icon, color: tint, background: tintBg),
          title: title,
          subtitle: subtitle,
          trailing: Switch.adaptive(
            value: enabled,
            onChanged: (v) =>
                ref.read(nearbyEnabledProvider.notifier).setEnabled(v),
          ),
        ),
        if (missing.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final c in missing) ...[
                if (c != missing.first)
                  Divider(
                    height: 1,
                    indent: kTextColumn,
                    color: palette.border,
                  ),
                SettingsRow(
                  title: checkLabel(c),
                  subtitle: _hint(c, reducedAccuracy: reducedAccuracy),
                  trailing: ActionPill(
                    label: _allows(c) ? 'Allow' : 'Fix',
                    onTap: () => _fix(c),
                  ),
                ),
              ],
              if (fine.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    kTextColumn,
                    0,
                    kRowInset,
                    14,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        LucideIcons.circleCheck,
                        size: 15,
                        color: palette.muted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          fineLine(fine),
                          style: rowSubtitleStyle(palette),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        SettingsRow(
          icon: LucideIcons.timer,
          title: 'Alert timing & muted stores',
          chevron: true,
          onTap: () => pushSettingsPage(context, const AlertTimingPage()),
        ),
      ],
    );
  }

  static bool _allows(AlertCheck c) =>
      c == AlertCheck.notifications ||
      c == AlertCheck.activity ||
      c == AlertCheck.alarms;

  static String _hint(AlertCheck c, {bool reducedAccuracy = false}) =>
      switch (c) {
        AlertCheck.notifications => 'Needed to show an alert',
        AlertCheck.location =>
          reducedAccuracy
              ? 'Precise location needed — turn on “Use precise location”'
              : '“Allow all the time”, so alerts work when the app is closed',
        AlertCheck.activity => 'Tells walking in from driving past',
        AlertCheck.battery => '“Unrestricted”, so Android doesn’t pause alerts',
        AlertCheck.alarms =>
          'Times the alert for about a minute after you walk in',
      };
}

String checkLabel(AlertCheck c) => switch (c) {
  AlertCheck.notifications => 'Notifications',
  AlertCheck.location => 'Location',
  AlertCheck.activity => 'Physical activity',
  AlertCheck.battery => 'Battery',
  AlertCheck.alarms => 'Alarms',
};

/// "Location is fine", "Battery and alarms are fine", "Notifications,
/// location and alarms are fine".
String fineLine(List<AlertCheck> fine) {
  final names = [
    for (var i = 0; i < fine.length; i++)
      i == 0 ? checkLabel(fine[i]) : checkLabel(fine[i]).toLowerCase(),
  ];
  if (names.length == 1) {
    return '${names.single} ${names.single.endsWith('s') ? 'are' : 'is'} fine';
  }
  final head = names.sublist(0, names.length - 1).join(', ');
  return '$head and ${names.last} are fine';
}

/// Takes the user to the one place that grants [check].
///
/// Background location goes through [NearbyPermissionGate] on purpose: Play
/// requires its prominent disclosure before every background-location request,
/// so there must be exactly one path that asks.
Future<void> fixAlertCheck(BuildContext context, AlertCheck check) async {
  switch (check) {
    case AlertCheck.notifications:
      final status = await Permission.notification.request();
      if (!status.isGranted) await openAppSettings();
    case AlertCheck.location:
      var fg = await Geolocator.checkPermission();
      if (fg == LocationPermission.denied) {
        fg = await Geolocator.requestPermission();
      }
      if (fg == LocationPermission.denied ||
          fg == LocationPermission.deniedForever ||
          fg == LocationPermission.unableToDetermine) {
        await openAppSettings();
        return;
      }
      try {
        if (await Geolocator.getLocationAccuracy() ==
            LocationAccuracyStatus.reduced) {
          await openAppSettings();
          return;
        }
      } catch (_) {}
      if (context.mounted) {
        await NearbyPermissionGate.requestBackgroundLocation(context);
      }
    case AlertCheck.activity:
      await NearbyPermissionGate.askActivity();
    case AlertCheck.battery:
      await Permission.ignoreBatteryOptimizations.request();
    case AlertCheck.alarms:
      await Permission.scheduleExactAlarm.request();
  }
}
