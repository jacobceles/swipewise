import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../providers/bank_sync_provider.dart';
import '../sync/sync_progress_event.dart';
import '../theme/app_theme.dart';

/// Sticky sync-progress banner that lives at the top of the Cards screen
/// body. Only renders during an *incremental* sync — when the user
/// already has banks linked and a refresh / add-bank-triggered sync is
/// running. The first-sync flow uses [FirstSyncBody] instead because it
/// owns the whole screen.
///
/// Three visible states, transitioned by the `bankSyncProvider`:
///
///   1. **Hidden** — no active sync.
///   2. **Syncing** — "Syncing X of Y banks…" + thin determinate progress
///      bar + chevron. Expand to see a per-bank list (✓ synced /
///      ⟳ in-flight / ✗ failed).
///   3. **Done flash** — "All synced" briefly (2s), then slides out.
///
/// Animation: `AnimatedSize` slides the banner in/out as a whole, and
/// `AnimatedSwitcher` cross-fades the syncing/done state inside it.
class BankSyncProgressBanner extends ConsumerStatefulWidget {
  const BankSyncProgressBanner({super.key});

  @override
  ConsumerState<BankSyncProgressBanner> createState() =>
      _BankSyncProgressBannerState();
}

class _BankSyncProgressBannerState
    extends ConsumerState<BankSyncProgressBanner> {
  bool _expanded = false;

  /// True while we're showing the brief post-sync "All synced" flash.
  /// Decoupled from the provider state so the banner can linger for the
  /// 2-second confirmation window after `SyncCompleted` arrives.
  bool _doneFlashing = false;
  Timer? _doneTimer;

  /// Snapshot of the last `SyncCompleted` payload we surfaced as the
  /// "done flash." Prevents firing the flash twice for the same run if
  /// the widget rebuilds.
  Object? _lastCompletedRunIdentity;

  @override
  void dispose() {
    _doneTimer?.cancel();
    super.dispose();
  }

  void _maybeStartDoneFlash(BankSyncState s) {
    final lp = s.lastProgress;
    if (lp is! SyncCompleted) return;
    // De-dup against repeated rebuilds for the same finished run.
    final identity = identityHashCode(lp);
    if (_lastCompletedRunIdentity == identity) return;
    _lastCompletedRunIdentity = identity;
    setState(() => _doneFlashing = true);
    _doneTimer?.cancel();
    _doneTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _doneFlashing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final asyncSync = ref.watch(bankSyncProvider);
    final syncState = asyncSync.hasValue
        ? asyncSync.value!
        : const BankSyncState();

    // Side effect: when `SyncCompleted` lands, start the 2-second
    // "All synced" flash. Wrapped in `addPostFrameCallback` so we
    // don't call setState during build.
    if (syncState.lastProgress is SyncCompleted && !_doneFlashing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeStartDoneFlash(syncState);
      });
    }

    // A sync that threw (Customer/Members resolution failed, etc.) lands as
    // AsyncValue.error. Surface it as a persistent failed row with Retry —
    // without this the banner falls back to an empty state and silently hides,
    // so a failed resync shows the user nothing at all. The error clears on
    // the next runSync (it flips to loading before its first await).
    final showError = asyncSync.hasError && !_doneFlashing;
    final showSyncingBanner = syncState.isPerMemberSyncing;
    final showAnything = showSyncingBanner || _doneFlashing || showError;

    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: !showAnything
          ? const SizedBox(width: double.infinity, height: 0)
          : Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.card,
                border: Border(
                  bottom: BorderSide(color: palette.border, width: 1),
                ),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: showError
                    ? _FailedRow(
                        key: const ValueKey('failed'),
                        palette: palette,
                        onRetry: () =>
                            ref.read(bankSyncProvider.notifier).runSync(),
                      )
                    : _doneFlashing
                    ? _DoneRow(key: const ValueKey('done'), palette: palette)
                    : _SyncingBlock(
                        key: const ValueKey('syncing'),
                        syncState: syncState,
                        expanded: _expanded,
                        onToggle: () => setState(() => _expanded = !_expanded),
                        palette: palette,
                      ),
              ),
            ),
    );
  }
}

class _SyncingBlock extends StatelessWidget {
  const _SyncingBlock({
    super.key,
    required this.syncState,
    required this.expanded,
    required this.onToggle,
    required this.palette,
  });

  final BankSyncState syncState;
  final bool expanded;
  final VoidCallback onToggle;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final completed = syncState.bankStatuses.length;
    final total = syncState.memberCount ?? completed;
    final progress = total == 0 ? 0.0 : (completed / total).clamp(0.0, 1.0);

    final inFlightBank = _inFlightBankInfo(syncState);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(AppColors.primary),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Syncing $completed of $total banks…',
                    style: AppText.bodyMd().copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                  size: 18,
                  color: palette.muted,
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: palette.secondary,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: !expanded
              ? const SizedBox(width: double.infinity, height: 0)
              : _ExpandedList(
                  syncState: syncState,
                  inFlightBank: inFlightBank,
                  palette: palette,
                ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  /// Pulls the (memberId, bankName) pair out of the latest non-terminal
  /// per-member progress event, used to surface the bank that's
  /// currently mid-flight in the expanded list.
  ({String memberId, String bankName, String stage})? _inFlightBankInfo(
    BankSyncState s,
  ) {
    final lp = s.lastProgress;
    return switch (lp) {
      MemberStarted(:final memberId, :final bankName) => (
        memberId: memberId,
        bankName: bankName,
        stage: 'Starting…',
      ),
      MemberAccountsLoaded(
        :final memberId,
        :final bankName,
        :final accountCount,
      ) =>
        (
          memberId: memberId,
          bankName: bankName,
          stage:
              'Loading $accountCount account${accountCount == 1 ? '' : 's'}…',
        ),
      MemberTransactionsLoaded(
        :final memberId,
        :final bankName,
        :final txCount,
      ) =>
        (
          memberId: memberId,
          bankName: bankName,
          stage: 'Loading transactions ($txCount so far)…',
        ),
      _ => null,
    };
  }
}

class _ExpandedList extends StatelessWidget {
  const _ExpandedList({
    required this.syncState,
    required this.inFlightBank,
    required this.palette,
  });

  final BankSyncState syncState;
  final ({String memberId, String bankName, String stage})? inFlightBank;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    final completed = syncState.bankStatuses;
    completed.forEach((memberId, evt) {
      rows.add(
        _StatusRow(
          icon: evt.success ? LucideIcons.circleCheck : LucideIcons.circleAlert,
          color: evt.success ? palette.green : palette.red,
          primary: evt.bankName,
          secondary: evt.success ? null : (evt.error ?? 'Failed'),
          palette: palette,
        ),
      );
    });
    final inFlight = inFlightBank;
    if (inFlight != null && !completed.containsKey(inFlight.memberId)) {
      rows.add(
        _StatusRow(
          icon: null,
          color: AppColors.primary,
          primary: inFlight.bankName,
          secondary: inFlight.stage,
          palette: palette,
        ),
      );
    }
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: palette.border),
          const SizedBox(height: 8),
          for (final r in rows) r,
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.color,
    required this.primary,
    required this.secondary,
    required this.palette,
  });

  /// Icon to show on the left; null renders a small spinner instead
  /// (used for the in-flight row).
  final IconData? icon;
  final Color color;
  final String primary;
  final String? secondary;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: icon == null
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(color),
                  )
                : Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  primary,
                  style: AppText.bodyMd(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (secondary != null)
                  Text(
                    secondary!,
                    style: AppText.bodySm(color: palette.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow({super.key, required this.palette});

  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(LucideIcons.circleCheck, size: 18, color: palette.green),
          const SizedBox(width: 12),
          Text(
            'All banks synced',
            style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _FailedRow extends StatelessWidget {
  const _FailedRow({super.key, required this.palette, required this.onRetry});

  final AppPalette palette;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(LucideIcons.circleAlert, size: 18, color: palette.red),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "Sync didn't finish",
              style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
