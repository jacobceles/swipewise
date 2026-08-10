import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/transaction.dart';
import '../theme/app_theme.dart';
import '../util/category_icons.dart';

/// Wireframe `aYUXN` - one row per transaction in the Transactions, Category
/// Detail, and Merchant Detail lists. The amount is rendered in JetBrains
/// Mono; credits get the green token, debits keep the foreground.
class TransactionRow extends StatelessWidget {
  const TransactionRow({super.key, required this.tx, this.onTap});

  final Transaction tx;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    // Direction comes from `type` ('CREDIT' | 'DEBIT'), NOT amount sign -
    // upsertTransactions stores amount as ABS magnitude.
    final isCredit = tx.type == 'CREDIT';
    final amountStr = _formatAmount(tx.amount, isCredit);

    final iconData = iconForCategory(tx.category);
    final colors = colorsForCategory(tx.category);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.bgColor,
                shape: BoxShape.circle,
              ),
              child: Icon(iconData, size: 18, color: colors.iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          tx.merchant ?? tx.name ?? 'Unknown',
                          style: AppText.titleMd().copyWith(fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (tx.category != null && tx.category!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          tx.category!,
                          style: AppText.bodySm().copyWith(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: palette.muted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subline(tx),
                    style: AppText.bodySm(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              amountStr,
              style: AppText.monoMd(
                color: isCredit ? palette.green : AppColors.foreground,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  static String _subline(Transaction tx) {
    final date = _formatDate(tx.postedAt);
    // Prefer the JOIN-resolved label so renames take effect immediately
    // without sync needing to chase every `transactions.card` snapshot.
    final card = tx.cardLabel ?? '';
    if (date.isEmpty) return card;
    if (card.isEmpty) return date;
    return '$date · $card';
  }

  static String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    return DateFormat.MMMd().format(dt.toLocal());
  }

  static String _formatAmount(double? amount, bool isCredit) {
    final v = (amount ?? 0).abs();
    final fmt = NumberFormat.simpleCurrency(decimalDigits: 2);
    final formatted = fmt.format(v);
    return isCredit ? '+$formatted' : '-$formatted';
  }
}
