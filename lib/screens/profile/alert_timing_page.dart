import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/settings_repository.dart';
import '../../providers/data_providers.dart';
import '../../providers/nearby_providers.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_theme.dart';
import 'profile_ui.dart';
import 'store_filter_sheet.dart';

/// Wireframe `apHmo` — how store alerts behave: the wait before one, and the
/// stores that never send one.
///
/// What the Stores list searches for (distance, kinds of places) lives in
/// Advisor's filter sheet instead, so every setting has exactly one home; the
/// last line here points there, because those kinds also decide which stores
/// can alert.
class AlertTimingPage extends ConsumerStatefulWidget {
  const AlertTimingPage({super.key});

  @override
  ConsumerState<AlertTimingPage> createState() => _AlertTimingPageState();
}

class _AlertTimingPageState extends ConsumerState<AlertTimingPage> {
  static const _waits = [60, 120, 180, 300, 480, 600, 900];

  static const _kindIcons = {
    'Dining': LucideIcons.utensils,
    'Coffee': LucideIcons.coffee,
    'Shopping': LucideIcons.shoppingBag,
    'Big-box': LucideIcons.warehouse,
    'Grocery': LucideIcons.shoppingCart,
    'Gas': LucideIcons.fuel,
  };

  /// Null until the user picks; then their pick, even when every kind
  /// happens to hold the same value.
  bool? _byKind;

  Future<void> _unmute(String merchantId) async {
    await ref.read(dataRepositoryProvider).unmuteMerchant(merchantId);
    ref.invalidate(mutedMerchantsListProvider);
    ref.invalidate(mutedMerchantIdsProvider);
    // ignore: unawaited_futures
    reregisterAfterMuteChange(ref);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final dwell = ref.watch(nearbyDwellProvider);
    final uniform = uniformDwell(dwell);
    final byKind = _byKind ?? uniform == null;
    final defaults = SettingsRepository.defaultDwellSeconds;
    final notifier = ref.read(nearbyDwellProvider.notifier);
    final muted = ref.watch(mutedMerchantsListProvider);

    return SettingsPage(
      title: 'Alert timing & muted stores',
      children: [
        SectionHeader(
          'Alert after',
          action: 'Reset',
          onAction: () {
            setState(() => _byKind = false);
            notifier.setAll(defaults.values.first);
          },
        ),
        SegmentedChoice<bool>(
          options: const [false, true],
          selected: byKind,
          labelOf: (k) => k ? 'By kind of visit' : 'Same for all',
          onChanged: (k) {
            setState(() => _byKind = k);
            // Back to one value: the shortest current wait, so no kind's
            // alert gets later than the user set it.
            if (!k && uniform == null) {
              notifier.setAll(dwell.values.reduce((a, b) => a < b ? a : b));
            }
          },
        ),
        const SizedBox(height: 12),
        SettingsGroup(
          children: byKind
              ? [
                  for (final kind in defaults.keys)
                    SettingsRow(
                      icon: _kindIcons[kind],
                      title: kind,
                      trailing: WaitStepper(
                        label: kind,
                        seconds: dwell[kind] ?? defaults[kind]!,
                        options: _waits,
                        onChanged: (s) => notifier.setSeconds(kind, s),
                      ),
                    ),
                ]
              : [
                  SettingsRow(
                    icon: LucideIcons.timer,
                    title: 'Every visit',
                    trailing: WaitStepper(
                      label: 'every visit',
                      seconds: uniform ?? dwell.values.first,
                      options: _waits,
                      onChanged: notifier.setAll,
                    ),
                  ),
                ],
        ),
        const GroupCaption(
          'How long you stay somewhere before we send one alert (1–15 min).',
        ),
        const SizedBox(height: kGroupGap),

        const SectionHeader('Muted stores'),
        muted.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const GroupCaption("Couldn't load muted stores."),
          data: (rows) => SettingsGroup(
            children: rows.isEmpty
                ? [SettingsRow(icon: LucideIcons.bellOff, title: 'None muted')]
                : [
                    for (final row in rows)
                      SettingsRow(
                        iconTile: IconTile(
                          LucideIcons.bellOff,
                          color: palette.muted,
                        ),
                        title: (row['name'] as String?) ?? 'Unknown store',
                        trailing: LinkAction(
                          label: 'Unmute',
                          onTap: () => _unmute(row['merchant_id'] as String),
                        ),
                      ),
                  ],
          ),
        ),
        const GroupCaption(
          'No alerts from these. Mute a store from the Stores list.',
        ),
        const SizedBox(height: kGroupGap),

        // A pointer, not a second copy of the control.
        Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kGroupRadius),
            side: BorderSide(color: palette.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: SettingsRow(
            iconTile: IconTile(
              LucideIcons.slidersHorizontal,
              color: palette.muted,
              background: Colors.transparent,
            ),
            title: 'Kinds of places · set in Advisor',
            subtitle: 'Only kinds turned on there can alert you.',
            chevron: true,
            onTap: () => showProfileSheet(context, const StoreFilterSheet()),
          ),
        ),
      ],
    );
  }
}

/// The single wait every kind of visit shares, or null when they differ.
int? uniformDwell(Map<String, int> dwell) {
  final values = dwell.values.toSet();
  return values.length == 1 ? values.single : null;
}

/// − value + pill. Snaps an off-list stored value to its nearest option.
class WaitStepper extends StatelessWidget {
  const WaitStepper({
    super.key,
    required this.label,
    required this.seconds,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final int seconds;
  final List<int> options;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final i = options.indexWhere((o) => o >= seconds);
    final idx = i == -1 ? options.length - 1 : i;
    Widget step(IconData icon, int? to, String semantics) => Semantics(
      label: semantics,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: to == null ? null : () => onChanged(to),
        child: SizedBox(
          width: 34,
          height: 32,
          child: Icon(
            icon,
            size: 16,
            color: to == null ? palette.muted.withValues(alpha: 0.4) : null,
          ),
        ),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          step(
            LucideIcons.minus,
            idx > 0 ? options[idx - 1] : null,
            'Shorter wait for $label',
          ),
          SizedBox(
            width: 50,
            child: Text(
              formatWait(seconds),
              textAlign: TextAlign.center,
              style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          step(
            LucideIcons.plus,
            idx < options.length - 1 ? options[idx + 1] : null,
            'Longer wait for $label',
          ),
        ],
      ),
    );
  }
}
