import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../api/data_repository.dart';
import '../api/settings_repository.dart';
import '../providers/entitlement_provider.dart';
import '../nearby/geofence_channel.dart';
import '../nearby/nearby_permission_gate.dart';
import '../providers/auth_provider.dart';
import '../providers/sync_provider.dart';
import '../providers/data_providers.dart';
import '../providers/payment_reminder_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../util/logger.dart';
import '../widgets/app_tab_bar.dart';
import 'dashboard_screen.dart';
import 'cards_screen.dart';
import 'advisor_screen.dart';
import 'breakdown_screen.dart';
import 'disambiguation_sheet.dart';
import 'profile_screen.dart';
import 'reward_ranking_sheet.dart';
import 'widgets/reconciliation_sheet.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  /// The tab the user tapped, or null to follow the saved preference.
  ///
  /// Deliberately not "the current tab seeded from the preference": that
  /// version depended on `ref.listen` firing, which it only does on a
  /// *change*. When the stored value already equals the provider's initial
  /// value — the normal case on a fresh install, both being `transactions` —
  /// no change is ever emitted, so the seed is whatever was hard-coded. That
  /// made the landing tab differ between debug and release builds off
  /// identical Dart. Deriving it in `build` instead is timing-independent.
  ShellTab? _userPicked;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _askPermissionsOnce();
      _consumePendingMerchant();
      _topUpPaymentReminders();
    });
  }

  /// Tops up the rolling payment-reminder schedule (N12).
  ///
  /// Reminders are individual calendar instants — a day-of-month has no repeat
  /// interval the plugin can express — so only a few months are ever scheduled
  /// ahead. Re-running on app open keeps that window full without needing a
  /// background job.
  Future<void> _topUpPaymentReminders() async {
    // Wait for the wallet to load: rescheduling off an empty card list would
    // cancel every reminder and schedule nothing back.
    await ref.read(cardsProvider.future);
    if (!mounted) return;
    await ref.read(paymentReminderControllerProvider).reschedule();
  }

  /// Fires the four OS permission dialogs (notifications, activity
  /// recognition, foreground location, background location) exactly once
  /// per install - on first HomeScreen entry after login. Re-enabling
  /// later requires the system Settings.
  ///
  /// Flips `permissionGateCompleteProvider` true on either exit path -
  /// the Stores tab's nearby providers watch this and stay idle until
  /// it's true so their Geolocator request doesn't race the gate.
  Future<void> _askPermissionsOnce() async {
    final auth = ref.read(authProvider);
    final userId = auth.userId;
    if (userId == null) return;
    final repo = ref.read(dataRepositoryProvider);
    final settings = SettingsRepository(repo);
    void markGateDone() {
      ref.read(permissionGateCompleteProvider.notifier).markComplete();
    }

    if (await settings.getPermissionsAsked(userId)) {
      markGateDone();
      return;
    }
    if (!mounted) {
      markGateDone();
      return;
    }
    await NearbyPermissionGate.ensureAll(context);
    await settings.setPermissionsAsked(userId);
    markGateDone();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _consumePendingMerchant();
    }
  }

  Future<void> _consumePendingMerchant() async {
    try {
      final pending = await GeofenceChannel.consumePendingMerchant();
      if (pending == null || pending.isEmpty || !mounted) return;
      if (pending.length > 1) {
        await showDisambiguationSheet(context, options: pending);
        return;
      }
      final only = pending.single;
      final cat = only.category;
      if (cat == null || cat.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Tap on ${only.name} - no category data")),
        );
        return;
      }
      await showRewardRankingSheetForLabel(
        context,
        label: cat,
        primary: RewardRankingPrimary.brand,
        merchantName: only.name,
      );
    } catch (_) {
      // Channel call may fail before native side is wired; ignore.
    }
  }

  void _onTabTap(ShellTab tab) {
    setState(() => _userPicked = tab);
  }

  /// Resolves the saved "default screen" preference to a tab this build has.
  ///
  /// The stored value can name a tab that doesn't exist here — the shipped
  /// default is `transactions`, and a user who upgrades free → Pro → free
  /// could have saved `breakdown`. Falling through to Advisor keeps the
  /// setting honest instead of indexing into a tab bar that has no such
  /// entry; Advisor is the free build's whole point, so it's the right
  /// landing spot regardless.
  ShellTab _shellTabFromDefault(DefaultScreen s, List<ShellTab> tabs) {
    final tab = shellTabForDefaultScreen(s);
    return tabs.contains(tab) ? tab : ShellTab.advisor;
  }

  /// Called after a successful sync. For each `institution_id` the user
  /// linked or reconnected via addbank since the last drain, look up the
  /// resulting card(s) and check whether any orphan transactions match
  /// their `last_four`. Show the reconciliation sheet for each match
  /// group sequentially. Each entry is dequeued whether the sheet shows
  /// or not, so we never re-prompt the same link after a fresh sync.
  Future<void> _drainPendingReconciliation() async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    final pending = ref.read(pendingReconciliationProvider);
    if (pending.isEmpty) return;
    final notifier = ref.read(pendingReconciliationProvider.notifier);
    final repo = DataRepository();
    for (final institutionId in pending.toList()) {
      notifier.dequeue(institutionId);
      final cards = await repo.queryCardsByInstitutionId(
        userId: userId,
        institutionId: institutionId,
      );
      for (final card in cards) {
        final lastFour = card['last_four'] as String?;
        final cardId = card['id'] as String;
        if (lastFour == null || lastFour.isEmpty) continue;
        final orphans = await repo.findOrphanTransactionGroupsForLastFour(
          userId: userId,
          lastFour: lastFour,
        );
        if (orphans.isEmpty) continue;
        if (!mounted) return;
        final bankName =
            (card['provider'] as String?) ??
            (await repo.lookupInstitutionName(institutionId)) ??
            'this bank';
        final groups = orphans
            .map(
              (o) => OrphanReconciliationGroup(
                orphanCardId: o.orphanCardId,
                institutionName: o.institutionName,
                txCount: o.txCount,
                earliest: DateTime.tryParse(o.earliest ?? ''),
                latest: DateTime.tryParse(o.latest ?? ''),
              ),
            )
            .toList();
        if (!mounted) return;
        // `mounted` is on the ConsumerState - the lint flags it as
        // "unrelated" to the State.context but the two share lifetime in
        // a State subclass. Suppress narrowly.
        // ignore: use_build_context_synchronously
        await showModalBottomSheet<bool>(
          // ignore: use_build_context_synchronously
          context: context,
          isScrollControlled: true,
          // ignore: use_build_context_synchronously
          backgroundColor: AppPalette.of(context).sheet,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          builder: (_) => ReconciliationSheet(
            newCardId: cardId,
            newBankName: bankName,
            newLastFour: lastFour,
            groups: groups,
          ),
        );
      }
    }
  }

  void _showSnack({
    required String message,
    required IconData icon,
    required Color iconColor,
    Duration duration = const Duration(seconds: 3),
  }) {
    final palette = AppPalette.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: duration,
          backgroundColor: palette.sheet,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 84),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRadiusS),
            side: BorderSide(color: palette.border),
          ),
          content: Row(
            children: [
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: 12),
              Expanded(child: Text(message, style: AppText.bodyMd())),
            ],
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // Changing the preference in Profile should move the user to that tab, so
    // drop their manual pick and fall back to following the setting again.
    ref.listen<DefaultScreen>(defaultScreenProvider, (prev, next) {
      if (_userPicked != null) setState(() => _userPicked = null);
    });

    final isPro = ref.watch(proEntitlementProvider);
    final tabs = shellTabs(isPro);
    final active =
        _userPicked ??
        _shellTabFromDefault(ref.watch(defaultScreenProvider), tabs);

    // Sync-outcome UI: a "Synced" toast, a failure toast, and the orphan-
    // transaction reconciliation sheet — all of which talk about banks. Free
    // never transitions `syncProvider`, so none of it fires today, but that
    // is an invariant several files away rather than anything structural.
    // Gating the listener itself is what keeps it true when someone later
    // wires a pull-to-refresh into the Cards screen.
    if (isPro) {
      ref.listen<AsyncValue<void>>(syncProvider, (prev, next) {
        next.whenOrNull(
          data: (_) {
            if (prev is AsyncLoading) {
              Log.i('ui', 'snackbar: Synced');
              _showSnack(
                message: 'Synced',
                icon: LucideIcons.check,
                iconColor: AppPalette.of(context).green,
                duration: const Duration(seconds: 2),
              );
              _drainPendingReconciliation();
            }
          },
          error: (e, _) {
            final msg = 'Sync failed: $e';
            Log.w('ui', 'snackbar: $msg');
            _showSnack(
              message: msg,
              icon: LucideIcons.triangleAlert,
              iconColor: AppPalette.of(context).red,
              duration: const Duration(seconds: 6),
            );
          },
        );
      });
    }

    // Order must match `shellTabs(isPro)` — that list is what the index below
    // is taken from, and the two drifting apart is the failure this assert
    // catches. The Pro screens are built only when entitled; they are present
    // in the binary either way, which is the point of the subscription model.
    final children = <Widget>[
      if (isPro) const DashboardScreen(),
      const CardsScreen(),
      if (isPro) const BreakdownScreen(),
      const AdvisorScreen(),
      const ProfileScreen(),
    ];
    assert(
      children.length == tabs.length,
      'IndexedStack children and shellTabs() have drifted apart',
    );
    final body = IndexedStack(index: tabs.indexOf(active), children: children);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: AppTabBar(tabs: tabs, active: active, onTap: _onTabTap),
            ),
          ),
        ],
      ),
    );
  }
}
