import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../providers/bank_sync_provider.dart';
import '../sync/sync_progress_event.dart';
import '../theme/app_theme.dart';

/// Shown on the Cards screen when the user just linked their first bank
/// and the data sync is running in the background while the local DB is
/// still empty. Replaces the misleading "No banks linked yet" empty state.
///
/// Real per-bank progress is driven by the `SyncProgressEvent` stream
/// from the bankSyncProvider. A short rotating tip carousel + a soft
/// "feel free to minimize" caption (paired with the link-progress
/// notification so the user has a path back if they walk away) make the
/// wait feel intentional, not stuck.
class FirstSyncBody extends ConsumerStatefulWidget {
  const FirstSyncBody({super.key});

  @override
  ConsumerState<FirstSyncBody> createState() => _FirstSyncBodyState();
}

class _FirstSyncBodyState extends ConsumerState<FirstSyncBody> {
  // Tip list - mix of educational ("what does this do?") and action
  // ("try this") so users learn the app while they wait. Add or reorder
  // here; the carousel timer + paging logic doesn't depend on count.
  static const _tips = <String>[
    'Tap any card to see its full rewards by category',
    'Try pulling down to refresh your cards anytime',
    'Use the Advisor tab to find the best card at nearby stores',
    'Set quarterly bonus categories from the cards screen',
    'Swipe through your transactions to break them down by merchant',
  ];

  late final Timer _tipTimer;
  int _tipIndex = 0;

  @override
  void initState() {
    super.initState();
    _tipTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() => _tipIndex = (_tipIndex + 1) % _tips.length);
    });
  }

  @override
  void dispose() {
    _tipTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final syncState = ref.watch(bankSyncProvider);
    final value = syncState.hasValue ? syncState.value! : null;
    final lastProgress = value?.lastProgress;
    final bankStatuses = value?.bankStatuses ?? const {};

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ProgressSection(
                  lastProgress: lastProgress,
                  bankStatuses: bankStatuses,
                  palette: palette,
                ),
                const SizedBox(height: 24),
                _TipCard(
                  text: _tips[_tipIndex],
                  total: _tips.length,
                  activeIndex: _tipIndex,
                  palette: palette,
                ),
              ],
            ),
          ),
          Text(
            "Feel free to minimize - we'll notify you when it's ready. "
            'Usually under a minute.',
            style: AppText.bodySm(color: palette.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ProgressSection extends StatelessWidget {
  const _ProgressSection({
    required this.lastProgress,
    required this.bankStatuses,
    required this.palette,
  });

  final SyncProgressEvent? lastProgress;
  final Map<String, MemberCompleted> bankStatuses;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    // Build a step list: customer/members fetched, then one row per
    // member started (with success/failure check or active spinner).
    final steps = <_Step>[];

    // Initial steps - only appear before the first MemberStarted, since
    // once members are flowing the bank-level rows convey the same info.
    if (lastProgress is SyncStarted ||
        lastProgress is CustomerResolved ||
        lastProgress is MembersListed) {
      steps.add(
        _Step(
          label: lastProgress is SyncStarted
              ? 'Starting…'
              : lastProgress is CustomerResolved
              ? 'Connected to your account'
              : 'Found ${(lastProgress as MembersListed).count} bank(s)',
          state: _StepState.active,
        ),
      );
    }

    // One row per bank we've seen progress for. `bankStatuses` only
    // contains completed banks; in-flight banks are inferred from the
    // current event when it's a Member* event.
    final activeMemberId = switch (lastProgress) {
      MemberStarted(:final memberId) => memberId,
      MemberAccountsLoaded(:final memberId) => memberId,
      MemberTransactionsLoaded(:final memberId) => memberId,
      _ => null,
    };
    final activeBankName = switch (lastProgress) {
      MemberStarted(:final bankName) => bankName,
      MemberAccountsLoaded(:final bankName) => bankName,
      MemberTransactionsLoaded(:final bankName) => bankName,
      _ => null,
    };

    bankStatuses.forEach((memberId, completed) {
      steps.add(
        _Step(
          label: completed.success
              ? 'Loaded ${completed.bankName}'
              : "Couldn't load ${completed.bankName}",
          state: completed.success ? _StepState.done : _StepState.failed,
        ),
      );
    });

    if (activeMemberId != null && !bankStatuses.containsKey(activeMemberId)) {
      final label = switch (lastProgress) {
        MemberAccountsLoaded(:final accountCount) =>
          'Loading $activeBankName ($accountCount account${accountCount == 1 ? '' : 's'})…',
        MemberTransactionsLoaded(:final txCount) =>
          'Loading $activeBankName transactions ($txCount so far)…',
        _ => 'Loading $activeBankName…',
      };
      steps.add(_Step(label: label, state: _StepState.active));
    }

    if (steps.isEmpty) {
      steps.add(
        const _Step(
          label: 'Setting up your accounts…',
          state: _StepState.active,
        ),
      );
    }

    // Progress bar: rough fraction = (done + failed) / (done + failed + active).
    final done = steps.where((s) => s.state != _StepState.active).length;
    final total = steps.length.clamp(1, 1000);
    final progress = done / total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Setting up your accounts…',
          style: AppText.titleMd().copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            backgroundColor: palette.secondary,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
          ),
        ),
        const SizedBox(height: 16),
        for (final step in steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _StepRow(step: step, palette: palette),
          ),
      ],
    );
  }
}

enum _StepState { active, done, failed }

class _Step {
  const _Step({required this.label, required this.state});
  final String label;
  final _StepState state;
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.palette});
  final _Step step;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (step.state) {
      _StepState.done => (LucideIcons.circleCheck, palette.green),
      _StepState.failed => (LucideIcons.circleAlert, palette.red),
      _StepState.active => (LucideIcons.loader, AppColors.primary),
    };
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            step.label,
            style: AppText.bodyMd(
              color: step.state == _StepState.active
                  ? AppColors.foreground
                  : AppColors.foreground,
            ),
          ),
        ),
      ],
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard({
    required this.text,
    required this.total,
    required this.activeIndex,
    required this.palette,
  });
  final String text;
  final int total;
  final int activeIndex;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'TIP',
            style: AppText.labelSm(
              color: AppColors.primary,
            ).copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5),
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(text, key: ValueKey(text), style: AppText.bodyMd()),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < total; i++) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == activeIndex ? AppColors.primary : palette.muted,
                    shape: BoxShape.circle,
                  ),
                ),
                if (i < total - 1) const SizedBox(width: 6),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
