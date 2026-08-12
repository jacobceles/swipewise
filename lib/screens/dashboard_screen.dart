import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/transaction.dart';
import '../providers/bank_sync_provider.dart';
import '../providers/data_providers.dart';
import '../providers/settings_provider.dart';
import '../providers/sync_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/transaction_row.dart';
import 'merchant_detail_screen.dart';

/// Wireframe `c8MKBm` - Transactions tab. Top bar with search toggle, 4
/// filter chips (All / Cards / Category / Date), centered last-synced pill,
/// pending + posted sections, loading-more footer. Drives off the existing
/// `pagedTransactionsProvider`.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  List<String> _selectedCards = const [];
  List<String> _selectedCategories = const [];
  DateTime? _startDate;
  DateTime? _endDate;
  String _query = '';
  bool _searchOpen = false;
  late final TextEditingController _searchController = TextEditingController();
  late final ScrollController _scrollController = ScrollController()
    ..addListener(_onScroll);

  TxFilter get _filter => TxFilter(
    q: _query,
    cardNames: _selectedCards.isEmpty ? null : _selectedCards,
    categories: _selectedCategories.isEmpty ? null : _selectedCategories,
    startDate: _startDate,
    endDate: _endDate,
  );

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      ref.read(pagedTransactionsProvider(_filter).notifier).loadMore();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _showCardFilter() async {
    final cards = ref.read(cardsProvider).value ?? const [];
    // Honor "Include Debit Accounts" - when off, hide checking/savings
    // names even if they're still in the cards table from a prior sync
    // round before the user flipped the toggle. UI must not lie about
    // what's tracked.
    final includeDebit = ref.read(includeDebitAccountsProvider);
    final visible = includeDebit
        ? cards
        : cards.where((c) => !c.isDepositAccount).toList();
    if (visible.isEmpty) return;
    final names = visible.map((c) => c.name).toSet().toList()..sort();
    await _openMultiSelect(
      title: 'Filter by Cards',
      options: names,
      currentSelection: _selectedCards,
      onApply: (next) => setState(() => _selectedCards = next),
    );
  }

  Future<void> _showCategoryFilter() async {
    final cats = ref.read(categoriesProvider).value ?? const [];
    if (cats.isEmpty) return;
    await _openMultiSelect(
      title: 'Filter by Category',
      options: cats,
      currentSelection: _selectedCategories,
      onApply: (next) => setState(() => _selectedCategories = next),
    );
  }

  Future<void> _showDateFilter() async {
    final earliest = await ref.read(earliestTransactionDateProvider.future);
    if (!mounted) return;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: earliest ?? DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _startDate != null
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
      });
    }
  }

  Future<void> _openMultiSelect({
    required String title,
    required List<String> options,
    required List<String> currentSelection,
    required ValueChanged<List<String>> onApply,
  }) async {
    final palette = AppPalette.of(context);
    var draft = [...currentSelection];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: palette.sheet,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.muted,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: Text(title, style: AppText.titleLg())),
                    TextButton(
                      onPressed: () => setSheet(() => draft = []),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: options.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: palette.border),
                    itemBuilder: (_, i) {
                      final opt = options[i];
                      final selected = draft.contains(opt);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(opt, style: AppText.bodyMd()),
                        trailing: Icon(
                          selected
                              ? LucideIcons.circleCheck
                              : LucideIcons.circle,
                          color: selected ? AppColors.primary : palette.muted,
                        ),
                        onTap: () => setSheet(() {
                          if (selected) {
                            draft.remove(opt);
                          } else {
                            draft.add(opt);
                          }
                        }),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () {
                      onApply(List.unmodifiable(draft));
                      Navigator.pop(ctx);
                    },
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _clearAllFilters() {
    setState(() {
      _selectedCards = const [];
      _selectedCategories = const [];
      _startDate = null;
      _endDate = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // Off-screen in the HomeScreen IndexedStack: built once and kept mounted.
    // pagedTransactionsProvider is invalidated at the end of every sync, but
    // without a sync-coupled dependency this tab doesn't re-run `build` to pull
    // the fresh page. Watching the sync state (same pattern as Cards)
    // gives it that rebuild trigger.
    ref.watch(bankSyncProvider);
    final txAsync = ref.watch(pagedTransactionsProvider(_filter));

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              searchOpen: _searchOpen,
              onToggleSearch: () => setState(() {
                _searchOpen = !_searchOpen;
                if (!_searchOpen) {
                  _query = '';
                  _searchController.clear();
                }
              }),
            ),
            if (_searchOpen)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (v) => setState(() => _query = v),
                  style: AppText.bodyMd(),
                  decoration: InputDecoration(
                    hintText: 'Search merchant, category, card…',
                    prefixIcon: Icon(
                      LucideIcons.search,
                      size: 18,
                      color: palette.muted,
                    ),
                    isDense: true,
                  ),
                ),
              ),
            _FilterChipRow(
              cards: _selectedCards,
              categories: _selectedCategories,
              startDate: _startDate,
              endDate: _endDate,
              onAll: _clearAllFilters,
              onCards: _showCardFilter,
              onCategory: _showCategoryFilter,
              onDate: _showDateFilter,
            ),
            const _SyncPill(),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => ref.read(syncProvider.notifier).runSync(),
                child: txAsync.when(
                  data: (data) => _buildList(data, palette),
                  loading: () => const _LoadingList(),
                  error: (e, _) => _ErrorList(error: '$e'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(PagedTxState data, AppPalette palette) {
    if (data.items.isEmpty) {
      return ListView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.receipt,
                    size: 48,
                    color: palette.muted.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No transactions yet',
                    style: AppText.bodyMd(color: palette.muted),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final pending = data.items.where((t) => t.isPending).toList();
    final posted = data.items.where((t) => !t.isPending).toList();
    final showFooter = data.hasMore || data.loadingMore;

    final slots = <_Slot>[
      if (pending.isNotEmpty) ...[
        _Slot.header('Pending'),
        for (final t in pending)
          _Slot.row(
            t,
            pendingStyle: true,
            startDate: _startDate,
            endDate: _endDate,
          ),
        _Slot.header('Posted'),
      ],
      for (final t in posted)
        _Slot.row(t, startDate: _startDate, endDate: _endDate),
      if (showFooter) _Slot.footer(data.loadingMore),
    ];

    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: slots.length,
      itemBuilder: (_, i) => slots[i].build(context),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.searchOpen, required this.onToggleSearch});

  final bool searchOpen;
  final VoidCallback onToggleSearch;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Transactions',
            style: AppText.displayLg().copyWith(fontSize: 28),
          ),
          GestureDetector(
            onTap: onToggleSearch,
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: searchOpen ? AppColors.primary : palette.secondary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                searchOpen ? LucideIcons.x : LucideIcons.search,
                size: 18,
                color: searchOpen ? AppColors.onPrimary : AppColors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChipRow extends StatelessWidget {
  const _FilterChipRow({
    required this.cards,
    required this.categories,
    required this.startDate,
    required this.endDate,
    required this.onAll,
    required this.onCards,
    required this.onCategory,
    required this.onDate,
  });

  final List<String> cards;
  final List<String> categories;
  final DateTime? startDate;
  final DateTime? endDate;
  final VoidCallback onAll;
  final VoidCallback onCards;
  final VoidCallback onCategory;
  final VoidCallback onDate;

  @override
  Widget build(BuildContext context) {
    final anyActive =
        cards.isNotEmpty || categories.isNotEmpty || startDate != null;
    final cardsLabel = cards.isEmpty
        ? 'Cards'
        : (cards.length == 1 ? cards.first : 'Cards · ${cards.length}');
    final categoryLabel = categories.isEmpty
        ? 'Category'
        : (categories.length == 1
              ? categories.first
              : 'Category · ${categories.length}');
    final dateLabel = startDate == null
        ? 'Date'
        : '${DateFormat('MMM d').format(startDate!)} – ${DateFormat('MMM d').format(endDate!)}';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: _Chip(label: 'All', selected: !anyActive, onTap: onAll),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _Chip(
              label: cardsLabel,
              selected: cards.isNotEmpty,
              onTap: onCards,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _Chip(
              label: categoryLabel,
              selected: categories.isNotEmpty,
              onTap: onCategory,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _Chip(
              label: dateLabel,
              selected: startDate != null,
              onTap: onDate,
            ),
          ),
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
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : palette.secondary,
          borderRadius: BorderRadius.circular(kRadiusPill),
        ),
        child: Text(
          label,
          style: AppText.bodyMd(
            color: selected ? AppColors.onPrimary : AppColors.foreground,
          ).copyWith(fontSize: 13, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _SyncPill extends ConsumerWidget {
  const _SyncPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final dt = ref.watch(lastSyncProvider).value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: palette.secondary,
            borderRadius: BorderRadius.circular(kRadiusPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: palette.green,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                dt == null
                    ? 'Not synced yet'
                    : 'last synced ${_relative(dt.toLocal())}',
                style: AppText.bodySm(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _relative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('MMM d').format(dt);
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: List.generate(
        8,
        (_) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: const _SkeletonRow(),
        ),
      ),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusXs),
      ),
    );
    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: palette.secondary,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [bar(140, 12), const SizedBox(height: 8), bar(80, 10)],
          ),
        ),
        bar(60, 14),
      ],
    );
  }
}

class _ErrorList extends StatelessWidget {
  const _ErrorList({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.5,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.wifiOff,
                    size: 48,
                    color: palette.muted.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Could not load transactions',
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
          ),
        ),
      ],
    );
  }
}

class _Slot {
  final String? header;
  final Transaction? tx;
  final bool pending;
  final bool isFooter;
  final bool footerLoading;

  /// Active list date range, forwarded to the merchant drilldown so it
  /// reflects the same window. Only meaningful for row slots.
  final DateTime? startDate;
  final DateTime? endDate;

  const _Slot.header(this.header)
    : tx = null,
      pending = false,
      isFooter = false,
      footerLoading = false,
      startDate = null,
      endDate = null;

  const _Slot.row(
    this.tx, {
    bool pendingStyle = false,
    this.startDate,
    this.endDate,
  }) : header = null,
       pending = pendingStyle,
       isFooter = false,
       footerLoading = false;

  const _Slot.footer(bool loading)
    : header = null,
      tx = null,
      pending = false,
      isFooter = true,
      footerLoading = loading,
      startDate = null,
      endDate = null;

  Widget build(BuildContext context) {
    if (isFooter) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: footerLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const SizedBox.shrink(),
        ),
      );
    }
    if (header != null) {
      final palette = AppPalette.of(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(0, header == 'Posted' ? 16 : 8, 0, 4),
        child: Text(
          header!.toUpperCase(),
          style: AppText.labelSm(color: palette.muted),
        ),
      );
    }
    final t = tx!;
    return Opacity(
      opacity: pending ? 0.55 : 1.0,
      child: TransactionRow(
        tx: t,
        onTap: t.merchant == null && t.name == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MerchantDetailScreen(
                    merchant: t.merchant ?? t.name!,
                    category: t.category,
                    startDate: startDate,
                    endDate: endDate,
                  ),
                ),
              ),
      ),
    );
  }
}
