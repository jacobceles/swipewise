import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../api/data_repository.dart';
import '../../providers/auth_provider.dart';
import '../../providers/data_providers.dart';
import '../../theme/app_theme.dart';
import '../../util/logger.dart';

/// Single orphan group available for re-attaching to a newly linked
/// card. Matches `DataRepository.findOrphanTransactionGroupsForLastFour`
/// shape but lifted out of the record-type signature for readability.
class OrphanReconciliationGroup {
  const OrphanReconciliationGroup({
    required this.orphanCardId,
    required this.institutionName,
    required this.txCount,
    required this.earliest,
    required this.latest,
  });

  final String orphanCardId;
  final String? institutionName;
  final int txCount;
  final DateTime? earliest;
  final DateTime? latest;
}

/// Modal bottom sheet shown after the user just linked / reconnected a
/// bank, when we detect orphan transactions on a previous version of
/// that card (same last four, same normalized bank). Two layouts:
///   - Single match: one summary card, "Attach to this card" CTA.
///   - Multi match (>= 2): stacked summary cards, "Attach all" CTA.
///
/// Returns `true` from `showModalBottomSheet` when the user accepted
/// the attach, `false` for "Keep as historical", `null` if dismissed by
/// drag. The caller is responsible for invalidating sync-dependent
/// providers after attach.
class ReconciliationSheet extends ConsumerWidget {
  const ReconciliationSheet({
    super.key,
    required this.newCardId,
    required this.newBankName,
    required this.newLastFour,
    required this.groups,
  });

  final String newCardId;
  final String newBankName;
  final String newLastFour;
  final List<OrphanReconciliationGroup> groups;

  bool get _isMulti => groups.length >= 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final headlineCopy = _isMulti
        ? 'We found ${groups.length} sets of transactions on $newBankName '
              '••$newLastFour cards you previously linked. Attach them all to '
              'your newly linked card?'
        : 'We found ${groups.first.txCount} transactions on a $newBankName '
              '••$newLastFour card you previously linked. Attach them to your '
              'newly linked $newBankName ••$newLastFour so all your spending '
              'shows in one place?';
    return Padding(
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
          const SizedBox(height: 16),
          Text(
            'Attach your existing history?',
            style: AppText.titleLg().copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(headlineCopy, style: AppText.bodySm(color: palette.muted)),
          const SizedBox(height: 20),
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _GroupSummaryCard(group: groups[i], palette: palette),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: () => _attach(context, ref),
              child: Text(_isMulti ? 'Attach all' : 'Attach to this card'),
            ),
          ),
          if (_isMulti) ...[
            const SizedBox(height: 6),
            TextButton(
              onPressed: () => _showChooseIndividuallyComingSoon(context),
              child: Text(
                'Or, choose individually →',
                style: AppText.bodyMd(color: AppColors.primary),
              ),
            ),
          ],
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              _isMulti ? 'Keep all as historical' : 'Keep as historical',
              style: AppText.bodyMd(color: palette.muted),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Attaching is reversible — you can remove these cards later '
            'from the bank section.',
            style: AppText.bodySm(color: palette.muted).copyWith(fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<void> _attach(BuildContext context, WidgetRef ref) async {
    final userId = ref.read(authProvider).userId;
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    if (userId == null) {
      Navigator.of(context).pop(false);
      return;
    }
    Navigator.of(context).pop(true);
    var moved = 0;
    try {
      for (final g in groups) {
        moved += await DataRepository().mergeOrphanTransactionsToCard(
          userId: userId,
          orphanCardId: g.orphanCardId,
          newCardId: newCardId,
        );
      }
      for (final p in syncInvalidatedProviders) {
        container.invalidate(p);
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Attached $moved transaction${moved == 1 ? '' : 's'} '
            'to $newBankName ••$newLastFour',
          ),
        ),
      );
    } catch (e, st) {
      Log.e('reconciliation', 'attach failed for $newCardId', e, st);
      messenger.showSnackBar(
        SnackBar(content: Text("Couldn't attach history: $e")),
      );
    }
  }

  void _showChooseIndividuallyComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Per-row selection coming soon'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}

class _GroupSummaryCard extends StatelessWidget {
  const _GroupSummaryCard({required this.group, required this.palette});

  final OrphanReconciliationGroup group;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final dateRange = _formatDateRange(group.earliest, group.latest);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.history, size: 22, color: palette.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${group.txCount} transaction${group.txCount == 1 ? '' : 's'}',
                  style: AppText.bodyMd().copyWith(fontWeight: FontWeight.w600),
                ),
                if (dateRange != null) ...[
                  const SizedBox(height: 2),
                  Text(dateRange, style: AppText.bodySm(color: palette.muted)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String? _formatDateRange(DateTime? earliest, DateTime? latest) {
    if (earliest == null && latest == null) return null;
    final fmt = DateFormat('MMM d, y');
    if (earliest != null && latest != null) {
      if (earliest.year == latest.year && earliest.month == latest.month) {
        return fmt.format(earliest);
      }
      return 'From ${fmt.format(earliest)} to ${fmt.format(latest)}';
    }
    return fmt.format((earliest ?? latest)!);
  }
}
