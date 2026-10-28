import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../api/data_repository.dart';
import '../api/settings_repository.dart';
import '../models/card.dart';
import '../providers/entitlement_provider.dart';
import '../nearby/geofence_channel.dart';
import '../providers/auth_provider.dart';
import '../providers/backup_provider.dart';
import '../providers/bank_sync_provider.dart';
import '../providers/sync_provider.dart';
import '../providers/data_providers.dart';
import '../providers/activation_reminder_provider.dart';
import '../providers/payment_reminder_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../util/logger.dart';
import '../widgets/app_tab_bar.dart';
import 'dashboard_screen.dart';
import 'onboarding/setup_flow.dart';
import 'cards_screen.dart';
import 'advisor_screen.dart';
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
      _consumePendingMerchant();
      _topUpPaymentReminders();
      // Restore first: it refuses a wallet that already has cards, so a bank
      // sync landing first on a new phone would block the backup's manual
      // cards and nicknames from coming back. And setup waits for it too: a
      // signed-in user with a backup must land on "cards added", not be asked
      // to add the cards they already have.
      // At most 10 s: a slow network must not hold setup back, and a restore
      // landing later still moves "Add your cards" on by itself.
      () async {
        await _awaitUserId();
        if (!mounted) return;
        final restore = _maybeRestoreWallet().catchError((Object _) {});
        await restore.timeout(const Duration(seconds: 10), onTimeout: () {});
        if (!mounted) return;
        _askPermissionsOnce();
        restore.whenComplete(() {
          if (mounted) _syncBanksIfDue();
        });
      }();
    });
  }

  /// How stale bank data may get before opening the app syncs it.
  static const _autoSyncAfter = Duration(hours: 12);

  /// Syncs linked banks when the app opens or comes back to the foreground and
  /// the last sync is older than [_autoSyncAfter]. The only other triggers are
  /// pull-to-refresh and linking a bank — there is no background sync — so
  /// without this a bank could go stale, or need reconnecting, unnoticed.
  /// `runSync` itself no-ops without Pro or aggregator credentials.
  Future<void> _syncBanksIfDue() async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    final last = await SettingsRepository(
      ref.read(dataRepositoryProvider),
    ).getLastSyncAt(userId);
    if (last != null &&
        DateTime.now().toUtc().difference(last.toUtc()) < _autoSyncAfter) {
      return;
    }
    if (!mounted) return;
    await ref.read(bankSyncProvider.notifier).runSync(forceRefresh: false);
  }

  /// Pulls a wallet backup down onto an empty device.
  ///
  /// Fire-and-forget, and silent on every outcome except a successful restore:
  /// having no backup is the normal case for most launches, and announcing it
  /// would be noise. The controller decides whether anything should happen at
  /// all — notably, it refuses to touch a wallet that already has cards.
  Future<void> _maybeRestoreWallet() async {
    final outcome = await ref
        .read(walletBackupControllerProvider)
        .maybeAutoRestore();
    if (!mounted || outcome != RestoreOutcome.restored) return;
    for (final p in syncInvalidatedProviders) {
      ref.invalidate(p);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Wallet restored from your backup.')),
    );
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
    // Same top-up for the quarter-start activation reminders (D2/N3), which
    // read the card→product links the catalog hydration writes.
    await ref.read(catalogReadyProvider.future);
    if (!mounted) return;
    await ref.read(activationReminderControllerProvider).reschedule();
  }

  /// Waits for the device-local identity to land.
  ///
  /// `_askPermissionsOnce` runs from a post-frame callback on the first build,
  /// which fires *before* the identity has been read out of SQLite — measured
  /// at 158ms early on a Pixel 10 Pro. Reading it one-shot there and giving up
  /// on null is what used to strand the permission gate.
  Future<String?> _awaitUserId() async {
    final existing = ref.read(authProvider).userId;
    if (existing != null) return existing;
    final completer = Completer<String?>();
    final sub = ref.listenManual(sessionProvider, (_, next) {
      if (next.userId != null && !completer.isCompleted) {
        completer.complete(next.userId);
      }
    });
    try {
      return await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
    } finally {
      sub.close();
    }
  }

  /// Opens the first-run setup flow when it's due, instead of asking for
  /// permissions straight away:
  ///  * a new user who just answered the welcome screen starts at "Add your
  ///    cards" (or "Cards added" when a restored wallet already has some);
  ///  * anyone never asked for alert permissions who has a card gets the
  ///    alert steps once;
  ///  * an empty wallet is asked nothing: alerts would have no card to name.
  ///    Adding the first card later brings the alert steps up
  ///    ([_offerAlertsAfterFirstCard]).
  ///
  /// `permissionGateCompleteProvider` stays false while the flow is up: the
  /// Stores tab and geofence registration request location through
  /// Geolocator, and overlapping requests null each other's dialogs.
  Future<void> _askPermissionsOnce() async {
    void markGateDone() {
      if (!mounted) return;
      ref.read(permissionGateCompleteProvider.notifier).markComplete();
    }

    // ⛔ Every exit path must call `markGateDone()`. The Stores tab renders a
    // loader until this flips, so any path that returns without it leaves the
    // tab spinning for the whole session — which is exactly what the old
    // `if (userId == null) return;` did whenever identity lost the race.
    final userId = await _awaitUserId();
    if (!mounted || userId == null) {
      markGateDone();
      return;
    }
    final settings = SettingsRepository(ref.read(dataRepositoryProvider));
    final pending =
        ref.read(setupPendingProvider) ||
        await settings.getSetupPending(userId);
    final asked = await settings.getPermissionsAsked(userId);
    final cards = await ref
        .read(cardsProvider.future)
        .catchError((_) => const <CardSummary>[]);
    if (!mounted) {
      markGateDone();
      return;
    }
    if (pending) {
      await _runSetup(
        userId,
        cards.isEmpty ? FlowStep.cards : FlowStep.cardsAdded,
      );
      if (mounted) {
        await ref.read(setupPendingProvider.notifier).set(false);
      } else {
        await settings.setSetupPending(userId, false);
      }
    } else if (!asked && cards.isNotEmpty) {
      await _runSetup(userId, FlowStep.notifications);
    }
    markGateDone();
  }

  bool _setupShowing = false;

  Future<void> _runSetup(String userId, FlowStep start) async {
    if (_setupShowing) return;
    _setupShowing = true;
    ref.read(permissionGateCompleteProvider.notifier).hold();
    try {
      final offered = await Navigator.of(context).push<bool>(
        PageRouteBuilder(
          pageBuilder: (_, _, _) => SetupFlow(start: start),
          transitionsBuilder: (_, anim, _, child) =>
              FadeTransition(opacity: anim, child: child),
        ),
      );
      if (offered ?? false) {
        await SettingsRepository(
          ref.read(dataRepositoryProvider),
        ).setPermissionsAsked(userId);
      }
    } finally {
      _setupShowing = false;
      if (mounted) {
        ref.read(permissionGateCompleteProvider.notifier).markComplete();
      }
    }
  }

  /// The wallet's first card arrived (from the Cards tab, after skipping it in
  /// setup): offer store alerts once, now that an alert has a card to name.
  Future<void> _offerAlertsAfterFirstCard() async {
    final userId = ref.read(authProvider).userId;
    if (userId == null || _setupShowing || !mounted) return;
    final settings = SettingsRepository(ref.read(dataRepositoryProvider));
    if (await settings.getPermissionsAsked(userId)) return;
    // The card lands while Add-a-Card is still on screen: wait until the
    // user is back on Home rather than open over its "Done".
    while (mounted && !(ModalRoute.of(context)?.isCurrent ?? true)) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    if (!mounted || !ref.read(permissionGateCompleteProvider)) return;
    await _runSetup(userId, FlowStep.notifications);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _autoBackup();
    if (state == AppLifecycleState.resumed) {
      _consumePendingMerchant();
      _syncBanksIfDue();
      _recheckAbroad();
      _rescheduleRemindersIfZoneChanged();
    }
  }

  /// Leaving the app is when edits are done, and the wallet only changes while
  /// it is open, so no background job is needed. Uploads only on a change.
  Future<void> _autoBackup() async {
    try {
      final outcome = await ref
          .read(walletBackupControllerProvider)
          .maybeAutoBackup();
      if (outcome != AutoBackupOutcome.off &&
          outcome != AutoBackupOutcome.unchanged) {
        Log.i('backup', 'auto: ${outcome.name}');
      }
    } catch (e) {
      Log.w('backup', 'auto backup failed', e);
    }
  }

  Duration _zoneOffset = DateTime.now().timeZoneOffset;

  /// Reminders are fixed instants computed for 09:00 local, so after a flight
  /// (or a DST switch) they would keep firing at 09:00 back home until the
  /// next cold start. A changed UTC offset on resume rebuilds them now.
  void _rescheduleRemindersIfZoneChanged() {
    final now = DateTime.now().timeZoneOffset;
    if (now == _zoneOffset) return;
    Log.i('reminders', 'time zone $_zoneOffset -> $now, rescheduling');
    _zoneOffset = now;
    _topUpPaymentReminders();
  }

  /// "Abroad" was otherwise decided only at cold start and after a sync, so
  /// crossing a border with the app open kept the home-country ranking.
  /// Refreshes only on a change: invalidating rebuilds every recommendation.
  Future<void> _recheckAbroad() async {
    final auth = ref.read(sessionProvider);
    final before = ref.read(travelIsForeignProvider).value;
    if (!auth.isLoggedIn || before == null) return;
    final now = await travelIsForeignNow(
      ref.read(dataRepositoryProvider),
      auth.userId!,
    );
    if (mounted && now != before) ref.invalidate(travelIsForeignProvider);
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
  /// could have saved a tab this build lacks. Falling through to Advisor keeps the
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
    ref.listen(cardsProvider, (prev, next) {
      final before = prev?.value?.length ?? 0;
      final now = next.value?.length ?? 0;
      if (before == 0 && now > 0 && prev?.hasValue == true) {
        _offerAlertsAfterFirstCard();
      }
    });
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
