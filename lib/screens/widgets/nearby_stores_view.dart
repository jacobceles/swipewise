import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../nearby/location_service.dart';
import '../../nearby/merchant.dart';
import '../../nearby/merchant_search_provider.dart';
import '../../nearby/nearby_permission_gate.dart';
import '../../providers/data_providers.dart';
import '../../providers/nearby_providers.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_theme.dart';
import '../../util/category_icons.dart';
import '../reward_ranking_sheet.dart';

/// Lives inside Advisor → Stores tab. Renders a list of nearby merchants
/// with their best reward card / rate, or a state card explaining why
/// the list is empty.
class NearbyStoresView extends ConsumerStatefulWidget {
  const NearbyStoresView({super.key, this.query = ''});

  /// Free-text filter applied to the merchant list. Case-insensitive.
  final String query;

  @override
  ConsumerState<NearbyStoresView> createState() => _NearbyStoresViewState();
}

class _NearbyStoresViewState extends ConsumerState<NearbyStoresView>
    with WidgetsBindingObserver {
  /// Tracks a genuine background trip so we only refresh on a real
  /// background→foreground return, not on transient `inactive⇄resumed`
  /// focus flicker. See [didChangeAppLifecycleState].
  bool _wasBackgrounded = false;

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` fires for *transient* focus loss — a system dialog, the
    // app-switcher peek, or the geolocator plugin attaching to the activity
    // during a one-shot fix — and is immediately followed by `resumed`.
    // Invalidating the nearby providers on every `resumed` turned that
    // flicker into a feedback storm: each invalidation re-ran
    // `nearbyMerchantsProvider`, whose `getCurrentPosition` call flipped the
    // activity focus again, ~30x/sec, so the location fix never completed and
    // the tab never loaded. Only refresh after a REAL background trip
    // (`paused`), which is also when the user may have changed permission in
    // system settings — the case this refresh exists for.
    if (state == AppLifecycleState.paused) {
      _wasBackgrounded = true;
    } else if (state == AppLifecycleState.resumed && _wasBackgrounded) {
      _wasBackgrounded = false;
      ref.invalidate(locationPermissionProvider);
      ref.invalidate(reliabilityGrantsProvider);
      ref.invalidate(nearbyMerchantsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(nearbyEnabledProvider);
    if (!enabled) {
      return const _StateCard(
        icon: LucideIcons.mapPinOff,
        title: 'Nearby stores turned off',
        subtitle: 'Turn it on in Profile to see stores near you.',
      );
    }
    final permAsync = ref.watch(locationPermissionProvider);
    final async = ref.watch(nearbyMerchantsProvider);
    // The merchants provider deliberately returns `const []` until the
    // up-front permission gate finishes - which lands as `hasValue=true,
    // value=[]` and used to render the "No nearby stores found" empty
    // card. We surface the gate state separately so the view can show a
    // loader until both the gate is done AND the provider has produced
    // real (non-synthetic-empty) data.
    final gateDone = ref.watch(permissionGateCompleteProvider);

    // One nudge at a time, most fundamental first: without background
    // location nothing fires at all, so the reliability banner waits its
    // turn instead of stacking a second card.
    final needsBgBanner = permAsync.maybeWhen(
      data: (p) => isAtLeastWhileInUse(p) && !isAlwaysAllowed(p),
      orElse: () => false,
    );
    final needsReliabilityBanner =
        !needsBgBanner &&
        ref
            .watch(reliabilityGrantsProvider)
            .maybeWhen(data: (granted) => !granted, orElse: () => false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (needsBgBanner) const _BackgroundPermissionBanner(),
        if (needsReliabilityBanner) const _ReliabilityBanner(),
        _buildBody(async, gateDone: gateDone),
      ],
    );
  }

  Widget _buildBody(
    AsyncValue<List<NearbyMerchantWithReward>> async, {
    required bool gateDone,
  }) {
    // Pre-gate the data check: while the permission gate hasn't flipped
    // yet, or while an in-flight refresh is replacing an empty result,
    // show the loader instead of the "no stores found" empty card.
    // Without this, the user lands on the tab during the brief window
    // where `nearbyMerchantsProvider` already settled to `[]` from the
    // pre-gate run and stays on the empty-state card until they pull to
    // refresh.
    final merchants = async.hasValue ? async.requireValue : null;
    final showLoader =
        !gateDone ||
        (async.isLoading && (merchants == null || merchants.isEmpty));
    if (showLoader) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (merchants != null) {
      if (merchants.isEmpty) {
        return const _StateCard(
          icon: LucideIcons.mapPinOff,
          title: 'No nearby stores found',
          subtitle: "We couldn't find stores near you. Check back later.",
        );
      }
      final filtered = _applyQuery(merchants, widget.query);
      if (filtered.isEmpty) {
        return _StateCard(
          icon: LucideIcons.searchX,
          title: 'No matching stores',
          subtitle:
              'No nearby stores match "${widget.query.trim()}". Try a different term.',
        );
      }
      return Column(
        children: [for (final m in filtered) _StoreRow(merchant: m)],
      );
    }
    if (async.hasError) {
      final e = async.error!;
      return _StateCard(
        icon: _iconForError(e),
        title: _titleForError(e),
        subtitle: _subtitleForError(e),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  List<NearbyMerchantWithReward> _applyQuery(
    List<NearbyMerchantWithReward> merchants,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return merchants;
    return merchants.where((m) {
      final name = m.name.toLowerCase();
      final label = (m.merchant.category ?? '').toLowerCase();
      final resolved = (m.resolvedLabel ?? '').toLowerCase();
      return name.contains(q) || label.contains(q) || resolved.contains(q);
    }).toList();
  }

  IconData _iconForError(Object e) {
    if (e is LocationDenied || e is LocationServiceDisabled) {
      return LucideIcons.mapPinOff;
    }
    if (e is MissingPlacesApiKey) return LucideIcons.keyRound;
    if (e is MerchantSearchUnavailable) return LucideIcons.cloudOff;
    return LucideIcons.triangleAlert;
  }

  String _titleForError(Object e) {
    if (e is LocationDenied) return 'Location permission needed';
    if (e is LocationServiceDisabled) return 'Location services off';
    return 'Could not load nearby stores';
  }

  String _subtitleForError(Object e) {
    if (e is LocationDenied) {
      return 'Allow location to see stores near you.';
    }
    if (e is LocationServiceDisabled) {
      return 'Turn on location services to see stores near you.';
    }
    return '';
  }
}

class _BackgroundPermissionBanner extends ConsumerWidget {
  const _BackgroundPermissionBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.amberBg,
        borderRadius: BorderRadius.circular(kRadiusS),
        border: Border.all(color: palette.amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(LucideIcons.bell, size: 18, color: palette.amber),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Allow background location',
                  style: AppText.titleMd().copyWith(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  'To get card alerts when you arrive at a store, set Location to "Allow all the time".',
                  style: AppText.bodySm().copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              // Routes through the same explainer + `Permission
              // .locationAlways.request()` the onboarding gate uses.
              // On Android 10 this is the in-app system dialog;
              // on Android 11+ it deep-links straight to the
              // per-app Location permission page (NOT the App Info
              // page, which was the previous failure mode when this
              // button called `Geolocator.openAppSettings()`).
              await NearbyPermissionGate.requestBackgroundLocation(context);
              // Refresh status so the banner hides immediately on
              // Android 10's in-app grant path. The Android 11+
              // path goes through Settings, and the parent view's
              // WidgetsBindingObserver re-invalidates on resume —
              // this explicit invalidate covers the in-app dialog
              // case where the app never loses foreground.
              if (context.mounted) {
                ref.invalidate(locationPermissionProvider);
              }
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: AppColors.primary,
            ),
            child: Text(
              'Open',
              style: AppText.titleMd(
                color: AppColors.primary,
              ).copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Detect-and-nudge for the two background-reliability grants (exact alarms
/// + unrestricted battery), mirroring [_BackgroundPermissionBanner]. Shows
/// whenever either grant is missing; pressing "Open" is the opt-in, so no
/// extra explainer modal (same reasoning as the background-location nudge).
class _ReliabilityBanner extends ConsumerWidget {
  const _ReliabilityBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.amberBg,
        borderRadius: BorderRadius.circular(kRadiusS),
        border: Border.all(color: palette.amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(LucideIcons.batteryCharging, size: 18, color: palette.amber),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Make store alerts reliable',
                  style: AppText.titleMd().copyWith(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  '"Alarms & reminders" is the timer that fires your alert '
                  '~1 min after you walk in (no alarms are set). '
                  'Unrestricted battery stops Android from pausing alerts '
                  'in the background. Don\'t worry — neither has a '
                  'noticeable effect on battery life.',
                  style: AppText.bodySm().copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              await NearbyPermissionGate.requestReliability();
              // The exact-alarm path bounces through Settings, so the
              // parent view's resume hook re-invalidates; this explicit
              // invalidate covers the battery dialog, which can keep the
              // app foregrounded the whole time.
              if (context.mounted) {
                ref.invalidate(reliabilityGrantsProvider);
              }
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: AppColors.primary,
            ),
            child: Text(
              'Open',
              style: AppText.titleMd(
                color: AppColors.primary,
              ).copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _StoreRow extends ConsumerWidget {
  const _StoreRow({required this.merchant});
  final NearbyMerchantWithReward merchant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final bestLine = _bestCardLine(merchant);
    final label = merchant.resolvedLabel;
    final isMuted = ref
        .watch(mutedMerchantIdsProvider)
        .maybeWhen(
          data: (ids) => ids.contains(merchant.merchant.id),
          orElse: () => false,
        );

    final iconData = iconForCategory(merchant.category);
    final colors = colorsForCategory(
      merchant.category,
      iconId: merchant.category,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        child: InkWell(
          borderRadius: BorderRadius.circular(kRadiusM),
          onTap: label == null || label.isEmpty
              ? null
              : () => showRewardRankingSheetForLabel(
                  context,
                  label: label,
                  primary: RewardRankingPrimary.brand,
                  merchantName: merchant.name,
                ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusM),
              border: Border.all(color: palette.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.bgColor,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(iconData, size: 18, color: colors.iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              merchant.name,
                              style: AppText.titleMd().copyWith(fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${merchant.distanceMi.toStringAsFixed(1)} mi',
                            style: AppText.monoXs().copyWith(fontSize: 11),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        bestLine,
                        style: AppText.bodySm(
                          color: AppColors.primary,
                        ).copyWith(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      if (merchant.isTemporarilyClosed) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Temporarily closed',
                          style: AppText.bodySm(
                            color: palette.amber,
                          ).copyWith(fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: isMuted ? AppColors.primary : AppColors.foreground,
                  icon: Icon(isMuted ? LucideIcons.bellOff : LucideIcons.bell),
                  tooltip: isMuted ? 'Unmute alerts' : 'Mute alerts',
                  onPressed: () => _toggleMute(context, ref, isMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleMute(
    BuildContext context,
    WidgetRef ref,
    bool currentlyMuted,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(dataRepositoryProvider);
    final placeId = merchant.merchant.id;
    if (currentlyMuted) {
      await repo.unmuteMerchant(placeId);
    } else {
      await repo.muteMerchant(placeId, merchant.name);
    }
    ref.invalidate(mutedMerchantIdsProvider);
    // Re-register so the fence set reflects the change promptly (mute frees a
    // slot under the 50-fence cap; unmute restores the fence). Fire-and-forget
    // — the SnackBar shouldn't wait on a location fix + Places round-trip.
    // ignore: unawaited_futures
    reregisterAfterMuteChange(ref);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          currentlyMuted
              ? 'Alerts on for ${merchant.name}'
              : 'Alerts muted for ${merchant.name}',
        ),
      ),
    );
  }

  String _bestCardLine(NearbyMerchantWithReward m) {
    if (m.bestCardName == null || m.bestCardName!.isEmpty) {
      return 'No matched card';
    }
    final rate = m.bestRate;
    final r = rate == null
        ? null
        : (rate % 1 == 0 ? rate.toInt().toString() : rate.toStringAsFixed(1));
    final base = r == null
        ? 'Best: ${m.bestCardName}'
        : 'Best: ${m.bestCardName} · $r%';
    if (m.matchedBrand != null && m.matchedBrand!.isNotEmpty) {
      return '$base · ${m.matchedBrand} bonus';
    }
    return base;
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.secondary,
              borderRadius: BorderRadius.circular(kRadiusM),
            ),
            child: Icon(icon, size: 24, color: palette.muted),
          ),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: AppText.titleMd()),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppText.bodySm(),
            ),
          ],
        ],
      ),
    );
  }
}
