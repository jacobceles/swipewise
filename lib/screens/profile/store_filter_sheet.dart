import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../nearby/google_places_provider.dart';
import '../../nearby/place_roots.dart';
import '../../providers/nearby_providers.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_theme.dart';
import 'profile_ui.dart';
import '../../util/units.dart';

/// Wireframe `lwrJJ` — Advisor's filter (the tune button in Stores view):
/// how far to look and which kinds of places to look for.
///
/// Set here, beside the list they change. The kinds also decide which stores
/// get a walk-in fence, so the sheet says so; Settings' alert page points back
/// here rather than repeating the control.
class StoreFilterSheet extends ConsumerStatefulWidget {
  const StoreFilterSheet({super.key});

  @override
  ConsumerState<StoreFilterSheet> createState() => _StoreFilterSheetState();
}

class _StoreFilterSheetState extends ConsumerState<StoreFilterSheet> {
  static const _radii = [5, 10, 25];

  bool _allShown = false;

  Future<void> _reloadStores() async {
    await ref.read(tileCacheProvider).clearAll();
    await GooglePlacesProvider().resetCircuitBreaker();
    ref.invalidate(nearbyMerchantsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final radius = ref.watch(nearbyRadiusProvider);
    final types = ref.watch(nearbyPlaceTypesProvider);
    final visible = _allShown
        ? kPlaceRoots
        : kPlaceRoots.where((r) => types.contains(r.id)).toList();
    final hidden = kPlaceRoots.length - visible.length;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(kGutter, 4, kGutter, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The drag handle comes from the app's bottom-sheet theme.
            Padding(
              padding: const EdgeInsets.only(left: kRowInset),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Nearby stores',
                          style: AppText.titleLg().copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'What shows up in Stores.',
                          style: rowSubtitleStyle(palette),
                        ),
                      ],
                    ),
                  ),
                  Semantics(
                    label: 'Close',
                    button: true,
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: palette.secondary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(LucideIcons.x, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const SectionHeader('Search distance'),
            SegmentedChoice<int>(
              options: _radii,
              selected: radius,
              background: AppColors.background,
              labelOf: (m) => formatRadiusMi(m),
              onChanged: (m) => ref.read(nearbyRadiusProvider.notifier).set(m),
            ),
            const SizedBox(height: 24),
            SectionHeader(
              'Kinds of places',
              action: 'Reset',
              onAction: () async {
                await ref
                    .read(nearbyPlaceTypesProvider.notifier)
                    .resetToDefault();
                await _reloadStores();
              },
            ),
            SettingsGroup(
              color: AppColors.background,
              children: [
                for (final r in visible)
                  SettingsRow(
                    icon: r.icon,
                    title: r.label,
                    trailing: Switch.adaptive(
                      value: types.contains(r.id),
                      onChanged: (_) async {
                        await ref
                            .read(nearbyPlaceTypesProvider.notifier)
                            .toggle(r.id);
                        await _reloadStores();
                      },
                    ),
                  ),
                if (hidden > 0 || _allShown)
                  InkWell(
                    onTap: () => setState(() => _allShown = !_allShown),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        kTextColumn,
                        16,
                        kRowInset,
                        16,
                      ),
                      child: Row(
                        children: [
                          Text(
                            _allShown ? 'Show fewer' : 'Show $hidden more',
                            style: AppText.bodyMd(
                              color: AppColors.primary,
                            ).copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            _allShown
                                ? LucideIcons.chevronUp
                                : LucideIcons.chevronDown,
                            size: 16,
                            color: AppColors.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(kRowInset, 14, kRowInset, 0),
              child: Row(
                children: [
                  Icon(LucideIcons.bell, size: 15, color: palette.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'These also decide which stores can alert you.',
                      style: rowSubtitleStyle(palette),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
