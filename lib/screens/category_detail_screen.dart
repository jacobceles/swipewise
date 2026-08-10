import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/stat_tile.dart';
import '../widgets/transaction_row.dart';

/// Wireframe `LpgSY` - Spending drilldown for one category. 3 stat tiles +
/// "HISTORY" caption + bordered list of `TransactionRow`s.
class CategoryDetailScreen extends ConsumerWidget {
  const CategoryDetailScreen({
    super.key,
    required this.category,
    this.startDate,
    this.endDate,
  });

  final String category;
  final DateTime? startDate;
  final DateTime? endDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final summaryAsync = ref.watch(
      categoryDrilldownProvider((
        category: category,
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
        title: Text(category, style: AppText.titleLg()),
      ),
      body: summaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBody(error: '$e', palette: palette),
        data: (summary) {
          final spent = summary.totalSpent;
          final txCount = summary.txCount;
          final share = summary.shareOfTotal;
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
                      ).format(spent),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: '% of Total',
                      value: '${(share * 100).toStringAsFixed(0)}%',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(label: 'Transactions', value: '$txCount'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Text('HISTORY', style: AppText.labelSm()),
              const SizedBox(height: 12),
              _HistoryList(
                category: category,
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

class _HistoryList extends ConsumerStatefulWidget {
  const _HistoryList({required this.category, this.startDate, this.endDate});

  final String category;
  final DateTime? startDate;
  final DateTime? endDate;

  @override
  ConsumerState<_HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends ConsumerState<_HistoryList> {
  // Filter is cached to avoid an inline rebuild creating a fresh value
  // each frame. `TxFilter` now has element-equal `==` so even a fresh
  // instance with the same inputs would resolve to the same provider —
  // caching is belt-and-suspenders.
  late final TxFilter _filter = TxFilter(
    q: '',
    categories: [widget.category],
    startDate: widget.startDate,
    endDate: widget.endDate,
    // Breakdown is a spend view — show only debits so the list matches the
    // spend-only category total above it (no credit-card payments/refunds).
    spendOnly: true,
  );

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final txAsync = ref.watch(pagedTransactionsProvider(_filter));
    return txAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('$e', style: AppText.bodySm(color: palette.muted)),
      ),
      data: (data) {
        if (data.items.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(kRadiusM),
              border: Border.all(color: palette.border),
            ),
            child: Text(
              'No transactions in this category for the selected period',
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
              for (var i = 0; i < data.items.length; i++) ...[
                TransactionRow(tx: data.items[i]),
                if (i < data.items.length - 1)
                  Divider(height: 1, color: palette.border, indent: 52),
              ],
            ],
          ),
        );
      },
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
              'Could not load category',
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
