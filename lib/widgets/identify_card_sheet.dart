import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/card_link_service.dart';
import '../api/data_repository.dart';
import '../api/reward_engine.dart';
import '../models/card.dart';
import '../providers/auth_provider.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';

/// Opens the Card Product Picker bottom sheet. This is the single entry
/// point for both the "Identify this card" flow (triggered from the
/// unidentified-card banner) and the "Rename this card" flow (triggered
/// from the pencil icon on any card detail). Renaming means picking the
/// correct catalog product so rewards/perks attach - the user cannot enter
/// freeform text unless their issuer has no catalog entry.
///
/// After a successful pick + confirm:
///   1. `setProductIdentification` is persisted on the card row (and any
///      prior custom rename cleared, so the catalog name/art wins)
///   2. `CardLinkService.confirmLink` writes a `user_confirmed` `card_links`
///      row binding the card to the catalog product, so the reward engine
///      ranks it and its perks/rewards resolve through the link
///   3. `cardsProvider` is invalidated so the wallet refreshes
///   4. A transient toast confirms the change
Future<void> showCardProductPicker(
  BuildContext context,
  WidgetRef ref,
  CardSummary card,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CardProductPicker(card: card),
  );
}

class _CardProductPicker extends ConsumerStatefulWidget {
  const _CardProductPicker({required this.card});
  final CardSummary card;

  @override
  ConsumerState<_CardProductPicker> createState() => _CardProductPickerState();
}

class _CardProductPickerState extends ConsumerState<_CardProductPicker> {
  late Future<List<CardProduct>> _future;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = _loadProducts();
  }

  /// Catalog products, issuer-filtered to the card's bank when we can match
  /// it loosely, else the whole catalog (search narrows it).
  Future<List<CardProduct>> _loadProducts() async {
    final all = await ref
        .read(dataRepositoryProvider)
        .catalog
        .productsForIssuer(null);
    // Match on an alphanumeric-only key so the synced provider ("US Bank" /
    // "U.S. Bank") reaches the catalog's slug-derived issuer ("Usbank");
    // a plain lowercase `contains` is defeated by the space/dots.
    final providerKey = _issuerKey(widget.card.provider ?? '');
    if (providerKey.isEmpty) return all;
    final sameIssuer = all.where((p) {
      final issuerKey = _issuerKey(p.issuer);
      return issuerKey.isNotEmpty &&
          (issuerKey.contains(providerKey) || providerKey.contains(issuerKey));
    }).toList();
    return sameIssuer.isEmpty ? all : sameIssuer;
  }

  static String _issuerKey(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final mediaQuery = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: mediaQuery.size.height * 0.85),
        decoration: BoxDecoration(
          color: palette.sheet,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: FutureBuilder<List<CardProduct>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final catalog = snap.data ?? const <CardProduct>[];
            if (catalog.isEmpty) {
              return _EmptyCatalog(card: widget.card);
            }
            final q = _query.trim().toLowerCase();
            final filtered = q.isEmpty
                ? catalog
                : catalog
                      .where((p) => p.displayName.toLowerCase().contains(q))
                      .toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Which ${widget.card.provider ?? 'card'} is this?',
                        style: AppText.titleMd().copyWith(fontSize: 20),
                      ),
                      if (widget.card.lastFour != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Last four: •••• ${widget.card.lastFour}',
                          style: AppText.bodySm(color: palette.muted),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search ${widget.card.provider ?? ''} cards'
                          .trim(),
                      prefixIcon: Icon(
                        LucideIcons.search,
                        size: 18,
                        color: palette.muted,
                      ),
                    ),
                  ),
                ),
                Flexible(
                  child: filtered.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No matches',
                            style: AppText.bodySm(color: palette.muted),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          shrinkWrap: true,
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) =>
                              Divider(height: 1, color: palette.border),
                          itemBuilder: (_, i) {
                            final p = filtered[i];
                            return _ProductRow(
                              product: p,
                              onTap: () => _onPick(p),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: TextButton(
                    onPressed: _onRenameManually,
                    child: Text(
                      "My card isn't listed - rename manually",
                      style: AppText.bodySm(color: AppColors.primary),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _onPick(CardProduct product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _ConfirmIdentityDialog(card: widget.card, product: product),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    await _applyIdentification(product);
  }

  Future<void> _applyIdentification(CardProduct product) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    final repo = ref.read(dataRepositoryProvider);
    // Persist the explicit pick + bind the card to this catalog product. The
    // confirm step also canonicalizes the card's name/art, so clear any prior
    // custom rename first.
    await repo.setProductIdentification(userId, widget.card.cardId, product.id);
    await repo.setCustomName(userId, widget.card.cardId, null);
    await CardLinkService().confirmLink(
      userId: userId,
      cardId: widget.card.cardId,
      cardProductId: product.id,
    );
    ref.invalidate(cardsProvider);
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    navigator.pop();
    final productName = product.displayName;
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(
              LucideIcons.circleCheck,
              color: Color(0xFF6FCF97),
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Card identified',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Rewards and perks added for $productName.',
                    style: const TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 4),
        backgroundColor: const Color(0xFF1A3D2A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusS),
          side: const BorderSide(color: Color(0x803E7A57)),
        ),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
    );
  }

  Future<void> _onRenameManually() async {
    final root = Navigator.of(context, rootNavigator: true);
    root.pop();
    await showManualRenameSheet(root.context, ref, widget.card);
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product, required this.onTap});
  final CardProduct product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final imageUrl = product.imageUrl;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.secondary,
                borderRadius: BorderRadius.circular(4),
              ),
              clipBehavior: Clip.antiAlias,
              child: imageUrl != null && imageUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) =>
                          const Icon(LucideIcons.creditCard, size: 18),
                    )
                  : const Icon(LucideIcons.creditCard, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                product.displayName,
                style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 18, color: palette.muted),
          ],
        ),
      ),
    );
  }
}

class _ConfirmIdentityDialog extends StatelessWidget {
  const _ConfirmIdentityDialog({required this.card, required this.product});
  final CardSummary card;
  final CardProduct product;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return AlertDialog(
      backgroundColor: palette.sheet,
      title: Text('Is this your card?', style: AppText.titleMd()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.secondary,
              borderRadius: BorderRadius.circular(kRadiusS),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.displayName,
                  style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
                ),
                if (card.lastFour != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Ending •••• ${card.lastFour}',
                    style: AppText.bodySm(color: palette.muted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            "We'll attach this product's rewards, perks, and category bonuses to your card.",
            style: AppText.bodySm(color: palette.muted),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Go back'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Yes, identify'),
        ),
      ],
    );
  }
}

class _EmptyCatalog extends ConsumerWidget {
  const _EmptyCatalog({required this.card});
  final CardSummary card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.secondary,
              shape: BoxShape.circle,
            ),
            child: Icon(LucideIcons.searchX, size: 32, color: palette.muted),
          ),
          const SizedBox(height: 14),
          Text("We don't know this issuer yet", style: AppText.titleMd()),
          const SizedBox(height: 8),
          Text(
            "${card.provider ?? 'This issuer'} isn't in our rewards catalog "
            "yet. Give the card a name you'll recognize - the card still "
            "works as usual, but rewards and perks won't be available.",
            textAlign: TextAlign.center,
            style: AppText.bodySm(color: palette.muted),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: () {
                final root = Navigator.of(context, rootNavigator: true);
                final rootContext = root.context;
                root.pop();
                showManualRenameSheet(rootContext, ref, card);
              },
              child: const Text('Rename card'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Keep current name'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Manual rename — freeform text input. Reachable from the picker's
/// "rename manually" fallback and (when the bank has no catalog entries)
/// from the empty-state sheet. Writes to `custom_name` only; does NOT
/// touch `product_identification` because freeform names can't bind
/// rewards (the catalog binder needs a stable product slug).
Future<void> showManualRenameSheet(
  BuildContext context,
  WidgetRef ref,
  CardSummary card,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ManualRenameSheet(card: card),
  );
}

class _ManualRenameSheet extends ConsumerStatefulWidget {
  const _ManualRenameSheet({required this.card});
  final CardSummary card;

  @override
  ConsumerState<_ManualRenameSheet> createState() => _ManualRenameSheetState();
}

class _ManualRenameSheetState extends ConsumerState<_ManualRenameSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.card.displayName);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final mediaQuery = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: palette.sheet,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
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
            const SizedBox(height: 16),
            Text('Rename this card', style: AppText.titleMd()),
            const SizedBox(height: 6),
            Text(
              widget.card.productIdentification == null
                  ? "Give this card a name you'll recognize. Rewards and "
                        "perks won't be available unless you identify it "
                        'from the catalog.'
                  : "Give this card a custom name. The display name will be "
                        'overridden, but identified rewards and perks stay '
                        'attached.',
              style: AppText.bodySm(color: palette.muted),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Card name'),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: _save,
                child: const Text('Save name'),
              ),
            ),
            if (widget.card.customName != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: TextButton(
                  onPressed: _clear,
                  child: Text(
                    'Reset to original name',
                    style: AppText.bodyMd(color: palette.muted),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    final name = _ctrl.text.trim();
    if (name.isEmpty) return;
    await ref
        .read(dataRepositoryProvider)
        .setCustomName(userId, widget.card.cardId, name);
    ref.invalidate(cardsProvider);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _clear() async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    await ref
        .read(dataRepositoryProvider)
        .setCustomName(userId, widget.card.cardId, null);
    ref.invalidate(cardsProvider);
    if (mounted) Navigator.pop(context);
  }
}

/// Inline banner shown above an unidentified card row on the Cards
/// screen and inside the Card Details sheet. Amber-tinted to communicate
/// "informational, action required" without being an error state.
class IdentifyCardBanner extends ConsumerWidget {
  const IdentifyCardBanner({super.key, required this.card});

  final CardSummary card;

  static bool shouldShowFor(CardSummary card) {
    if (card.source != 'bank') return false;
    if (card.isExplicitlyIdentified) return false;
    return DataRepository.isAmbiguousCardName(card.name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    return InkWell(
      onTap: () => showCardProductPicker(context, ref, card),
      borderRadius: BorderRadius.circular(kRadiusS),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x14FF8400),
          borderRadius: BorderRadius.circular(kRadiusS),
          border: Border.all(color: const Color(0x40FF8400)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.scanSearch, size: 18, color: palette.amber),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Couldn't identify this card",
                    style: AppText.bodyMd().copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Identify it to unlock rewards and perks.',
                    style: AppText.bodySm(color: palette.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(kRadiusPill),
              ),
              child: Text(
                'Identify',
                style: AppText.bodySm(
                  color: AppColors.onPrimary,
                ).copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
