import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme/app_theme.dart';

/// Wireframe `dIOA0` - close-X + centered title. Used by every Add Bank
/// sub-view and by Add Card. Implements `PreferredSizeWidget` so it can
/// drop into a `Scaffold.appBar` slot.
class ConnectBankAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ConnectBankAppBar({
    super.key,
    required this.title,
    this.onClose,
    this.onBack,
  });

  final String title;
  final VoidCallback? onClose;
  final VoidCallback? onBack;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 56,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (onBack != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(LucideIcons.chevronLeft, size: 24),
                    onPressed: onBack,
                    color: AppColors.foreground,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              Align(
                alignment: Alignment.center,
                child: Text(
                  title,
                  style: AppText.titleMd().copyWith(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const Icon(LucideIcons.x, size: 24),
                  onPressed: onClose ?? () => Navigator.of(context).maybePop(),
                  color: AppColors.foreground,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Centered step header shared by every Add Bank / manual-card-add screen:
/// a small uppercase step label, the bank's logo (falling back to an
/// initial-letter avatar when no logo URL is available or it fails to
/// load), and the bank name. Wireframe: Connect Bank Account screens.
class BankStepHeader extends StatelessWidget {
  const BankStepHeader({
    super.key,
    required this.label,
    required this.bankName,
    this.logoUrl,
  });

  /// Small uppercase label above the avatar, e.g. "CONNECTING TO".
  final String label;
  final String bankName;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(label, style: AppText.labelSm()),
      const SizedBox(height: 12),
      Container(
        width: 56,
        height: 56,
        alignment: Alignment.center,
        // Light tile (`AppColors.bankLogoTile`), not the dark `secondary` —
        // Sophtron logos are often dark-on-transparent and disappear/look
        // shadowed against a dark background. Same tile the institution
        // picker uses. The fallback letter needs a dark color to read
        // against it — `AppText.titleLg()`'s default (`foreground`, white)
        // would be invisible here.
        decoration: const BoxDecoration(
          color: AppColors.bankLogoTile,
          shape: BoxShape.circle,
        ),
        child: (logoUrl == null || logoUrl!.isEmpty)
            ? Text(
                bankName.isEmpty ? '?' : bankName.substring(0, 1).toUpperCase(),
                style: AppText.titleLg(color: AppColors.onPrimary),
              )
            : ClipOval(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: CachedNetworkImage(
                    imageUrl: logoUrl!,
                    width: 56,
                    height: 56,
                    fit: BoxFit.contain,
                    errorWidget: (_, _, _) => Text(
                      bankName.isEmpty
                          ? '?'
                          : bankName.substring(0, 1).toUpperCase(),
                      style: AppText.titleLg(color: AppColors.onPrimary),
                    ),
                  ),
                ),
              ),
      ),
      const SizedBox(height: 10),
      Text(bankName, style: AppText.titleLg()),
    ],
  );
}
