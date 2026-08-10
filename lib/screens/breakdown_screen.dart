import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../api/types.dart';
import '../providers/bank_sync_provider.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';
import '../util/category_icons.dart';
import 'category_detail_screen.dart';

/// Wireframe `od4zZ` - Spending analytics tab. 2×2 stat grid, Top Merchant
/// tile, fl_chart monthly trend bars, and a tappable "Spending by Category"
/// list. Drives off the existing `breakdownProvider` and `monthlyTrendProvider`.
class BreakdownScreen extends ConsumerStatefulWidget {
  const BreakdownScreen({super.key});

  @override
  ConsumerState<BreakdownScreen> createState() => _BreakdownScreenState();
}

class _BreakdownScreenState extends ConsumerState<BreakdownScreen> {
  List<String> _selectedCardIds = const [];
  // Default range: last + current calendar month, so the breakdown is almost
  // never empty (the current month alone is empty early in the month).
  late DateTime? _startDate = _lastMonthStart();
  late DateTime? _endDate = _currentMonthEnd();
  bool _userPickedRange = false;

  static DateTime _lastMonthStart() {
    final now = DateTime.now();
    final m = now.month - 1;
    final year = m <= 0 ? now.year - 1 : now.year;
    final month = m <= 0 ? m + 12 : m;
    return DateTime(year, month, 1);
  }

  static DateTime _currentMonthEnd() {
    final now = DateTime.now();
    final firstOfNext = (now.month == 12)
        ? DateTime(now.year + 1, 1, 1)
        : DateTime(now.year, now.month + 1, 1);
    return firstOfNext.subtract(const Duration(milliseconds: 1));
  }

  static DateTime _sixMonthsAgoStart() {
    final now = DateTime.now();
    final m = now.month - 5;
    final year = m <= 0 ? now.year - 1 : now.year;
    final month = m <= 0 ? m + 12 : m;
    return DateTime(year, month, 1);
  }

  Future<void> _pickDateRange() async {
    // `lastDate` must not be before the initial range's end. The default
    // `_endDate` is the end of the current month (e.g. May 31 23:59:59.999),
    // which is after `now`, so a `now`-based lastDate would trip
    // showDateRangePicker's assertion and the picker would never open.
    final lastDate = _currentMonthEnd();
    final earliest = await ref.read(earliestTransactionDateProvider.future);
    if (!mounted) return;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: earliest ?? DateTime(2020),
      lastDate: lastDate,
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
    );
    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = DateTime(
          picked.end.year,
          picked.end.month,
          picked.end.day,
          23,
          59,
          59,
          999,
        );
        _userPickedRange = true;
      });
    }
  }

  void _clearRange() {
    setState(() {
      _startDate = _lastMonthStart();
      _endDate = _currentMonthEnd();
      _userPickedRange = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // This tab lives off-screen in the HomeScreen IndexedStack, so it's built
    // once and kept mounted — it has no reason to rebuild on its own. The
    // breakdown/trend/cards providers it reads are invalidated at the end of
    // every sync (see `syncInvalidatedProviders`), but without a sync-coupled
    // dependency this screen never re-runs `build` to pull the recomputed
    // values, so it showed startup data until app relaunch. Watching the sync
    // state (same pattern as the Cards screen) gives it that rebuild trigger;
    // the re-read below then pulls fresh data after an on-sync or add-bank run.
    ref.watch(bankSyncProvider);
    final cardsAsync = ref.watch(cardsProvider);
    final filterArg = (
      cardIds: _selectedCardIds,
      startDate: _startDate,
      endDate: _endDate,
    );
    final trendArg = _userPickedRange
        ? filterArg
        : (
            cardIds: _selectedCardIds,
            startDate: _sixMonthsAgoStart() as DateTime?,
            endDate: _currentMonthEnd() as DateTime?,
          );
    final breakdownAsync = ref.watch(breakdownProvider(filterArg));
    final trendAsync = ref.watch(monthlyTrendProvider(trendArg));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
          children: [
            _Header(
              hasCustomRange: _userPickedRange,
              startDate: _startDate,
              endDate: _endDate,
              onClearRange: _clearRange,
              onPickRange: _pickDateRange,
            ),
            const SizedBox(height: 16),
            cardsAsync.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
              data: (cards) => _CardChipRow(
                cards: cards
                    .map((c) => (id: c.cardId, label: c.name))
                    .toList(growable: false),
                selectedIds: _selectedCardIds,
                onTap: (id) => setState(() {
                  _selectedCardIds = _selectedCardIds.contains(id)
                      ? _selectedCardIds.where((x) => x != id).toList()
                      : [..._selectedCardIds, id];
                }),
                onAll: () => setState(() => _selectedCardIds = const []),
              ),
            ),
            const SizedBox(height: 16),
            breakdownAsync.when(
              loading: () => _BreakdownSkeleton(palette: palette),
              error: (e, _) => _ErrorPanel(error: '$e', palette: palette),
              data: (data) => _BreakdownBody(
                data: data,
                trendAsync: trendAsync,
                startDate: _startDate,
                endDate: _endDate,
                userPickedRange: _userPickedRange,
                palette: palette,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.hasCustomRange,
    required this.startDate,
    required this.endDate,
    required this.onClearRange,
    required this.onPickRange,
  });

  final bool hasCustomRange;
  final DateTime? startDate;
  final DateTime? endDate;
  final VoidCallback onClearRange;
  final VoidCallback onPickRange;

  static final _short = DateFormat('MMM d');

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('Breakdown', style: AppText.displayLg().copyWith(fontSize: 28)),
        Row(
          children: [
            // Always show the active range — the default (last + current
            // month) is itself a filter. Custom ranges get the primary pill +
            // clear "×"; the default gets a muted chip (tap to change).
            GestureDetector(
              onTap: hasCustomRange ? onClearRange : onPickRange,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: hasCustomRange ? AppColors.primary : palette.secondary,
                  borderRadius: BorderRadius.circular(kRadiusPill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      startDate != null && endDate != null
                          ? '${_short.format(startDate!)} – ${_short.format(endDate!)}'
                          : 'All time',
                      style:
                          (hasCustomRange
                                  ? AppText.bodySm(color: AppColors.onPrimary)
                                  : AppText.bodySm())
                              .copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (hasCustomRange) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        LucideIcons.x,
                        size: 12,
                        color: AppColors.onPrimary,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onPickRange,
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.secondary,
                  shape: BoxShape.circle,
                ),
                child: const Icon(LucideIcons.calendarDays, size: 18),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CardChipRow extends StatelessWidget {
  const _CardChipRow({
    required this.cards,
    required this.selectedIds,
    required this.onTap,
    required this.onAll,
  });

  final List<({String id, String label})> cards;
  final List<String> selectedIds;
  final ValueChanged<String> onTap;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _Chip(label: 'All', selected: selectedIds.isEmpty, onTap: onAll),
          for (final c in cards) ...[
            const SizedBox(width: 8),
            _Chip(
              label: c.label,
              selected: selectedIds.contains(c.id),
              onTap: () => onTap(c.id),
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : palette.secondary,
          borderRadius: BorderRadius.circular(kRadiusPill),
        ),
        child: Text(
          label,
          style:
              AppText.bodyMd(
                color: selected ? AppColors.onPrimary : AppColors.foreground,
              ).copyWith(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
        ),
      ),
    );
  }
}

class _BreakdownBody extends StatelessWidget {
  const _BreakdownBody({
    required this.data,
    required this.trendAsync,
    required this.startDate,
    required this.endDate,
    required this.userPickedRange,
    required this.palette,
  });

  final BreakdownSummary data;
  final AsyncValue<List<({String month, double total})>> trendAsync;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool userPickedRange;
  final AppPalette palette;

  static final _short = DateFormat('MMM d');

  @override
  Widget build(BuildContext context) {
    final cf = data.cashFlow;
    final spent = cf.spent;
    final periodDays = startDate != null && endDate != null
        ? (endDate!.difference(startDate!).inDays + 1).clamp(1, 999999)
        : 1;
    final periodLabel = startDate != null && endDate != null
        ? '${_short.format(startDate!)} – ${_short.format(endDate!)}'
        : 'Last 6 months';
    final byCategory = data.byCategory;
    final highest = byCategory.isNotEmpty ? byCategory.first : null;
    final highestPct = highest == null || spent == 0
        ? 0.0
        : (highest.total / spent) * 100;
    final variance = data.periodVariancePct;
    final avgTx = data.avgTransaction;
    final txCount = cf.spentCount;

    // "Avg / Day" = total spend over the selected range divided by its day
    // count. Paired in the UI with a neutral "over N days" sub-line; the
    // period-over-period variance lives on the Total Spending box instead,
    // since it compares totals (over equal-length windows), not daily rates.
    final avgDay = periodDays > 0 ? spent / periodDays : spent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _StatBox(
                label: 'Total Spending',
                value: NumberFormat.simpleCurrency(
                  decimalDigits: 0,
                ).format(spent),
                sub:
                    '${variance >= 0 ? '+' : ''}${variance.toStringAsFixed(1)}% vs prev period',
                subColor: variance >= 0 ? palette.green : palette.red,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatBox(
                label: 'Avg / Day',
                value: NumberFormat.simpleCurrency(
                  decimalDigits: 0,
                ).format(avgDay),
                sub: 'over $periodDays day${periodDays == 1 ? '' : 's'}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatBox(
                label: 'Highest Category',
                value: highest?.category ?? '-',
                sub: '${highestPct.toStringAsFixed(0)}% of total',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatBox(
                label: 'Avg Transaction',
                value: NumberFormat.simpleCurrency(
                  decimalDigits: 2,
                ).format(avgTx),
                sub: '$txCount transactions',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _TopMerchantTile(merchant: data.topMerchant ?? '-'),
        const SizedBox(height: 20),
        // The trend chart plots the last 6 months unless the user picked a
        // custom range — label it with that actual window, not the stat-grid's
        // selected period (which defaults to the current month and otherwise
        // mismatches the multi-month bars).
        _TrendCard(
          trendAsync: trendAsync,
          periodLabel: userPickedRange ? periodLabel : 'Last 6 months',
        ),
        const SizedBox(height: 20),
        _CategoriesCard(
          byCategory: byCategory,
          spent: spent,
          startDate: startDate,
          endDate: endDate,
        ),
      ],
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({
    required this.label,
    required this.value,
    required this.sub,
    this.subColor,
  });

  final String label;
  final String value;
  final String sub;
  final Color? subColor;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: AppText.labelSm()),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppText.monoLg().copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(sub, style: AppText.bodySm(color: subColor ?? palette.muted)),
        ],
      ),
    );
  }
}

class _TopMerchantTile extends StatelessWidget {
  const _TopMerchantTile({required this.merchant});
  final String merchant;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
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
            child: const Icon(LucideIcons.crown, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TOP MERCHANT', style: AppText.labelSm()),
                const SizedBox(height: 2),
                Text(merchant, style: AppText.titleMd()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.trendAsync, required this.periodLabel});

  final AsyncValue<List<({String month, double total})>> trendAsync;
  final String periodLabel;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Monthly Spending Trend', style: AppText.titleMd()),
          const SizedBox(height: 4),
          Text('Per month · $periodLabel', style: AppText.bodySm()),
          const SizedBox(height: 16),
          SizedBox(
            height: 140,
            child: trendAsync.when(
              data: (rows) => _TrendBars(rows: rows),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: Text(
                  'Could not load trend',
                  style: AppText.bodySm(color: palette.muted),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendBars extends StatelessWidget {
  const _TrendBars({required this.rows});
  final List<({String month, double total})> rows;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    if (rows.isEmpty) {
      return Center(
        child: Text(
          'No trend data',
          style: AppText.bodySm(color: palette.muted),
        ),
      );
    }
    final maxV = rows.fold<double>(0, (a, r) => r.total > a ? r.total : a);
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxV == 0 ? 1 : maxV * 1.15,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          show: true,
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= rows.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _abbrevMonth(rows[i].month),
                    style: AppText.monoXs(),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => palette.sheet,
            getTooltipItem: (group, _, rod, _) {
              return BarTooltipItem(
                NumberFormat.simpleCurrency(decimalDigits: 0).format(rod.toY),
                AppText.monoXs(color: AppColors.foreground),
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < rows.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: rows[i].total,
                  color: AppColors.primary,
                  width: 18,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static String _abbrevMonth(String monthIso) {
    final parts = monthIso.split('-');
    if (parts.length < 2) return monthIso;
    final m = int.tryParse(parts[1]);
    if (m == null) return monthIso;
    return DateFormat.MMM().format(DateTime(2000, m));
  }
}

class _CategoriesCard extends StatelessWidget {
  const _CategoriesCard({
    required this.byCategory,
    required this.spent,
    this.startDate,
    this.endDate,
  });

  final List<CategoryBreakdownRow> byCategory;
  final double spent;
  // Carried into the drilldown so it shows the same period the breakdown does.
  final DateTime? startDate;
  final DateTime? endDate;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Spending by Category', style: AppText.titleMd()),
          const SizedBox(height: 4),
          Text('Share of total spend', style: AppText.bodySm()),
          const SizedBox(height: 12),
          if (byCategory.isEmpty)
            Text(
              'No data in this period',
              style: AppText.bodySm(color: palette.muted),
            )
          else
            for (final c in byCategory.take(5)) ...[
              _CategoryRow(
                label: c.category,
                amount: c.total,
                share: spent == 0 ? 0 : c.total / spent,
                startDate: startDate,
                endDate: endDate,
              ),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.label,
    required this.amount,
    required this.share,
    this.startDate,
    this.endDate,
  });

  final String label;
  final double amount;
  final double share;
  final DateTime? startDate;
  final DateTime? endDate;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CategoryDetailScreen(
            category: label,
            startDate: startDate,
            endDate: endDate,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(iconForCategory(label), size: 18, color: palette.muted),
                const SizedBox(width: 10),
                Expanded(child: Text(label, style: AppText.bodyMd())),
                Text(
                  '${NumberFormat.simpleCurrency(decimalDigits: 0).format(amount)} · ${(share * 100).toStringAsFixed(0)}%',
                  style: AppText.monoXs().copyWith(
                    fontSize: 12,
                    color: AppColors.foreground,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: share.clamp(0, 1),
                minHeight: 4,
                backgroundColor: palette.secondary,
                valueColor: const AlwaysStoppedAnimation(AppColors.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownSkeleton extends StatelessWidget {
  const _BreakdownSkeleton({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    Widget box(double h) => Container(
      height: h,
      decoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusS),
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: box(72)),
            const SizedBox(width: 12),
            Expanded(child: box(72)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: box(72)),
            const SizedBox(width: 12),
            Expanded(child: box(72)),
          ],
        ),
        const SizedBox(height: 12),
        box(60),
        const SizedBox(height: 16),
        box(180),
        const SizedBox(height: 16),
        box(220),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.error, required this.palette});
  final String error;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Icon(LucideIcons.wifiOff, size: 40, color: palette.muted),
          const SizedBox(height: 12),
          Text(
            'Could not load breakdown',
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
    );
  }
}
