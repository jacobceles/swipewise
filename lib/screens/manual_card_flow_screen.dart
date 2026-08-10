import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/card_repository.dart';
import '../api/catalog_repository.dart';
import '../api/reward_engine.dart';
import '../providers/auth_provider.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/connect_bank_app_bar.dart';

/// Products the user already holds — a `card_links` row for the product,
/// from any source (a heuristically-matched bank card or a prior manual
/// add). Pre-checked and locked in [_SelectCards] so the user can see what
/// they already have without being able to re-add (and duplicate) it.
typedef _ProductCatalog = ({List<CardProduct> products, Set<String> owned});

/// Wireframe `QqeiU` / `jvNhY` / `srsqJ`. Catalog-backed card flow: pick
/// products, fill in optional details, add them to the wallet.
///
/// Reached two ways, which is why it takes plain strings rather than the
/// institution map it used to. The Pro build enters from the add-bank picker
/// (a Sophtron institution); the free build enters from the standalone wallet
/// flow (a catalog issuer). Nothing here touches a bank either way.
class ManualCardFlowScreen extends ConsumerStatefulWidget {
  const ManualCardFlowScreen({
    super.key,
    required this.issuerQuery,
    required this.displayName,
    required this.addAnotherLabel,
    this.appBarTitle,
    this.logoUrl,
  });

  /// Matched against `card_products.issuer` with punctuation and case
  /// stripped, so both a bank name ("Bank of America") and the catalog's own
  /// squashed slug ("Bankofamerica") resolve to the same products.
  final String issuerQuery;

  /// Header text. Separate from [issuerQuery] because the catalog's issuer
  /// values are join keys, not labels — "Amex" has to display as "American
  /// Express" while still matching on "amex".
  final String displayName;

  /// Label for the secondary action on the result screen, which pops one
  /// level back to whichever picker sent the user here.
  final String addAnotherLabel;

  /// Fixed app-bar title. Null keeps the bank flow's older behaviour of
  /// naming the current step; the wallet flow passes a constant instead and
  /// leaves per-step context to the header block.
  final String? appBarTitle;

  final String? logoUrl;

  @override
  ConsumerState<ManualCardFlowScreen> createState() =>
      _ManualCardFlowScreenState();
}

enum _ManualStep { select, details, result }

class _ManualCardFlowScreenState extends ConsumerState<ManualCardFlowScreen> {
  _ManualStep _step = _ManualStep.select;
  late final Future<_ProductCatalog> _catalog;
  final Set<String> _selected = {};
  final Map<String, _CardDetails> _details = {};
  List<_AddOutcome> _outcomes = const [];

  @override
  void initState() {
    super.initState();
    _catalog = _loadCatalog();
  }

  Future<_ProductCatalog> _loadCatalog() async {
    final repo = ref.read(dataRepositoryProvider);
    final all = await repo.catalog.productsForIssuer(null);
    final bank = _normalized(widget.issuerQuery);
    final matches = all.where((product) {
      final issuer = _normalized(product.issuer);
      return issuer == bank || issuer.contains(bank) || bank.contains(issuer);
    }).toList();
    matches.sort((a, b) => a.displayName.compareTo(b.displayName));

    final userId = ref.read(authProvider).userId;
    final owned = userId == null
        ? <String>{}
        : (await repo.catalog.linkedCards(
            userId,
          )).map((l) => l.cardProductId).toSet();
    return (products: matches, owned: owned);
  }

  String _normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  void _showDetails(List<CardProduct> products) {
    if (_selected.isEmpty) return;
    for (final product in products.where((p) => _selected.contains(p.id))) {
      _details.putIfAbsent(product.id, _CardDetails.new);
    }
    setState(() => _step = _ManualStep.details);
  }

  Future<void> _addCards(List<CardProduct> products) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    final outcomes = <_AddOutcome>[];
    for (final product in products.where((p) => _selected.contains(p.id))) {
      final detail = _details[product.id]!;
      final result = await ref
          .read(dataRepositoryProvider)
          .addManualCard(
            userId: userId,
            productId: product.id,
            issuer: product.issuer,
            name: product.displayName,
            network: product.network,
            imageUrl: product.imageUrl,
            lastFour: detail.lastFour,
            creditLimit: detail.creditLimit,
            dueDay: detail.dueDay,
            institutionLogo: widget.logoUrl,
          );
      outcomes.add(_AddOutcome(product, result));
    }
    ref.invalidate(cardsProvider);
    if (mounted) {
      setState(() {
        _outcomes = outcomes;
        _step = _ManualStep.result;
      });
    }
  }

  @override
  void dispose() {
    for (final detail in _details.values) {
      detail.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title =
        widget.appBarTitle ??
        switch (_step) {
          _ManualStep.select => 'Select cards',
          _ManualStep.details => 'Card details',
          _ManualStep.result => 'Cards added',
        };
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: ConnectBankAppBar(
        title: title,
        onBack: _step == _ManualStep.select
            ? null
            : () => setState(() => _step = _ManualStep.select),
        onClose: () => Navigator.of(context).pop(),
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<_ProductCatalog>(
          future: _catalog,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _LoadFailure(error: '${snapshot.error}');
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final products = snapshot.data!.products;
            final owned = snapshot.data!.owned;
            return switch (_step) {
              _ManualStep.select => _SelectCards(
                issuerName: widget.displayName,
                logoUrl: widget.logoUrl,
                products: products,
                owned: owned,
                selected: _selected,
                onChanged: (id, selected) => setState(() {
                  selected ? _selected.add(id) : _selected.remove(id);
                }),
                onContinue: () => _showDetails(products),
              ),
              _ManualStep.details => _CardDetailsForm(
                issuerName: widget.displayName,
                logoUrl: widget.logoUrl,
                products: products
                    .where((p) => _selected.contains(p.id))
                    .toList(),
                details: _details,
                onAdd: () => _addCards(products),
              ),
              _ManualStep.result => _ResultView(
                outcomes: _outcomes,
                addAnotherLabel: widget.addAnotherLabel,
                // Done means "I'm finished adding cards" — pop past both this
                // screen AND the picker underneath it, landing back on the
                // Cards page instead of stranding the user mid-flow. Both
                // entry points have that same two-deep shape (Cards → picker →
                // here). "Add another" pops one level, back to the picker.
                onDone: () => Navigator.of(context)
                  ..pop()
                  ..pop(),
                onAddAnother: () => Navigator.of(context).pop(),
              ),
            };
          },
        ),
      ),
    );
  }
}

class _SelectCards extends StatefulWidget {
  const _SelectCards({
    required this.issuerName,
    required this.logoUrl,
    required this.products,
    required this.owned,
    required this.selected,
    required this.onChanged,
    required this.onContinue,
  });
  final String issuerName;
  final String? logoUrl;
  final List<CardProduct> products;
  // card_product_ids already in the wallet (bank-linked or manually added
  // earlier). Shown pre-checked and locked so the user can't add a
  // duplicate.
  final Set<String> owned;
  final Set<String> selected;
  final void Function(String, bool) onChanged;
  final VoidCallback onContinue;

  @override
  State<_SelectCards> createState() => _SelectCardsState();
}

class _SelectCardsState extends State<_SelectCards> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? widget.products
        : widget.products
              .where((p) => p.displayName.toLowerCase().contains(q))
              .toList();
    // "Select all" only toggles the addable (not-yet-owned) cards among
    // what's currently visible — already-owned tiles aren't selectable.
    final selectable = visible
        .where((p) => !widget.owned.contains(p.id))
        .toList();
    final allSelected =
        selectable.isNotEmpty &&
        selectable.every((p) => widget.selected.contains(p.id));

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        children: [
          BankStepHeader(
            label: 'ADD CARDS',
            bankName: widget.issuerName,
            logoUrl: widget.logoUrl,
          ),
          const SizedBox(height: 6),
          Text(
            'Choose the cards you have.',
            textAlign: TextAlign.center,
            style: AppText.bodyMd(color: AppColors.mutedFg),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v),
            style: AppText.bodyMd(),
            decoration: InputDecoration(
              hintText: 'Search ${widget.issuerName} cards…',
              prefixIcon: Icon(
                LucideIcons.search,
                size: 18,
                color: AppColors.mutedFg,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('AVAILABLE CARDS', style: AppText.labelSm()),
              const Spacer(),
              TextButton(
                onPressed: selectable.isEmpty
                    ? null
                    : () {
                        for (final p in selectable) {
                          widget.onChanged(p.id, !allSelected);
                        }
                      },
                child: Text(allSelected ? 'Clear all' : 'Select all'),
              ),
            ],
          ),
          Expanded(
            child: visible.isEmpty
                ? const _EmptyProducts()
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final p = visible[index];
                      final isOwned = widget.owned.contains(p.id);
                      return _ProductTile(
                        product: p,
                        selected: widget.selected.contains(p.id),
                        alreadyOwned: isOwned,
                        onTap: isOwned
                            ? null
                            : () => widget.onChanged(
                                p.id,
                                !widget.selected.contains(p.id),
                              ),
                      );
                    },
                  ),
          ),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: widget.selected.isEmpty ? null : widget.onContinue,
              child: Text('Continue · ${widget.selected.length} selected'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CardDetailsForm extends StatelessWidget {
  const _CardDetailsForm({
    required this.issuerName,
    required this.logoUrl,
    required this.products,
    required this.details,
    required this.onAdd,
  });
  final String issuerName;
  final String? logoUrl;
  final List<CardProduct> products;
  final Map<String, _CardDetails> details;
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
    child: Column(
      children: [
        // Header + description scroll together with the card forms as one
        // page — with several selected cards the fixed-header version left
        // too little room to see a whole form at once. Only the CTA below
        // stays pinned.
        Expanded(
          child: ListView(
            children: [
              BankStepHeader(
                label: 'CARD DETAILS',
                bankName: issuerName,
                logoUrl: logoUrl,
              ),
              const SizedBox(height: 6),
              Text(
                'All optional — add now or edit later.',
                textAlign: TextAlign.center,
                style: AppText.bodyMd(color: AppColors.mutedFg),
              ),
              const SizedBox(height: 20),
              for (final product in products) ...[
                _DetailsCard(product: product, details: details[product.id]!),
                const SizedBox(height: 20),
              ],
            ],
          ),
        ),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: onAdd,
            child: Text(
              'Add ${products.length} card${products.length == 1 ? '' : 's'}',
            ),
          ),
        ),
        Center(
          child: TextButton(
            onPressed: onAdd,
            child: const Text('Skip for now — add without these details'),
          ),
        ),
      ],
    ),
  );
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.product, required this.details});
  final CardProduct product;
  final _CardDetails details;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(kRadiusM),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 28,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(kRadiusXs),
              ),
              child: const Icon(
                LucideIcons.creditCard,
                size: 13,
                color: AppColors.onPrimary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(product.displayName, style: AppText.titleMd()),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Last 4 digits', style: AppText.bodySm()),
        const SizedBox(height: 4),
        TextField(
          controller: details.lastFourController,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4),
          ],
          decoration: const InputDecoration(hintText: '1234'),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Credit limit', style: AppText.bodySm()),
                  const SizedBox(height: 4),
                  TextField(
                    controller: details.limitController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: const InputDecoration(hintText: r'$10,000'),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Due date', style: AppText.bodySm()),
                  const SizedBox(height: 4),
                  TextField(
                    controller: details.dueDayController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ],
                    decoration: const InputDecoration(hintText: '15th'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.outcomes,
    required this.addAnotherLabel,
    required this.onDone,
    required this.onAddAnother,
  });
  final List<_AddOutcome> outcomes;
  final String addAnotherLabel;
  final VoidCallback onDone;
  final VoidCallback onAddAnother;
  @override
  Widget build(BuildContext context) {
    final added = outcomes
        .where((o) => o.result.status == ManualCardAddStatus.added)
        .toList();
    final failed = outcomes
        .where((o) => o.result.status != ManualCardAddStatus.added)
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      child: Column(
        children: [
          Icon(LucideIcons.circleCheck, color: AppColors.green, size: 64),
          const SizedBox(height: 12),
          Text(
            '${added.length} card${added.length == 1 ? '' : 's'} added',
            style: AppText.titleLg().copyWith(fontSize: 22),
          ),
          const SizedBox(height: 6),
          Text(
            "They're now in your wallet and ready to use. Edit details "
            'anytime from the Cards tab.',
            textAlign: TextAlign.center,
            style: AppText.bodyMd(color: AppColors.mutedFg),
          ),
          const SizedBox(height: 28),
          Expanded(
            child: ListView(
              children: [
                if (added.isNotEmpty)
                  _OutcomeSection(
                    label: 'ADDED (${added.length})',
                    outcomes: added,
                    successful: true,
                  ),
                if (failed.isNotEmpty)
                  _OutcomeSection(
                    label: "COULDN'T ADD (${failed.length})",
                    outcomes: failed,
                    successful: false,
                  ),
              ],
            ),
          ),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(onPressed: onDone, child: const Text('Done')),
          ),
          TextButton(onPressed: onAddAnother, child: Text(addAnotherLabel)),
        ],
      ),
    );
  }
}

class _OutcomeSection extends StatelessWidget {
  const _OutcomeSection({
    required this.label,
    required this.outcomes,
    required this.successful,
  });
  final String label;
  final List<_AddOutcome> outcomes;
  final bool successful;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppText.labelSm()),
      const SizedBox(height: 10),
      ...outcomes.map(
        (o) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _OutcomeTile(outcome: o, successful: successful),
        ),
      ),
    ],
  );
}

class _OutcomeTile extends StatelessWidget {
  const _OutcomeTile({required this.outcome, required this.successful});
  final _AddOutcome outcome;
  final bool successful;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppColors.card,
      border: successful ? null : Border.all(color: AppColors.red),
      borderRadius: BorderRadius.circular(kRadiusM),
    ),
    child: Row(
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: successful ? AppColors.green : AppColors.redBg,
            shape: BoxShape.circle,
          ),
          child: Icon(
            successful ? LucideIcons.check : LucideIcons.circleAlert,
            size: 16,
            color: successful ? AppColors.onPrimary : AppColors.red,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(outcome.product.displayName, style: AppText.titleMd()),
              Text(
                successful
                    ? '${outcome.product.network ?? 'Card'} • ${issuerDisplayName(outcome.product.issuer)}'
                    : 'Already in your wallet',
                style: AppText.bodySm(
                  color: successful ? AppColors.mutedFg : AppColors.red,
                ),
              ),
            ],
          ),
        ),
        if (successful)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.greenBg,
              borderRadius: BorderRadius.circular(kRadiusPill),
            ),
            child: Text(
              'ADDED',
              style: AppText.labelSm(color: AppColors.green),
            ),
          ),
      ],
    ),
  );
}

class _ProductTile extends StatelessWidget {
  const _ProductTile({
    required this.product,
    required this.selected,
    required this.onTap,
    this.alreadyOwned = false,
  });
  final CardProduct product;
  final bool selected;
  // True when this product is already in the wallet. Shown flat and muted
  // with an IN WALLET pill and NO checkbox, rather than as a checked row:
  // a check reads as "you just selected this", and the row isn't tappable,
  // so the user would be left trying to uncheck something that can't move.
  final bool alreadyOwned;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(kRadiusM),
    child: Opacity(
      opacity: alreadyOwned ? 0.55 : 1,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          border: Border.all(
            color: selected && !alreadyOwned
                ? AppColors.primary
                : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(kRadiusM),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.secondary,
                borderRadius: BorderRadius.circular(kRadiusXs),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(kRadiusXs),
                child: (product.imageUrl == null || product.imageUrl!.isEmpty)
                    ? const Icon(LucideIcons.creditCard, size: 18)
                    : CachedNetworkImage(
                        imageUrl: product.imageUrl!,
                        width: 40,
                        height: 28,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            const Icon(LucideIcons.creditCard, size: 18),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(product.displayName, style: AppText.titleMd()),
                  Text(
                    '${product.network ?? 'Card'} • Credit',
                    style: AppText.bodySm(),
                  ),
                ],
              ),
            ),
            if (alreadyOwned)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.greenBg,
                  borderRadius: BorderRadius.circular(kRadiusPill),
                ),
                child: Text(
                  'IN WALLET',
                  style: AppText.labelSm(color: AppColors.green),
                ),
              )
            else
              Icon(
                selected ? LucideIcons.circleCheck : LucideIcons.circle,
                size: 24,
                color: selected ? AppColors.primary : AppColors.mutedFg,
              ),
          ],
        ),
      ),
    ),
  );
}

class _EmptyProducts extends StatelessWidget {
  const _EmptyProducts();
  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      "We don't have any cards for this issuer yet.",
      textAlign: TextAlign.center,
      style: AppText.bodyMd(color: AppColors.mutedFg),
    ),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.error});
  final String error;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text('Unable to load cards.\n$error', textAlign: TextAlign.center),
    ),
  );
}

class _CardDetails {
  final lastFourController = TextEditingController();
  final limitController = TextEditingController();
  final dueDayController = TextEditingController();
  String? get lastFour {
    final v = lastFourController.text.trim();
    return v.length == 4 ? v : null;
  }

  double? get creditLimit => double.tryParse(limitController.text.trim());
  int? get dueDay {
    final value = int.tryParse(dueDayController.text.trim());
    return value != null && value >= 1 && value <= 31 ? value : null;
  }

  void dispose() {
    lastFourController.dispose();
    limitController.dispose();
    dueDayController.dispose();
  }
}

class _AddOutcome {
  const _AddOutcome(this.product, this.result);
  final CardProduct product;
  final ManualCardAddResult result;
}
