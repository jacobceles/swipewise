import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../models/card.dart';
import '../models/insights.dart';
import '../api/data_repository.dart';
import '../api/bank_client.dart';
import '../api/types.dart';
import '../providers/entitlement_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/data_providers.dart';
import '../providers/settings_provider.dart';
import '../providers/bank_sync_provider.dart';
import '../sync/sync_progress_event.dart';
import '../notifications/payment_reminder_service.dart';
import '../theme/app_theme.dart';
import 'due_date_sheet.dart';
import '../util/logger.dart';
import '../widgets/async_action_button.dart';
import '../widgets/bank_sync_progress_banner.dart';
import '../widgets/identify_card_sheet.dart';
import '../widgets/first_sync_body.dart';

/// Wireframe `iDYBq` - Cards tab. Bank sections + per-card rows with card
/// art, utilization bar, and a Card Details sheet on tap.
class CardsScreen extends ConsumerStatefulWidget {
  const CardsScreen({super.key});

  @override
  ConsumerState<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends ConsumerState<CardsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final cardsAsync = ref.watch(cardsProvider);
    // Honor "Include Debit Accounts" - when off, hide checking/savings
    // rows even if they're still in the DB from a previous sync round
    // before the user flipped the toggle off. Without this the Cards
    // screen and the filter-by-cards sheet can disagree.
    final includeDebit = ref.watch(includeDebitAccountsProvider);

    final syncState = ref.watch(bankSyncProvider);
    // First-sync detection: empty DB + sync currently running (either
    // AsyncLoading state OR progress events flowing but no end-result yet).
    final syncInProgress =
        syncState.isLoading ||
        (syncState.hasValue &&
            syncState.value!.lastProgress != null &&
            syncState.value!.lastProgress is! SyncCompleted);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopBar(),
            Expanded(
              child: cardsAsync.when(
                loading: () => _LoadingBody(palette: palette),
                error: (e, _) => _ErrorBody(error: '$e', palette: palette),
                data: (cards) {
                  final visible = includeDebit
                      ? cards
                      : cards.where((c) => !c.isDepositAccount).toList();
                  if (visible.isEmpty) {
                    if (syncInProgress) return const FirstSyncBody();
                    // A first sync that threw leaves the DB empty AND
                    // bankSyncProvider in error. Without this branch that
                    // falls through to _EmptyBody ("No banks linked yet") —
                    // wrong (they did link) and with no retry. Show the
                    // failure with a Retry that re-runs the sync.
                    if (syncState.hasError) {
                      return _SyncFailedBody(
                        palette: palette,
                        onRetry: () =>
                            ref.read(bankSyncProvider.notifier).runSync(),
                      );
                    }
                    return _EmptyBody(palette: palette);
                  }
                  // Banner is only shown when the user has cards to look
                  // at. The empty-DB first-sync path renders FirstSyncBody
                  // which owns the whole body — stacking the banner on
                  // top of it would just duplicate the progress UI.
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const BankSyncProgressBanner(),
                      Expanded(
                        child: _Body(
                          cards: visible,
                          query: _query,
                          onQueryChanged: (v) => setState(() => _query = v),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final isPro = ref.watch(proEntitlementProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Cards',
              style: AppText.displayLg().copyWith(fontSize: 28),
            ),
          ),
          GestureDetector(
            onTap: () {
              if (!isPro) {
                context.push('/add-cards');
              } else if (_canLinkBank(context, ref)) {
                context.push('/add-bank');
              }
            },
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.secondary,
                shape: BoxShape.circle,
              ),
              child: const Icon(LucideIcons.plus, size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({
    required this.cards,
    required this.query,
    required this.onQueryChanged,
  });

  final List<CardSummary> cards;
  final String query;
  final ValueChanged<String> onQueryChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final credit = cards.where((c) => c.isCreditCard).toList();
    final totalBalance = credit.fold<double>(0, (a, c) => a + c.balance);
    final limitedCC = credit.where((c) => c.creditLimit != null);
    final totalLimit = limitedCC.fold<double>(0, (a, c) => a + c.creditLimit!);
    final available = limitedCC
        .fold<double>(
          0,
          (a, c) => a + (c.creditAvailable ?? (c.creditLimit! - c.balance)),
        )
        .clamp(0, double.infinity)
        .toDouble();

    final filtered = query.isEmpty
        ? cards
        : cards
              .where(
                (c) =>
                    c.name.toLowerCase().contains(query.toLowerCase()) ||
                    (c.lastFour?.contains(query) ?? false),
              )
              .toList();

    // Group by `institution_id` (stable across renames/case drift), with
    // a legacy "manual" bucket for manual cards added before per-issuer
    // grouping existed (no institution at all). Manual cards added since
    // carry a synthetic `CardRepository.manualInstitutionId` per issuer
    // (e.g. "manual:chase") — never a real Sophtron id — so they group
    // together under their own "<Issuer> (Manual)" section instead of a
    // single flat "Manual" bucket, and never merge into a live bank
    // connection's section for the same issuer. The display label per
    // group falls back through: live connection's `institution_name` →
    // first card's `provider` → "Previous link".
    final connByInstId =
        ref.watch(bankConnectionsByInstitutionIdProvider).value ??
        const <String, BankConnectionRow>{};
    const manualKey = '__manual__';
    final groups = <String, List<CardSummary>>{};
    for (final c in filtered) {
      final key = c.institutionId ?? manualKey;
      groups.putIfAbsent(key, () => []).add(c);
    }

    bool isManualGroup(List<CardSummary> groupCards) =>
        groupCards.isNotEmpty && groupCards.every((c) => c.source == 'manual');

    String labelFor(String key, List<CardSummary> groupCards) {
      if (key == manualKey) return 'Manual';
      if (isManualGroup(groupCards)) {
        final cardProvider = groupCards.first.provider;
        final issuer = (cardProvider != null && cardProvider.isNotEmpty)
            ? cardProvider
            : 'Manual';
        return '$issuer (Manual)';
      }
      final connName = connByInstId[key]?.institutionName;
      if (connName != null && connName.isNotEmpty) return connName;
      final cardProvider = groupCards.firstOrNull?.provider;
      if (cardProvider != null && cardProvider.isNotEmpty) return cardProvider;
      return 'Previous link';
    }

    // Sort: broken (last_sync_status='failed') → orphan (no connection)
    // → normal, then alphabetical inside each band.
    int sortBand(String key) {
      if (key == manualKey) return 2; // always at the end
      final conn = connByInstId[key];
      if (conn == null) return 1; // orphan
      if (conn.lastSyncStatus == 'failed') return 0; // broken first
      return 1;
    }

    final keys = groups.keys.toList()
      ..sort((a, b) {
        final byBand = sortBand(a).compareTo(sortBand(b));
        if (byBand != 0) return byBand;
        return labelFor(
          a,
          groups[a]!,
        ).toLowerCase().compareTo(labelFor(b, groups[b]!).toLowerCase());
      });

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
      children: [
        Row(
          children: [
            Expanded(
              child: _RollupTile(label: 'Used', value: _money(totalBalance)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _RollupTile(label: 'Limit', value: _money(totalLimit)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _RollupTile(
                label: 'Available',
                value: _money(available),
                valueColor: palette.green,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          height: 44,
          decoration: BoxDecoration(
            color: palette.secondary,
            borderRadius: BorderRadius.circular(kRadiusPill),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.search, size: 18, color: palette.muted),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  onChanged: onQueryChanged,
                  decoration: InputDecoration(
                    hintText: 'Search cards…',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                    hintStyle: AppText.bodyMd(color: palette.muted),
                  ),
                  style: AppText.bodyMd(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (filtered.isEmpty)
          _FilteredEmpty(palette: palette)
        else
          for (var i = 0; i < keys.length; i++) ...[
            _BankSection(
              groupKey: keys[i],
              label: labelFor(keys[i], groups[keys[i]]!),
              institutionId: keys[i] == manualKey ? null : keys[i],
              cards: groups[keys[i]]!,
              autoExpand: keys.length == 1,
            ),
            if (i < keys.length - 1) const SizedBox(height: 20),
          ],
      ],
    );
  }
}

class _RollupTile extends StatelessWidget {
  const _RollupTile({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.labelSm().copyWith(fontSize: 11)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppText.monoLg(
                color: valueColor ?? AppColors.foreground,
              ).copyWith(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _BankSection extends ConsumerStatefulWidget {
  const _BankSection({
    required this.groupKey,
    required this.label,
    required this.institutionId,
    required this.cards,
    required this.autoExpand,
  });

  /// Stable group identity (institution_id for Sophtron-sourced banks,
  /// the manual sentinel for the Manual bucket). Drives connection
  /// lookup; never displayed.
  final String groupKey;

  /// Human-visible bank name in the section header.
  final String label;

  /// `null` for the Manual group; the Sophtron `InstitutionID` otherwise.
  final String? institutionId;

  final List<CardSummary> cards;
  final bool autoExpand;

  @override
  ConsumerState<_BankSection> createState() => _BankSectionState();
}

class _BankSectionState extends ConsumerState<_BankSection> {
  late bool _expanded = widget.autoExpand;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final connByInstId =
        ref.watch(bankConnectionsByInstitutionIdProvider).value ??
        const <String, BankConnectionRow>{};
    final conn = widget.institutionId == null
        ? null
        : connByInstId[widget.institutionId!];
    // A manual group is either the legacy bucket (no institution at all) or
    // one whose cards are all `source='manual'`. The second half matters:
    // manually-added cards carry a synthetic `manual:<issuer>` institution id,
    // so testing only for a null id classified every one of them as a bank —
    // and then, finding no connection row, as an *orphaned* bank. The whole
    // wallet rendered under "This bank isn't linked anymore" with a Reconnect
    // button, which in a free build points at a route that doesn't exist.
    final isManual =
        widget.institutionId == null ||
        widget.cards.every((c) => c.source == 'manual');
    // Both states are bank-connection states, and both branches render a
    // button offering to reconnect a bank. Without Pro neither state can
    // arise (every card is manual, and there are no `bank_connections` rows),
    // but that is a runtime invariant several files away — anchoring on
    // entitlement makes the whole branch fail closed instead.
    final isPro = ref.watch(proEntitlementProvider);
    final isBroken = isPro && conn?.lastSyncStatus == 'failed';
    // Orphan: cards present + non-Manual + no live connection row. The
    // user disconnected, or the bank was wiped server-side.
    final isOrphan = isPro && !isManual && conn == null;
    final memberId = conn?.userInstitutionId;
    final lastSyncedAt = conn?.lastSyncedAt;

    final credit = widget.cards.where((c) => c.isCreditCard);
    final totalBalance = credit.fold<double>(0, (a, c) => a + c.balance);
    final totalLimit = credit
        .where((c) => c.creditLimit != null)
        .fold<double>(0, (a, c) => a + c.creditLimit!);
    final available = credit
        .where((c) => c.creditLimit != null)
        .fold<double>(
          0,
          (a, c) => a + (c.creditAvailable ?? (c.creditLimit! - c.balance)),
        )
        .clamp(0, double.infinity)
        .toDouble();

    // Prefer the institution_logo from bank_connections (link-time
    // URL or v1-lookup refresh) over the per-card copy, since not every
    // card row has it populated.
    final logoUrl =
        conn?.institutionLogo ??
        widget.cards
            .where(
              (c) => c.institutionLogo != null && c.institutionLogo!.isNotEmpty,
            )
            .firstOrNull
            ?.institutionLogo;

    final dimCards = isBroken || isOrphan;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              // Header tap zone (logo + name + count) → bank info sheet.
              // The chevron is a separate tap target for expand/collapse.
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Manual groups get the delete confirmation instead of the
                  // bank sheet: Reconnect and sync metadata mean nothing for a
                  // wallet the user typed in, but "remove all of these" is the
                  // same need Disconnect serves for a linked bank.
                  onTap: isManual
                      ? () => _confirmDeleteManualGroup(
                          context,
                          ref,
                          widget.label,
                          widget.cards,
                        )
                      : isOrphan
                      ? null
                      : () => _openBankInfoSheet(
                          context: context,
                          ref: ref,
                          bank: widget.label,
                          logoUrl: logoUrl,
                          memberId: memberId,
                          institutionId: widget.institutionId,
                          lastSyncedAt: lastSyncedAt,
                        ),
                  child: Row(
                    children: [
                      _BankLogo(bank: widget.label, logoUrl: logoUrl),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.label, style: AppText.titleMd()),
                            const SizedBox(height: 2),
                            Text(
                              widget.cards.length == 1
                                  ? '1 card'
                                  : '${widget.cards.length} cards',
                              style: AppText.bodySm(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  child: Icon(
                    _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                    size: 24,
                    color: palette.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (isOrphan) ...[
          _OrphanBanner(palette: palette),
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                if (_canLinkBank(context, ref)) context.push('/add-bank');
              },
              child: const Text('Reconnect bank'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 44,
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _confirmRemoveOrphan(
                context: context,
                ref: ref,
                bank: widget.label,
                institutionId: widget.institutionId!,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.red,
                side: BorderSide(color: palette.red),
              ),
              child: const Text('Remove cards'),
            ),
          ),
        ] else if (isBroken) ...[
          // Broken state replaces (not overlays) the normal stats row.
          // Goal: impossible to miss - a small icon was too easy to skip.
          _BrokenBanner(palette: palette),
          const SizedBox(height: 10),
          _ReconnectButton(
            bank: widget.label,
            institutionId: widget.institutionId,
            logoUrl: logoUrl,
          ),
          if (lastSyncedAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Last synced ${_relativeDate(lastSyncedAt)}',
              style: AppText.bodySm(color: palette.muted),
            ),
          ],
        ] else
          Row(
            children: [
              Expanded(
                child: _MiniStat(label: 'Used', value: _money(totalBalance)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(label: 'Limit', value: _money(totalLimit)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  label: 'Available',
                  value: _money(available),
                  valueColor: palette.green,
                ),
              ),
            ],
          ),
        if (_expanded) ...[
          const SizedBox(height: 12),
          for (final c in widget.cards)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Opacity(
                opacity: dimCards ? 0.5 : 1.0,
                child: _CardRow(card: c, hideUtilization: isOrphan),
              ),
            ),
        ],
      ],
    );
  }
}

class _OrphanBanner extends StatelessWidget {
  const _OrphanBanner({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusS),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.unlink, size: 18, color: palette.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Not connected',
                  style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  "This bank isn't linked anymore. Reconnect to resume "
                  'syncing or remove the leftover cards.',
                  style: AppText.bodySm(color: palette.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _confirmRemoveOrphan({
  required BuildContext context,
  required WidgetRef ref,
  required String bank,
  required String institutionId,
}) async {
  final palette = AppPalette.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: palette.sheet,
      title: Text('Remove $bank cards?'),
      content: Text(
        'This deletes the locally stored cards and transactions for '
        '$bank. The bank is already disconnected at the aggregator - '
        'nothing is removed there. You can re-add the bank anytime.',
        style: AppText.bodyMd(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: palette.red),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final userId = ref.read(authProvider).userId;
  if (userId == null) return;
  try {
    final txCount = await DataRepository().deleteOrphanCardsByInstitution(
      userId: userId,
      institutionId: institutionId,
    );
    for (final p in syncInvalidatedProviders) {
      container.invalidate(p);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          txCount == 0
              ? 'Removed $bank'
              : 'Removed $bank · $txCount transactions cleared',
        ),
      ),
    );
  } catch (e, st) {
    Log.e('cards-screen', 'orphan remove failed for $institutionId', e, st);
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't remove $bank: $e")),
    );
  }
}

class _BrokenBanner extends StatelessWidget {
  const _BrokenBanner({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.redBg,
        borderRadius: BorderRadius.circular(kRadiusS),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.triangleAlert, size: 18, color: palette.red),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Connection lost',
              style: AppText.bodyMd(
                color: palette.red,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReconnectButton extends StatelessWidget {
  const _ReconnectButton({
    required this.bank,
    required this.institutionId,
    required this.logoUrl,
  });
  final String bank;
  final String? institutionId;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      width: double.infinity,
      child: ElevatedButton(
        onPressed: institutionId == null
            ? null
            : () => _navigateToReconnect(
                context: context,
                bank: bank,
                institutionId: institutionId!,
                logoUrl: logoUrl,
                // Broken-section button only renders when
                // last_sync_status='failed' - the "credentials expired"
                // copy in the form is accurate here.
                wasBroken: true,
              ),
        child: const Text('Reconnect'),
      ),
    );
  }
}

/// Human-readable elapsed time for the last-synced timestamp on a broken
/// bank row. Same shape across the bank section + bank info sheet.
String _relativeDate(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  final diff = DateTime.now().toUtc().difference(dt.toUtc());
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return DateFormat('MMM d, y').format(dt.toLocal());
}

/// Guards the bank-link entry points on having a Google identity.
///
/// The aggregator Customer id is `sha256(email + salt)` — see
/// `SophtronConfig.deriveCustomerUniqueId` — so linking a bank needs a
/// signed-in email. Signing in is optional in both tiers now, which means a
/// Pro user can reach these buttons without one; the link flow would then run
/// all the way through and sync nothing, because `runSync` bails on a null
/// `bankCustomerId`. Say it up front instead.
///
/// Returns true when linking may proceed, and otherwise explains why not.
bool _canLinkBank(BuildContext context, WidgetRef ref) {
  if (ref.read(authProvider).email != null) return true;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        'Sign in from Profile first — a bank link is tied to your account.',
      ),
    ),
  );
  return false;
}

/// Reconnect from the broken bank section (or the bank info sheet) routes
/// into the existing Connect Bank Account flow with the institution
/// pre-selected so the user skips the picker.
///
/// `wasBroken` is true only when the user is coming from a connection
/// that's actually flagged `last_sync_status='failed'` - i.e. the red
/// "Connection lost" banner in the bank section. In that case the
/// credentials form shows an amber "your connection has expired" banner
/// to explain why we're asking for credentials again. Reconnect from the
/// bank info sheet (where the bank is working fine and the user just
/// wants to re-link, e.g. to update credentials) passes false so we
/// don't lie about the connection's state.
void _navigateToReconnect({
  required BuildContext context,
  required String bank,
  required String institutionId,
  required String? logoUrl,
  required bool wasBroken,
}) {
  final uri = Uri(
    path: '/add-bank',
    queryParameters: {
      'mode': 'reconnect',
      'institutionId': institutionId,
      'institutionName': bank,
      if (logoUrl != null && logoUrl.isNotEmpty) 'institutionLogo': logoUrl,
      if (wasBroken) 'wasBroken': '1',
    },
  );
  context.push(uri.toString());
}

/// Light tile background (#F0F0F0) is intentional - Sophtron's bank logos
/// vary in style (some are dark-on-transparent, some white-on-transparent,
/// some full-bleed colored). A dark tile made the dark-on-transparent
/// logos look shadowed/muddy. White-ish tile reads cleanly for all styles.
const Color _kBankLogoTile = Color(0xFFF0F0F0);

class _BankLogo extends StatelessWidget {
  const _BankLogo({required this.bank, this.logoUrl, this.size = 36});
  final String bank;
  final String? logoUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (logoUrl != null && logoUrl!.isNotEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: _kBankLogoTile,
          shape: BoxShape.circle,
        ),
        clipBehavior: Clip.antiAlias,
        child: CachedNetworkImage(
          imageUrl: logoUrl!,
          width: size,
          height: size,
          fit: BoxFit.contain,
          errorWidget: (_, _, _) => _BankLetterTile(bank: bank, size: size),
        ),
      );
    }
    return _BankLetterTile(bank: bank, size: size);
  }
}

/// Last-resort fallback when neither Sophtron's link-time logo nor the
/// v1 institution lookup gives us a URL. Just shows the first letter on
/// the same neutral tile so visual rhythm stays consistent.
class _BankLetterTile extends StatelessWidget {
  const _BankLetterTile({required this.bank, this.size = 36});
  final String bank;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: _kBankLogoTile,
        shape: BoxShape.circle,
      ),
      child: Text(
        bank.isEmpty ? '?' : bank.substring(0, 1).toUpperCase(),
        style: AppText.titleMd().copyWith(
          fontWeight: FontWeight.w700,
          color: AppColors.background,
        ),
      ),
    );
  }
}

/// Bottom sheet that opens when the user taps a bank header (not the
/// expand chevron). Shows bank metadata + Reconnect / Disconnect.
/// Reconnect = pre-select institution and reuse credentials form.
/// Disconnect = AlertDialog confirmation, then `client.deleteMember` +
/// local DB wipe scoped to this member.
void _openBankInfoSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String bank,
  required String? logoUrl,
  required String? memberId,
  required String? institutionId,
  required String? lastSyncedAt,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppPalette.of(context).sheet,
    builder: (sheetCtx) => _BankInfoSheet(
      bank: bank,
      logoUrl: logoUrl,
      memberId: memberId,
      institutionId: institutionId,
      lastSyncedAt: lastSyncedAt,
    ),
  );
}

class _BankInfoSheet extends ConsumerStatefulWidget {
  const _BankInfoSheet({
    required this.bank,
    required this.logoUrl,
    required this.memberId,
    required this.institutionId,
    required this.lastSyncedAt,
  });

  final String bank;
  final String? logoUrl;
  final String? memberId;
  final String? institutionId;
  final String? lastSyncedAt;

  @override
  ConsumerState<_BankInfoSheet> createState() => _BankInfoSheetState();
}

class _BankInfoSheetState extends ConsumerState<_BankInfoSheet> {
  // Set true once the user confirms Disconnect and the async work is
  // in flight. While true the sheet stays open with the
  // `AsyncActionButton` showing its spinner-prefixed loading state, and
  // PopScope blocks system back so the user can't escape mid-call and
  // wonder whether the action actually happened.
  bool _isDisconnecting = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final bank = widget.bank;
    final logoUrl = widget.logoUrl;
    final memberId = widget.memberId;
    final institutionId = widget.institutionId;
    final lastSyncedAt = widget.lastSyncedAt;
    return PopScope(
      // System back is blocked while a disconnect is mid-flight; the
      // user gets the in-place loading affordance instead. Re-enables
      // the moment the future settles (success or failure).
      canPop: !_isDisconnecting,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drag handle.
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
            Center(
              child: _BankLogo(bank: bank, logoUrl: logoUrl, size: 56),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                bank,
                style: AppText.titleLg().copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (lastSyncedAt != null) ...[
              const SizedBox(height: 4),
              Center(
                child: Text(
                  'Last synced ${_relativeDate(lastSyncedAt)}',
                  style: AppText.bodySm(color: palette.muted),
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                // Reconnect is disabled while a disconnect is mid-flight —
                // can't kick off two opposing state mutations on the same
                // bank at the same time.
                onPressed: (institutionId == null || _isDisconnecting)
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        _navigateToReconnect(
                          context: context,
                          bank: bank,
                          institutionId: institutionId,
                          logoUrl: logoUrl,
                          // Sheet is reached from a working bank header -
                          // user is re-linking proactively, not because
                          // we flagged the connection broken.
                          wasBroken: false,
                        );
                      },
                child: const Text('Reconnect'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 48,
              child: AsyncActionButton(
                outlined: true,
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.red,
                  side: BorderSide(color: palette.red),
                ),
                onPressed: memberId == null
                    ? null
                    : () => _runDisconnect(
                        context: context,
                        ref: ref,
                        bank: bank,
                        memberId: memberId,
                        onStart: () => setState(() => _isDisconnecting = true),
                        onSettled: () {
                          if (mounted) {
                            setState(() => _isDisconnecting = false);
                          }
                        },
                      ),
                loadingChild: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text('Disconnecting…'),
                  ],
                ),
                child: const Text('Disconnect'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Disconnecting removes this bank from SwipeWise and the data '
              'aggregator, and deletes synced transactions for it.',
              style: AppText.bodySm(color: palette.muted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// Reworked disconnect path. Differences vs the previous
/// `_confirmDisconnect`:
///
/// 1. The bank-info sheet **stays open** while the async work runs. The
///    [AsyncActionButton] inside the sheet drives the visible loading
///    state ("Disconnecting…" + spinner) so the latency is attributable
///    instead of disappearing into a snackbar 1-2 seconds later.
/// 2. The sheet only pops on **success**; on failure it stays open with
///    an error snackbar so the user can retry without re-navigating to
///    the bank header.
/// 3. The caller wires `onStart` / `onSettled` into the sheet's local
///    state so `PopScope(canPop: !_isDisconnecting)` blocks system back
///    while the request is mid-flight (matches the "stay locked" UX
///    decision documented in the audit follow-through).
///
/// The container is captured BEFORE the async work because the post-
/// success pop unmounts the sheet's `ref` — `ref.invalidate` after a
/// pop throws "Using ref when a widget is about to or has been unmounted
/// is unsafe." Messenger and palette are captured for the same reason.
Future<void> _runDisconnect({
  required BuildContext context,
  required WidgetRef ref,
  required String bank,
  required String memberId,
  required VoidCallback onStart,
  required VoidCallback onSettled,
}) async {
  final palette = AppPalette.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: palette.sheet,
      title: Text('Disconnect $bank?'),
      content: Text(
        'This will remove $bank from SwipeWise and delete all synced '
        'transactions. The bank link will also be removed from the data '
        'aggregator. This cannot be undone.',
        style: AppText.bodyMd(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: palette.red),
          child: const Text('Disconnect'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  final auth = ref.read(authProvider);
  final userId = auth.userId;
  final uniqueId = auth.bankCustomerId;
  if (userId == null || uniqueId == null) return;

  onStart();
  try {
    // Order: Sophtron API first, then local wipe. If the remote call
    // fails we leave local intact so the user can retry — better than
    // telling them it's gone when the link is still live at Sophtron.
    //
    // Compile-time gated even though free can never reach this sheet (it has
    // Guarded on entitlement even though a non-Pro user can never open this
    // sheet (they have no bank connections): the call would fail at the
    // aggregator anyway, and failing here keeps the reason legible.
    if (ref.read(proEntitlementProvider)) {
      final customerId = await BankClient().resolveCustomerId(uniqueId);
      await BankClient().deleteMember(
        customerId: customerId,
        memberId: memberId,
      );
    }
    await DataRepository().deleteMemberData(
      userId: userId,
      userInstitutionId: memberId,
    );
    // Refresh sync-derived providers so the Cards screen drops the
    // disconnected bank without waiting for the next sync. Use the
    // captured container, not `ref` — the sheet pop below unmounts it.
    for (final p in syncInvalidatedProviders) {
      container.invalidate(p);
    }
    // Mark settled BEFORE the pop so PopScope (canPop = !_isDisconnecting)
    // doesn't block the success pop.
    onSettled();
    if (context.mounted) Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text('Disconnected $bank')));
  } catch (e, st) {
    Log.e('cards-screen', 'disconnect failed for $memberId', e, st);
    onSettled();
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't disconnect $bank: $e")),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    this.valueColor,
    this.onEdit,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return GestureDetector(
      onTap: onEdit,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: palette.secondary,
          borderRadius: BorderRadius.circular(kRadiusS),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, style: AppText.labelSm())),
                if (onEdit != null)
                  Icon(LucideIcons.pencil, size: 11, color: palette.muted),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: AppText.monoMd(
                color: valueColor ?? AppColors.foreground,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardRow extends ConsumerWidget {
  const _CardRow({required this.card, this.hideUtilization = false});
  final CardSummary card;
  // True for orphan-bank rows: the utilization bar would mislead since
  // the balance/limit data is stale; the wireframe omits it.
  final bool hideUtilization;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final util = card.utilization;
    final utilColor = util == null
        ? palette.muted
        : (util < 0.30
              ? palette.green
              : (util < 0.70 ? palette.amber : palette.red));
    final available =
        card.creditAvailable ??
        (card.creditLimit != null ? card.creditLimit! - card.balance : null);
    final showIdentify = IdentifyCardBanner.shouldShowFor(card);

    final rowContainer = Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(
          color: showIdentify ? palette.amber : palette.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _openCardDetails(context, ref, card),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _CardArt(card: card),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                card.displayName,
                                style: AppText.titleMd().copyWith(fontSize: 15),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () =>
                                  showCardProductPicker(context, ref, card),
                              child: Icon(
                                LucideIcons.pencil,
                                size: 14,
                                color: palette.muted,
                              ),
                            ),
                            if (card.isDormant()) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.amberBg,
                                  borderRadius: BorderRadius.circular(
                                    kRadiusXs,
                                  ),
                                ),
                                child: Text(
                                  'unused 90d+',
                                  style: AppText.labelSm(
                                    color: palette.amber,
                                  ).copyWith(letterSpacing: 0, fontSize: 10),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '•••• ${card.lastFour ?? '----'}',
                          style: AppText.monoXs(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _MiniStat(
                        label: 'Used',
                        value: _money(card.balance),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniStat(
                        label: 'Limit',
                        value: _money(card.creditLimit),
                        onEdit: card.isCreditCard
                            ? () => _editLimit(context, ref, card)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MiniStat(
                        label: 'Available',
                        value: _money(available),
                        valueColor: palette.green,
                      ),
                    ),
                  ],
                ),
                if (util != null && !hideUtilization) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: util,
                      minHeight: 6,
                      backgroundColor: palette.secondary,
                      valueColor: AlwaysStoppedAnimation<Color>(utilColor),
                    ),
                  ),
                ],
                if (card.isCreditCard) ...[
                  const SizedBox(height: 10),
                  _DueDateLine(card: card),
                ],
                if (showIdentify) ...[
                  const SizedBox(height: 10),
                  IdentifyCardBanner(card: card),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return rowContainer;
  }
}

class _CardArt extends StatelessWidget {
  const _CardArt({required this.card});
  final CardSummary card;

  @override
  Widget build(BuildContext context) {
    final colors = _gradientFor(card.name);
    // Art preference order:
    //   1. `imageUrl` — the seed catalog's matched card image, only
    //      ever populated for identified credit-card products.
    //   2. `institutionLogo` — the bank's logo from Sophtron, populated
    //      for every Sophtron-sourced card (credit *and* debit). This
    //      is the only way debit accounts can show anything bank-
    //      specific: the seed catalog is credit-card-only, so debit
    //      accounts can never have an `imageUrl`. Falling through to
    //      the logo gives the row a recognisable identity instead of
    //      the generic gradient.
    //   3. The hashed gradient fallback for everything else (manual
    //      cards, unidentified credits with no logo).
    final art = card.imageUrl?.trim().isNotEmpty == true
        ? card.imageUrl
        : (card.institutionLogo?.trim().isNotEmpty == true
              ? card.institutionLogo
              : null);
    return Container(
      width: 56,
      height: 36,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(6),
        image: art != null
            ? DecorationImage(
                image: CachedNetworkImageProvider(art),
                fit: BoxFit.cover,
              )
            : null,
      ),
    );
  }

  static List<Color> _gradientFor(String name) {
    final h = name.hashCode.abs();
    final palette = [
      [const Color(0xFF1A3A6E), const Color(0xFF0A1A3A)],
      [const Color(0xFF8B6914), const Color(0xFF4A3508)],
      [const Color(0xFF6B1A1A), const Color(0xFF2A0808)],
      [const Color(0xFF1F4F2A), const Color(0xFF0A2A14)],
      [const Color(0xFF3D2E12), const Color(0xFF1A1208)],
    ];
    return palette[h % palette.length];
  }
}

void _openCardDetails(BuildContext context, WidgetRef ref, CardSummary card) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppPalette.of(context).sheet,
    // Pass the cardId, not the snapshot, so the sheet re-reads from
    // `cardsProvider` and refreshes in place when the user identifies
    // or renames the card via the in-sheet pencil — otherwise the
    // header keeps showing the pre-identification name until the user
    // dismisses and re-opens the sheet.
    builder: (_) => _CardDetailsSheet(cardId: card.cardId),
  );
}

Future<void> _editLimit(
  BuildContext context,
  WidgetRef ref,
  CardSummary card,
) async {
  final palette = AppPalette.of(context);
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: palette.sheet,
    builder: (_) => _EditCreditLimitSheet(card: card),
  );
  if (saved == true) {
    ref.invalidate(cardsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Limit updated')));
    }
  }
}

/// Wireframe `iXeJr` - modal card sheet with 3-tab body (Rewards/Credits/
/// Benefits) and an optional Delete button for manual cards.
///
/// Keyed on `cardId` rather than a [CardSummary] snapshot so the sheet
/// re-renders when the user identifies / renames / re-attaches the
/// card via the in-sheet pencil. The snapshot approach left the
/// header showing the pre-identification name until the user
/// dismissed and re-opened the sheet.
class _CardDetailsSheet extends ConsumerWidget {
  const _CardDetailsSheet({required this.cardId});
  final String cardId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
    final idx = cards.indexWhere((c) => c.cardId == cardId);
    if (idx < 0) {
      // Card disappeared while the sheet was open (rare: an in-flight
      // sync dropped its institution). Render an empty shell — caller
      // will pop the sheet on next frame via cardsProvider's update.
      return const SizedBox.shrink();
    }
    final card = cards[idx];
    final perksAsync = ref.watch(cardPerksProvider(card.cardId));
    final rewardsAsync = ref.watch(cardRewardsByCardProvider(card.cardId));
    final perks = perksAsync.value ?? const <CardPerk>[];
    final rewards = rewardsAsync.value ?? const <WalletRewardRow>[];
    final credits = perks.where((p) => p.isCredit).toList();
    final benefits = perks.where((p) => p.isBenefit).toList();
    final available =
        card.creditAvailable ??
        (card.creditLimit != null ? card.creditLimit! - card.balance : null);

    return DefaultTabController(
      length: 3,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      card.displayName,
                      style: AppText.titleLg(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Universal rename - opens the Card Product Picker so
                  // the user can re-identify (preferred path: keeps
                  // rewards/perks attached). Manual freeform rename is
                  // still reachable from the picker's fallback link when
                  // the bank has no seed catalog entries.
                  IconButton(
                    icon: Icon(
                      LucideIcons.pencil,
                      size: 16,
                      color: palette.muted,
                    ),
                    onPressed: () => showCardProductPicker(context, ref, card),
                    tooltip: card.isExplicitlyIdentified
                        ? 'Re-identify card'
                        : 'Identify card',
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '•••• ${card.lastFour ?? '----'}',
                    style: AppText.monoXs(),
                  ),
                ],
              ),
              if (IdentifyCardBanner.shouldShowFor(card)) ...[
                const SizedBox(height: 12),
                IdentifyCardBanner(card: card),
              ],
              const SizedBox(height: 16),
              _StatStrip(
                balance: card.balance,
                limit: card.creditLimit,
                available: available,
              ),
              const SizedBox(height: 12),
              TabBar(
                labelColor: AppColors.foreground,
                unselectedLabelColor: palette.muted,
                indicatorColor: AppColors.primary,
                indicatorSize: TabBarIndicatorSize.label,
                labelStyle: AppText.bodyMd().copyWith(
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: AppText.bodyMd(),
                tabs: [
                  _TabLabel(label: 'Rewards', count: rewards.length),
                  _TabLabel(label: 'Credits', count: credits.length),
                  _TabLabel(label: 'Benefits', count: benefits.length),
                ],
              ),
              Flexible(
                child: TabBarView(
                  children: [
                    _RewardsTab(
                      rewards: rewards,
                      async: rewardsAsync,
                      card: card,
                    ),
                    _CreditsTab(credits: credits, async: perksAsync),
                    _BenefitsTab(benefits: benefits, async: perksAsync),
                  ],
                ),
              ),
              if (card.source == 'manual') ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => _confirmDelete(context, ref, card),
                  icon: const Icon(LucideIcons.trash2, size: 18),
                  label: const Text('Delete card'),
                  style: TextButton.styleFrom(foregroundColor: palette.red),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  CardSummary card,
) async {
  final palette = AppPalette.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: palette.sheet,
      title: const Text('Delete card?'),
      content: Text(
        // No "synced transactions are not affected" tail: free has no synced
        // transactions to reassure anyone about, and in Pro the sentence was
        // answering a question the dialog doesn't raise.
        'This removes "${card.displayName}${card.lastFour != null ? ' ••${card.lastFour}' : ''}" from your cards.',
        style: AppText.bodyMd(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: palette.red),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final userId = ref.read(authProvider).userId;
  if (userId == null) return;
  await ref.read(dataRepositoryProvider).deleteManualCard(userId, card.cardId);
  ref.invalidate(cardsProvider);
  if (context.mounted) Navigator.pop(context);
}

/// Removes every card in a manual group — the equivalent of Disconnect for a
/// bank the user typed in rather than linked.
///
/// Deliberately loops [deleteManualCard] rather than reusing the institution
/// -scoped wipe that Disconnect uses. That wipe exists to be re-run by a sync
/// which immediately re-inserts the same cards, so it spares `card_overrides`
/// on purpose; here nothing is coming back, and the per-card path is what the
/// user already gets from the card sheet. Same end state, one primitive.
Future<void> _confirmDeleteManualGroup(
  BuildContext context,
  WidgetRef ref,
  String label,
  List<CardSummary> cards,
) async {
  final palette = AppPalette.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final n = cards.length;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: palette.sheet,
      title: Text('Delete $label?'),
      content: Text(
        n == 1
            ? 'This removes the 1 card you added under $label.'
            : 'This removes all $n cards you added under $label.',
        style: AppText.bodyMd(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: palette.red),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final userId = ref.read(authProvider).userId;
  if (userId == null) return;
  final repo = ref.read(dataRepositoryProvider);
  try {
    for (final c in cards) {
      await repo.deleteManualCard(userId, c.cardId);
    }
    ref.invalidate(cardsProvider);
    messenger.showSnackBar(
      SnackBar(content: Text(n == 1 ? 'Removed $label' : 'Removed $n cards')),
    );
  } catch (e, st) {
    Log.e('cards-screen', 'manual group delete failed for $label', e, st);
    messenger.showSnackBar(
      SnackBar(content: Text("Couldn't remove $label: $e")),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.label, required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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
      ),
    );
  }
}

class _StatStrip extends StatelessWidget {
  const _StatStrip({
    required this.balance,
    required this.limit,
    required this.available,
  });

  final double balance;
  final double? limit;
  final double? available;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusM),
      ),
      child: Row(
        children: [
          _statCell(context, 'Used', _money(balance)),
          _divider(palette),
          _statCell(context, 'Limit', _money(limit)),
          _divider(palette),
          _statCell(
            context,
            'Available',
            _money(available),
            color: palette.green,
          ),
        ],
      ),
    );
  }

  Widget _statCell(
    BuildContext context,
    String label,
    String value, {
    Color? color,
  }) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: AppText.labelSm()),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: AppText.monoMd(
                color: color ?? AppColors.foreground,
              ).copyWith(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(AppPalette palette) =>
      Container(width: 1, height: 32, color: palette.border);
}

class _RewardsTab extends StatelessWidget {
  const _RewardsTab({
    required this.rewards,
    required this.async,
    required this.card,
  });
  final List<WalletRewardRow> rewards;
  final AsyncValue async;
  final CardSummary card;

  @override
  Widget build(BuildContext context) {
    // Locked-rewards empty state: when a card needs identification, the
    // generic "no rewards yet" copy is misleading - rewards are
    // unavailable because we don't know the product. Surface that
    // directly with a CTA to the picker so the empty tab is also an
    // entry point to the Identify flow.
    final empty = IdentifyCardBanner.shouldShowFor(card)
        ? _LockedRewardsEmpty(card: card)
        : const _TabEmpty(
            icon: LucideIcons.gift,
            message: 'No rewards data for this card yet',
          );
    return _TabSlot(
      async: async,
      empty: empty,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: rewards.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, indent: 0, color: AppPalette.of(context).border),
        itemBuilder: (_, i) {
          final r = rewards[i];
          final label = r.label;
          final amount = r.amount ?? 0;
          final currency = r.currency ?? '%';
          // `is_baseline = 1` is the explicit catch-all marker now; the
          // legacy substring on the label stays as a defensive fallback.
          final isCatchAll =
              r.isBaseline ||
              label.toLowerCase().contains('everywhere') ||
              label.toLowerCase().contains('other');
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: AppText.bodyMd()),
                      // "top N spend categories" earns reach only a subset of the
                      // listed categories — show the caveat so the rates don't read
                      // as earned on everything at once.
                      if (r.earnConstraint != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            r.earnConstraint!,
                            style: AppText.bodySm(
                              color: AppPalette.of(context).muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Text(
                  _formatRate(amount, currency),
                  style: AppText.monoMd(
                    color: isCatchAll
                        ? AppColors.foreground
                        : AppPalette.of(context).green,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CreditsTab extends StatelessWidget {
  const _CreditsTab({required this.credits, required this.async});
  final List<CardPerk> credits;
  final AsyncValue async;

  @override
  Widget build(BuildContext context) {
    return _TabSlot(
      async: async,
      empty: const _TabEmpty(
        icon: LucideIcons.receipt,
        message: 'No statement credits for this card',
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: credits.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: AppPalette.of(context).border),
        itemBuilder: (_, i) => _CreditRow(perk: credits[i]),
      ),
    );
  }
}

class _CreditRow extends StatelessWidget {
  const _CreditRow({required this.perk});
  final CardPerk perk;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final freq = perk.frequency?.toLowerCase();
    String? freqLabel;
    if (freq == 'monthly') freqLabel = 'Monthly';
    if (freq == 'annual' || freq == 'yearly') freqLabel = 'Annual';
    if (freq == 'every four years') freqLabel = 'Every Four Years';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(perk.title ?? 'Statement credit', style: AppText.bodyMd()),
                if (_subline(perk) != null) ...[
                  const SizedBox(height: 4),
                  Text(_subline(perk)!, style: AppText.bodySm()),
                ],
                if (perk.dateRedeemed != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Last used ${_formatDate(perk.dateRedeemed)}',
                    style: AppText.bodySm(
                      color: palette.muted,
                    ).copyWith(fontStyle: FontStyle.italic),
                  ),
                ],
              ],
            ),
          ),
          if (freqLabel != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: palette.greenBg,
                borderRadius: BorderRadius.circular(kRadiusPill),
              ),
              child: Text(
                freqLabel,
                style: AppText.labelSm(
                  color: palette.green,
                ).copyWith(fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  static String? _subline(CardPerk p) {
    if (p.dateRedeemed != null && p.redeemedAmount != null) {
      return 'Redeemed ${_formatDate(p.dateRedeemed)} · ${NumberFormat.simpleCurrency().format(p.redeemedAmount)}';
    }
    if (p.calendarMaxYearAmount != null) {
      final freq = p.frequency?.toLowerCase();
      final period = (freq == 'monthly')
          ? 'mo'
          : (freq == 'annual' || freq == 'yearly')
          ? 'yr'
          : (freq == 'every four years' ? '4 yrs' : 'yr');
      return '${NumberFormat.simpleCurrency(decimalDigits: 0).format(p.calendarMaxYearAmount)} / $period';
    }
    if (p.expirationDate != null) {
      return 'Expires ${_formatDate(p.expirationDate)}';
    }
    return p.description;
  }

  static String _formatDate(String? iso) {
    if (iso == null) return '-';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat('MMM d, y').format(dt.toLocal());
  }
}

class _BenefitsTab extends StatelessWidget {
  const _BenefitsTab({required this.benefits, required this.async});
  final List<CardPerk> benefits;
  final AsyncValue async;

  @override
  Widget build(BuildContext context) {
    return _TabSlot(
      async: async,
      empty: const _TabEmpty(
        icon: LucideIcons.shield,
        message: 'No benefits listed for this card',
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: benefits.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, color: AppPalette.of(context).border),
        itemBuilder: (_, i) {
          final b = benefits[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.title ?? 'Benefit', style: AppText.bodyMd()),
                if (b.description != null) ...[
                  const SizedBox(height: 4),
                  Text(b.description!, style: AppText.bodySm()),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TabSlot extends StatelessWidget {
  const _TabSlot({
    required this.async,
    required this.empty,
    required this.child,
  });

  final AsyncValue async;
  final Widget empty;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return async.when(
      data: (data) {
        final isEmpty = data is List && data.isEmpty;
        return isEmpty ? empty : child;
      },
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('$e', style: AppText.bodySm()),
        ),
      ),
    );
  }
}

class _TabEmpty extends StatelessWidget {
  const _TabEmpty({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: palette.muted.withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            Text(message, style: AppText.bodySm(), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Locked-rewards empty state shown on the Rewards tab when the card
/// needs identification. Replaces the generic "no rewards yet" so users
/// understand rewards are unavailable *because the product is unknown*,
/// and lands them in the picker with one tap.
class _LockedRewardsEmpty extends ConsumerWidget {
  const _LockedRewardsEmpty({required this.card});
  final CardSummary card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.lock, size: 32, color: palette.muted),
            const SizedBox(height: 10),
            Text(
              'Rewards unavailable',
              style: AppText.titleMd().copyWith(fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              'Identify this card to see rewards rates, category bonuses, and perks.',
              style: AppText.bodySm(color: palette.muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => showCardProductPicker(context, ref, card),
              icon: const Icon(LucideIcons.scanSearch, size: 16),
              label: const Text('Identify card'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wireframe `XnuHS` - small modal for editing a manual card's credit limit.
class _EditCreditLimitSheet extends ConsumerStatefulWidget {
  const _EditCreditLimitSheet({required this.card});
  final CardSummary card;

  @override
  ConsumerState<_EditCreditLimitSheet> createState() =>
      _EditCreditLimitSheetState();
}

class _EditCreditLimitSheetState extends ConsumerState<_EditCreditLimitSheet> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.card.creditLimit == null
        ? ''
        : widget.card.creditLimit!.toStringAsFixed(0),
  );
  bool _saving = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  double? get _parsed => double.tryParse(_ctrl.text.replaceAll(',', ''));

  bool get _canSave {
    final p = _parsed;
    if (p == null || p <= 0) return false;
    return p != widget.card.creditLimit;
  }

  Future<void> _save() async {
    final value = _parsed;
    if (value == null) return;
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(dataRepositoryProvider)
          .updateManualCreditLimit(
            userId,
            widget.card.cardId,
            limit: value,
            name: widget.card.name,
            lastFour: widget.card.lastFour,
            provider: widget.card.provider,
            accountType: widget.card.accountType,
          );
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Edit credit limit', style: AppText.titleLg()),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: false,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d,]')),
              ],
              onChanged: (_) => setState(() {}),
              style: AppText.monoLg().copyWith(fontSize: 32),
              decoration: const InputDecoration(
                prefixText: '\$ ',
                prefixStyle: TextStyle(fontSize: 28),
                hintText: '0',
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: !_canSave || _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: AppColors.onPrimary,
                        ),
                      )
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(child: _skel(palette, h: 64)),
            const SizedBox(width: 10),
            Expanded(child: _skel(palette, h: 64)),
            const SizedBox(width: 10),
            Expanded(child: _skel(palette, h: 64)),
          ],
        ),
        const SizedBox(height: 16),
        _skel(palette, h: 44),
        const SizedBox(height: 20),
        for (var i = 0; i < 3; i++) ...[
          _skel(palette, h: 120),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _skel(AppPalette palette, {required double h}) {
    return Container(
      height: h,
      decoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusS),
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
            Icon(
              LucideIcons.triangleAlert,
              size: 48,
              color: palette.muted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              'Could not load cards',
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

class _EmptyBody extends ConsumerWidget {
  const _EmptyBody({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(proEntitlementProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.creditCard,
              size: 56,
              color: palette.muted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              isPro ? 'No banks linked yet' : 'No cards yet',
              style: AppText.titleMd(),
            ),
            const SizedBox(height: 8),
            Text(
              isPro
                  ? 'Connect a bank or add a card manually to get started.'
                  : 'Add the cards you carry and we’ll tell you which one to '
                        'use at every store.',
              style: AppText.bodySm(),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              child: ElevatedButton.icon(
                onPressed: () {
                  if (!isPro) {
                    context.push('/add-cards');
                  } else if (_canLinkBank(context, ref)) {
                    context.push('/add-bank');
                  }
                },
                icon: const Icon(LucideIcons.plus, size: 18),
                label: Text(isPro ? 'Add bank' : 'Add cards'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncFailedBody extends StatelessWidget {
  const _SyncFailedBody({required this.palette, required this.onRetry});
  final AppPalette palette;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.triangleAlert,
              size: 56,
              color: palette.muted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text("We couldn't finish setting up", style: AppText.titleMd()),
            const SizedBox(height: 8),
            Text(
              'Your bank linked, but the sync ran into a problem. '
              'Check your connection and try again.',
              style: AppText.bodySm(),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 200,
              child: ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(LucideIcons.refreshCw, size: 18),
                label: const Text('Try again'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilteredEmpty extends StatelessWidget {
  const _FilteredEmpty({required this.palette});
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(
            LucideIcons.searchX,
            size: 36,
            color: palette.muted.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),
          Text('No cards match', style: AppText.bodyMd(color: palette.muted)),
        ],
      ),
    );
  }
}

String _money(double? v) {
  if (v == null) return '-';
  return NumberFormat.simpleCurrency(decimalDigits: 0).format(v);
}

String _formatRate(double amount, String currency) {
  if (currency == 'PERCENT' || currency == '%' || currency.isEmpty) {
    return '${amount.toStringAsFixed(amount.truncateToDouble() == amount ? 0 : 1)}%';
  }
  return '${amount.toStringAsFixed(amount.truncateToDouble() == amount ? 0 : 1)}x';
}

/// Wireframe `cD1A9` — the per-card due-date line.
///
/// Two states by design: a set date shows how soon it falls (amber when it's
/// close), and an unset one is a quiet "Add due date" affordance — **not** an
/// error. Most cards will never have one, because banks don't supply a due date
/// and the user has to type it.
class _DueDateLine extends ConsumerWidget {
  const _DueDateLine({required this.card});
  final CardSummary card;

  static String ordinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    return switch (day % 10) {
      1 => '${day}st',
      2 => '${day}nd',
      3 => '${day}rd',
      _ => '${day}th',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final dueDay = card.dueDay;

    // Wireframe: a calendar icon then the text, left-aligned on its own line.
    Widget line(List<InlineSpan> spans, Color iconColor) => InkWell(
      onTap: () => showDueDateSheet(context, ref, card),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          // Centered on its own line under the card's stats.
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.calendar, size: 13, color: iconColor),
            const SizedBox(width: 6),
            Text.rich(
              TextSpan(
                style: AppText.bodySm(color: palette.muted),
                children: spans,
              ),
            ),
          ],
        ),
      ),
    );

    if (dueDay == null) {
      return line([const TextSpan(text: 'Add due date')], palette.muted);
    }
    final days = PaymentReminderService.daysUntilDue(dueDay, DateTime.now());
    // The urgency clause is ALWAYS accent-coloured — it is the part the eye is
    // meant to catch. Only the date itself stays in the body colour.
    return line([
      TextSpan(text: 'Due ${ordinal(dueDay)}', style: AppText.bodySm()),
      TextSpan(
        text: days == 0 ? ' · today' : ' · in $days day${days == 1 ? '' : 's'}',
        style: AppText.bodySm(color: AppColors.primary),
      ),
    ], palette.muted);
  }
}
