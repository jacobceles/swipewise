import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/catalog_repository.dart';
import '../api/settings_repository.dart';
import '../providers/data_providers.dart';
import '../theme/app_theme.dart';
import '../widgets/connect_bank_app_bar.dart';
import '../widgets/country_filter.dart';
import 'manual_card_flow_screen.dart';

/// Lowercase card product names grouped by normalized issuer slug so typing a
/// card name ("Sapphire", "Cobalt") on the issuer screen filters to the
/// issuer(s) that offer it.
final catalogProductNamesByIssuerProvider =
    FutureProvider<Map<String, List<String>>>((ref) async {
      await ref.watch(catalogIssuersProvider.future);
      try {
        final repo = ref.watch(dataRepositoryProvider);
        final all = await repo.catalog.productsForIssuer(null);
        final byIssuer = <String, List<String>>{};
        for (final p in all) {
          final key = p.issuer.toLowerCase().replaceAll(
            RegExp(r'[^a-z0-9]'),
            '',
          );
          (byIssuer[key] ??= <String>[]).add(p.displayName.toLowerCase());
        }
        return byIssuer;
      } catch (_) {
        return const {};
      }
    });

/// Constant across every step of the flow — the app bar names the task, and
/// per-step context lives in the header block instead. Wireframe `kjiHP` /
/// `tvrOa` / `QYoqF` / `I2kWs7`.
const String kAddCardsTitle = 'Add a Card';

/// Build a wallet with no bank involved: pick an issuer, then pick cards.
///
/// The app's original — and until now only — way to own a card ran through
/// the bank picker, so a build with no bank credentials could not add a card
/// by any route. This is the other entry point. It reads the local catalog
/// and nothing else: no network call, no account, no institution.
///
/// The product/details/result steps are [ManualCardFlowScreen], shared with
/// the bank flow, so there is one implementation of "add these cards to the
/// wallet" rather than two that drift.
class AddCardsScreen extends ConsumerStatefulWidget {
  const AddCardsScreen({super.key});

  @override
  ConsumerState<AddCardsScreen> createState() => _AddCardsScreenState();
}

class _AddCardsScreenState extends ConsumerState<AddCardsScreen> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _country = catalogCountryAll;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openIssuer(CatalogIssuer issuer) {
    final q = _query.trim();
    final matchedIssuerName =
        q.isEmpty ||
        issuer.displayName.toLowerCase().contains(q.toLowerCase()) ||
        issuer.id.toLowerCase().contains(q.toLowerCase());
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ManualCardFlowScreen(
          // The catalog's own issuer value, not the display name: "Amex" is
          // the join key and "American Express" would match nothing.
          issuerQuery: issuer.id,
          displayName: issuer.displayName,
          addAnotherLabel: 'Add cards from another issuer',
          appBarTitle: kAddCardsTitle,
          country: _country,
          initialQuery: matchedIssuerName ? '' : q,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final issuers = ref.watch(catalogIssuersProvider);
    final productsByIssuer =
        ref.watch(catalogProductNamesByIssuerProvider).value ?? const {};
    final counts = ref.watch(walletCountsByIssuerProvider).value ?? const {};
    final added = counts.values.fold(0, (sum, n) => sum + n);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: ConnectBankAppBar(
        title: kAddCardsTitle,
        onClose: () => Navigator.of(context).pop(),
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: switch (issuers) {
            AsyncError(:final error) => _LoadFailure(error: '$error'),
            AsyncData(:final value) => _IssuerList(
              issuers: _visible(value, productsByIssuer),
              counts: counts,
              added: added,
              searchCtrl: _searchCtrl,
              onQueryChanged: (v) => setState(() => _query = v),
              country: _country,
              onCountryChanged: (v) => setState(() => _country = v),
              onPick: _openIssuer,
            ),
            _ => const Center(child: CircularProgressIndicator()),
          },
        ),
      ),
    );
  }

  List<CatalogIssuer> _visible(
    List<CatalogIssuer> all,
    Map<String, List<String>> productsByIssuer,
  ) {
    final q = _query.trim().toLowerCase();
    // Match the raw catalog value and card product names too, so typing "amex"
    // finds American Express and typing "sapphire" shows Chase.
    return all.where((i) {
      if (_country != catalogCountryAll && !i.countries.contains(_country)) {
        return false;
      }
      if (q.isEmpty ||
          i.displayName.toLowerCase().contains(q) ||
          i.id.toLowerCase().contains(q)) {
        return true;
      }
      final key = i.id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final names = productsByIssuer[key] ?? const [];
      return names.any((name) => name.contains(q));
    }).toList();
  }
}

class _IssuerList extends StatelessWidget {
  const _IssuerList({
    required this.issuers,
    required this.counts,
    required this.added,
    required this.searchCtrl,
    required this.onQueryChanged,
    required this.country,
    required this.onCountryChanged,
    required this.onPick,
  });

  final List<CatalogIssuer> issuers;
  final Map<String, int> counts;
  final int added;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onQueryChanged;
  final String country;
  final ValueChanged<String> onCountryChanged;
  final void Function(CatalogIssuer) onPick;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Pick the issuer of the card you want to add.',
        style: AppText.bodyMd(color: AppColors.mutedFg),
      ),
      // Progress, not decoration. The grid looks identical before and after a
      // trip through the flow, so without this there is nothing on screen to
      // confirm the last batch actually landed.
      if (added > 0) ...[
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.greenBg,
            borderRadius: BorderRadius.circular(kRadiusPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.check, size: 13, color: AppColors.green),
              const SizedBox(width: 6),
              Text(
                '$added card${added == 1 ? '' : 's'} added so far',
                style: AppText.labelSm(color: AppColors.green),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        controller: searchCtrl,
        onChanged: onQueryChanged,
        style: AppText.bodyMd(),
        decoration: InputDecoration(
          hintText: 'Search issuers or cards…',
          prefixIcon: Icon(
            LucideIcons.search,
            size: 18,
            color: AppColors.mutedFg,
          ),
        ),
      ),
      const SizedBox(height: 16),
      CountryFilter(value: country, onChanged: onCountryChanged),
      const SizedBox(height: 16),
      Row(
        children: [
          Text(switch (country) {
            'US' => 'US ISSUERS',
            'CA' => 'CANADIAN ISSUERS',
            _ => 'ALL ISSUERS',
          }, style: AppText.labelSm()),
          const Spacer(),
          Text(
            '${issuers.length} issuer${issuers.length == 1 ? '' : 's'}',
            style: AppText.labelSm().copyWith(
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Expanded(
        child: issuers.isEmpty
            ? const _NoIssuers()
            : GridView.builder(
                itemCount: issuers.length,
                // Fixed height rather than an aspect ratio so a tile with the
                // "N added" tag is the same size as one without it. Sized for
                // the tallest tile: a country tag AND an "N added" line.
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  mainAxisExtent: 120,
                ),
                itemBuilder: (_, index) {
                  final issuer = issuers[index];
                  return _IssuerTile(
                    issuer: issuer,
                    // Only the unfiltered view tags, and only issuers that sell
                    // outside the US — tagging every US tile would be noise.
                    countryTag:
                        country != catalogCountryAll ||
                            !issuer.countries.contains('CA')
                        ? null
                        : issuer.countries.contains('US')
                        ? 'US + CANADA'
                        : 'CANADA',
                    addedCount: counts[issuer.id] ?? 0,
                    onTap: () => onPick(issuer),
                  );
                },
              ),
      ),
    ],
  );
}

class _IssuerTile extends StatelessWidget {
  const _IssuerTile({
    required this.issuer,
    required this.countryTag,
    required this.addedCount,
    required this.onTap,
  });

  final CatalogIssuer issuer;
  final String? countryTag;
  final int addedCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(kRadiusM),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(kRadiusM),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // The issuer's logo rather than card art: the art is a rectangular
          // card image, and one product's design says nothing about the
          // issuer as a whole. No bundled logo: a letter in the same light
          // circle the bank picker uses for logo-less institutions.
          // Opaque square icons (logo.dev), so an app-icon tile needs no frame.
          if (issuerLogoAsset(issuer.id) case final logo?)
            ClipRRect(
              borderRadius: BorderRadius.circular(kRadiusS),
              child: Image.asset(logo, width: 40, height: 40),
            )
          else
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: AppColors.bankLogoTile,
                shape: BoxShape.circle,
              ),
              child: Text(
                issuer.displayName.isEmpty
                    ? '?'
                    : issuer.displayName.substring(0, 1).toUpperCase(),
                style: AppText.titleMd(color: AppColors.onPrimary),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            issuer.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodyMd(),
          ),
          if (countryTag != null) Text(countryTag!, style: AppText.labelSm()),
          if (addedCount > 0)
            Text(
              '$addedCount added',
              style: AppText.labelSm(color: AppColors.green),
            ),
        ],
      ),
    ),
  );
}

class _NoIssuers extends StatelessWidget {
  const _NoIssuers();

  static final _missingCardUri = Uri.parse(
    'https://github.com/jacobceles/swipewise/issues/new?title=Missing+card:+',
  );

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'No issuers match that search.',
          textAlign: TextAlign.center,
          style: AppText.bodyMd(color: AppColors.mutedFg),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => launchUrl(
            _missingCardUri,
            mode: LaunchMode.externalApplication,
          ),
          child: const Text('Card missing? Tell us'),
        ),
      ],
    ),
  );
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      "Couldn't load the card catalog.\n$error",
      textAlign: TextAlign.center,
      style: AppText.bodyMd(color: AppColors.mutedFg),
    ),
  );
}
