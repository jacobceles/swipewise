import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Wireframe `j0RPuk` - small bordered card with a tiny label above a
/// JetBrains Mono value. Optional `delta` paints below the value in a
/// state color (green for positive, red for negative, amber for neutral).
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.delta,
    this.deltaColor,
    this.valueColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
  });

  final String label;
  final String value;
  final String? delta;
  final Color? deltaColor;
  final Color? valueColor;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(kRadiusM),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label.toUpperCase(), style: AppText.labelSm()),
          const SizedBox(height: 6),
          Text(
            value,
            style: AppText.monoLg(
              color: valueColor ?? AppColors.foreground,
            ).copyWith(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          if (delta != null) ...[
            const SizedBox(height: 4),
            Text(
              delta!,
              style: AppText.monoXs(color: deltaColor ?? palette.muted),
            ),
          ],
        ],
      ),
    );
  }
}
