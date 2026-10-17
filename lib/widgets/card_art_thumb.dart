import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';

import '../models/card.dart';
import '../theme/app_theme.dart';

/// A small card-art rectangle: the catalog image, else the bank's logo (the
/// only bank-specific art a debit/unidentified card ever has), else a
/// name-derived gradient — the same preference order as the Cards screen.
class CardArtThumb extends StatelessWidget {
  const CardArtThumb({
    super.key,
    required this.card,
    this.width = 44,
    this.height = 28,
  });

  final CardSummary card;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final art = card.imageUrl?.trim().isNotEmpty == true
        ? card.imageUrl
        : (card.institutionLogo?.trim().isNotEmpty == true
              ? card.institutionLogo
              : null);
    final gradient = LinearGradient(
      colors: _gradientFor(card.name),
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
    return Container(
      width: width,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: art != null ? null : gradient,
      ),
      child: art != null
          ? CachedNetworkImage(
              imageUrl: art,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) =>
                  DecoratedBox(decoration: BoxDecoration(gradient: gradient)),
            )
          : null,
    );
  }

  static List<Color> _gradientFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('platinum')) {
      return [const Color(0xFF1E293B), const Color(0xFF475569)];
    }
    if (n.contains('sapphire')) {
      return [const Color(0xFF1E3A8A), const Color(0xFF3B82F6)];
    }
    if (n.contains('gold')) {
      return [const Color(0xFF92400E), const Color(0xFFD97706)];
    }
    if (n.contains('venture') || n.contains('capital one')) {
      return [const Color(0xFF7F1D1D), const Color(0xFFDC2626)];
    }
    if (n.contains('discover')) {
      return [const Color(0xFFC2410C), const Color(0xFFFB923C)];
    }
    if (n.contains('freedom')) {
      return [const Color(0xFF2563EB), const Color(0xFF60A5FA)];
    }
    if (n.contains('costco') || n.contains('visa')) {
      return [const Color(0xFFEA580C), const Color(0xFFF97316)];
    }
    return [AppColors.primary, AppColors.primary.withValues(alpha: 0.7)];
  }
}
