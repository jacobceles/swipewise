import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import 'profile_ui.dart';

/// Wireframe `C6hqRe` — version, updates, privacy policy.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  /// The hosted policy, deliberately not a bundled copy: one source, at the
  /// URL Google Play already points at, cannot drift.
  static final _privacy = Uri.parse(
    'https://jacobcelestine.com/swipewise/privacy_policy.html',
  );

  // externalApplication so Android routes the link to the Play Store app.
  static final _store = Uri.parse(
    'https://play.google.com/store/apps/details?id=com.appsoflife.swipewise',
  );

  Future<void> _open(BuildContext context, Uri uri, String what) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't open $what")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final external = Icon(
      LucideIcons.externalLink,
      size: 18,
      color: palette.muted,
    );
    return SettingsPage(
      title: 'About',
      children: [
        const SizedBox(height: 12),
        Center(
          child: Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              LucideIcons.creditCard,
              size: 30,
              color: AppColors.onPrimary,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'SwipeWise',
          textAlign: TextAlign.center,
          style: AppText.titleLg().copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (_, snap) => Text(
            snap.hasData
                ? 'Version ${snap.data!.version} (${snap.data!.buildNumber})'
                : '',
            textAlign: TextAlign.center,
            style: rowSubtitleStyle(palette),
          ),
        ),
        const SizedBox(height: kGroupGap),
        SettingsGroup(
          children: [
            SettingsRow(
              icon: LucideIcons.download,
              title: 'Check for updates',
              subtitle: 'Opens Google Play',
              trailing: external,
              onTap: () => _open(context, _store, 'the Play Store'),
            ),
            SettingsRow(
              icon: LucideIcons.shieldCheck,
              title: 'Privacy policy',
              trailing: external,
              onTap: () => _open(context, _privacy, 'the privacy policy'),
            ),
          ],
        ),
      ],
    );
  }
}
