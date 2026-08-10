import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../nearby/google_places_provider.dart';
import '../nearby/place_roots.dart';
import '../providers/nearby_providers.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

class NearbyCategoriesScreen extends ConsumerWidget {
  const NearbyCategoriesScreen({super.key});

  Future<void> _invalidateAndReload(WidgetRef ref) async {
    await ref.read(tileCacheProvider).clearAll();
    await GooglePlacesProvider().resetCircuitBreaker();
    ref.invalidate(nearbyMerchantsProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final selected = ref.watch(nearbyPlaceTypesProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).maybePop(),
                        child: Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: palette.secondary,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(LucideIcons.chevronLeft, size: 18),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Nearby Categories',
                        style: AppText.titleLg().copyWith(fontSize: 18),
                      ),
                    ],
                  ),
                  GestureDetector(
                    onTap: () async {
                      await ref
                          .read(nearbyPlaceTypesProvider.notifier)
                          .resetToDefault();
                      await _invalidateAndReload(ref);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: palette.secondary,
                        borderRadius: BorderRadius.circular(kRadiusPill),
                      ),
                      child: Text(
                        'Reset',
                        style: AppText.bodyMd().copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SHOW IN STORES', style: AppText.labelSm()),
                  const SizedBox(height: 6),
                  Text(
                    'Pick which categories Stores pulls nearby places from. '
                    'Wallet recommendations are unaffected.',
                    style: AppText.bodySm(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                itemCount: kPlaceRoots.length,
                itemBuilder: (context, i) {
                  final r = kPlaceRoots[i];
                  final isOn = selected.contains(r.id);
                  return _CategoryRow(
                    root: r,
                    isOn: isOn,
                    onTap: () async {
                      await ref
                          .read(nearbyPlaceTypesProvider.notifier)
                          .toggle(r.id);
                      await _invalidateAndReload(ref);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.root,
    required this.isOn,
    required this.onTap,
  });

  final PlaceRoot root;
  final bool isOn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.border)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.secondary,
                shape: BoxShape.circle,
              ),
              child: Icon(root.icon, size: 18, color: AppColors.foreground),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(root.label, style: AppText.titleMd()),
                  const SizedBox(height: 2),
                  Text(root.description, style: AppText.bodySm()),
                ],
              ),
            ),
            Switch.adaptive(
              value: isOn,
              onChanged: (_) => onTap(),
              activeThumbColor: AppColors.primary,
            ),
          ],
        ),
      ),
    );
  }
}
