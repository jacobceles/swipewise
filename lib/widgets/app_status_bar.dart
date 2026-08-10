import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme/app_theme.dart';

/// Pencil-wireframe status bar - fixed 9:41 time + signal/wifi/battery glyphs.
/// On real devices the OS draws its own status bar via `SafeArea`. This widget
/// is here only for screenshot diffing against the wireframe; production
/// scaffolds should rely on `SafeArea(top: true)` and not insert this.
class AppStatusBar extends StatelessWidget {
  const AppStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '9:41',
              style: AppText.titleMd(
                color: AppColors.foreground,
              ).copyWith(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(LucideIcons.signal, size: 16, color: AppColors.foreground),
                SizedBox(width: 6),
                Icon(LucideIcons.wifi, size: 16, color: AppColors.foreground),
                SizedBox(width: 6),
                Icon(
                  LucideIcons.batteryFull,
                  size: 16,
                  color: AppColors.foreground,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
