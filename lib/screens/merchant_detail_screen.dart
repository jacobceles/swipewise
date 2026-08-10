import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/stat_tile.dart';

/// Wireframe `Ldeoe` - One merchant's spending history. 3 stat tiles, then
/// a bordered list of date / card / amount rows.
class MerchantDetailScreen extends ConsumerWidget {
  const MerchantDetailScreen({
    super.key,
    required this.merchant,
    this.category,
    this.startDate,
    this.endDate,
  });
  final String merchant;

  /// Bank/canonical category label (e.g. "Dining"), shown beside the title.
  final String? category;

  /// Active transactions-list date range, threaded through so the drilldown
  /// reflects what the user was viewing. Null = all-time (default list view).
  final DateTime? startDate;
  final DateTime? endDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final summaryAsync = ref.watch(
      merchantSummaryProvider((
        merchant: merchant,
        startDate: startDate,
        endDate: endDate,
      )),
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.chevronLeft, size: 24),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                merchant,
                style: AppText.titleLg(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (category != null && category!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                category!,
                style: AppText.bodySm().copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: palette.muted,
                ),
              ),
            ],
          ],
        ),
      ),
      body: summaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBody(error: '$e', palette: palette),
        data: (summary) {
          if (summary == null) {
            return _EmptyBody(palette: palette);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: StatTile(
                      label: 'Total Spent',
                      value: NumberFormat.simpleCurrency(
                        decimalDigits: 0,
                      ).format(summary.totalSpent),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: 'Visits',
                      value: '${summary.visitCount}',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: 'Avg Visit',
                      value: NumberFormat.simpleCurrency(
                        decimalDigits: 0,
                      ).format(summary.avgPerVisit),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text('HISTORY', style: AppText.labelSm()),
              const SizedBox(height: 12),
              _HistoryList(
                merchant: summary.merchant,
                startDate: startDate,
                endDate: endDate,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HistoryList extends ConsumerWidget {
  const _HistoryList({required this.merchant, this.startDate, this.endDate});
  final String merchant;
  final DateTime? startDate;
  final DateTime? endDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    // Exact-merchant + the active date range: the query already returns only
    // this merchant's rows (no client-side filtering needed), scoped to the
    // same window the list was showing.
    final txAsync = ref.watch(
      pagedTransactionsProvider(
        TxFilter(
          merchantExact: merchant,
          startDate: startDate,
          endDate: endDate,
        ),
      ),
    );
    return txAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text('$e', style: AppText.bodySm(color: palette.muted)),
      data: (data) {
        final rows = data.items;
        if (rows.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(kRadiusM),
              border: Border.all(color: palette.border),
            ),
            child: Text(
              'No history.',
              style: AppText.bodySm(color: palette.muted),
              textAlign: TextAlign.center,
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(kRadiusM),
            border: Border.all(color: palette.border),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                _HistoryRow(tx: rows[i]),
                if (i < rows.length - 1)
                  Divider(height: 1, color: palette.border),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.tx});
  final dynamic tx;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final isCredit = tx.type == 'CREDIT';
    final dt = tx.postedAt != null ? DateTime.tryParse(tx.postedAt!) : null;
    final dateStr = dt == null ? '' : DateFormat('MMM d, y').format(dt);
    final sign = isCredit ? '+' : '-';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dateStr, style: AppText.bodyMd()),
                if (tx.card != null) ...[
                  const SizedBox(height: 2),
                  Text(tx.card!, style: AppText.bodySm()),
                ],
              ],
            ),
          ),
          Text(
            '$sign${NumberFormat.simpleCurrency().format(tx.amount?.abs() ?? 0)}',
            style: AppText.monoMd(
              color: isCredit ? palette.green : AppColors.foreground,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.store, size: 48, color: palette.muted),
          const SizedBox(height: 12),
          Text(
            'No data for this merchant',
            style: AppText.bodyMd(color: palette.muted),
          ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.error, required this.palette});
  final String error;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.wifiOff, size: 40, color: palette.muted),
            const SizedBox(height: 12),
            Text(
              'Could not load merchant',
              style: AppText.bodyMd(color: palette.muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              error,
              style: AppText.bodySm(color: palette.muted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
