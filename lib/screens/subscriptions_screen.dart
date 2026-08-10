import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/insights.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';
import '../util/category_icons.dart';

/// Wireframe `EvRft` - Recurring/subscription charges with a 3-up summary
/// card and per-row "Active" pill.
class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final summaryAsync = ref.watch(recurringPaymentsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.chevronLeft, size: 24),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Recurring Transactions', style: AppText.titleLg()),
      ),
      body: summaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '$e',
              style: AppText.bodySm(color: palette.muted),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (summary) {
          if (summary.items.isEmpty) return const _EmptyState();
          final tips = ref.watch(recurringSwitchTipsProvider).value ?? const {};
          final dismissed = ref.watch(dismissedRecurringTipsProvider);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            children: [
              _SummaryCard(summary: summary),
              const SizedBox(height: 16),
              _SectionHeader(count: summary.items.length),
              const SizedBox(height: 12),
              for (final p in summary.items)
                _SubscriptionRow(
                  payment: p,
                  tip: dismissed.contains(p.id) ? null : tips[p.id],
                  onDismiss: () => ref
                      .read(dismissedRecurringTipsProvider.notifier)
                      .dismiss(p.id),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final RecurringPaymentsSummary summary;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final money = NumberFormat.simpleCurrency(decimalDigits: 0);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: palette.border),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: _Stat(value: '${summary.items.length}', label: 'Active'),
            ),
            _VBar(color: palette.border),
            Expanded(
              child: _Stat(
                value: money.format(summary.monthlyTotal),
                label: 'Monthly',
              ),
            ),
            _VBar(color: palette.border),
            Expanded(
              child: _Stat(
                value: money.format(summary.paidThisMonth),
                label: 'Paid',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: AppText.monoLg().copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label.toUpperCase(), style: AppText.labelSm()),
      ],
    );
  }
}

class _VBar extends StatelessWidget {
  const _VBar({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 36, color: color);
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      children: [
        Text('Active subscriptions', style: AppText.titleMd()),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            color: palette.secondary,
            borderRadius: BorderRadius.circular(kRadiusPill),
          ),
          child: Text(
            '$count',
            style: AppText.monoXs(
              color: palette.muted,
            ).copyWith(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _SubscriptionRow extends StatelessWidget {
  const _SubscriptionRow({
    required this.payment,
    this.tip,
    required this.onDismiss,
  });
  final RecurringPayment payment;
  final RecurringSwitchTip? tip;
  final VoidCallback onDismiss;

  String _frequencyLabel() {
    switch ((payment.frequency ?? '').toUpperCase()) {
      case 'MONTHLY':
        return 'Monthly';
      case 'WEEKLY':
        return 'Weekly';
      case 'DAILY':
        return 'Daily';
      case 'QUARTERLY':
        return 'Quarterly';
      case 'ANNUAL':
      case 'YEARLY':
        return 'Annual';
      default:
        return payment.frequency?.toLowerCase().replaceFirstMapped(
              RegExp(r'^(.)'),
              (m) => m[0]!.toUpperCase(),
            ) ??
            '';
    }
  }

  String _nextLabel() {
    final d = payment.nextPaymentDate;
    if (d == null) return '';
    final now = DateTime.now();
    final diff = d.difference(now).inDays;
    if (diff < 0) return DateFormat('MMM d').format(d);
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return 'Next ${DateFormat('MMM d').format(d)}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final freq = _frequencyLabel();
    final next = _nextLabel();
    final sub = [freq, next].where((s) => s.isNotEmpty).join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
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
              color: palette.secondary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              iconForCategory(payment.category),
              size: 18,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  payment.merchant ?? 'Subscription',
                  style: AppText.titleMd().copyWith(fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(sub, style: AppText.bodySm()),
                ],
                if (tip != null) ...[
                  const SizedBox(height: 6),
                  _SwitchTip(tip: tip!, onDismiss: onDismiss),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (payment.amount != null)
                Text(
                  NumberFormat.simpleCurrency().format(payment.amount),
                  style: AppText.monoMd().copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.greenBg,
                  borderRadius: BorderRadius.circular(kRadiusPill),
                ),
                child: Text(
                  'Active',
                  style: AppText.labelSm(
                    color: palette.green,
                  ).copyWith(fontSize: 10),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact "Switch to `<Card>` (+X%)" nudge shown on a row when a card the
/// user owns out-earns the one the charge is billed to. The ✕ dismisses it.
class _SwitchTip extends StatelessWidget {
  const _SwitchTip({required this.tip, required this.onDismiss});
  final RecurringSwitchTip tip;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 8, top: 2, bottom: 2, right: 2),
      decoration: BoxDecoration(
        color: palette.greenBg,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.arrowLeftRight, size: 12, color: palette.green),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'Switch to ${tip.cardName} (${tip.deltaLabel})',
              style: AppText.labelSm(
                color: palette.green,
              ).copyWith(fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: onDismiss,
            borderRadius: BorderRadius.circular(kRadiusPill),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(LucideIcons.x, size: 12, color: palette.green),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.secondary,
                shape: BoxShape.circle,
              ),
              child: Icon(LucideIcons.searchX, size: 28, color: palette.muted),
            ),
            const SizedBox(height: 16),
            Text('No active subscriptions', style: AppText.titleMd()),
            const SizedBox(height: 6),
            Text(
              'Once we detect repeating charges, the active ones will show up here.',
              textAlign: TextAlign.center,
              style: AppText.bodySm(),
            ),
          ],
        ),
      ),
    );
  }
}
