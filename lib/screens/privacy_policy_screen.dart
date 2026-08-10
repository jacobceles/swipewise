import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../theme/app_theme.dart';

/// Wireframe `BaNCW` - Bundled markdown privacy policy, styled via the
/// `AppText` ramp.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(LucideIcons.chevronLeft, size: 24),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Privacy Policy', style: AppText.titleLg()),
      ),
      body: FutureBuilder<String>(
        future: rootBundle.loadString('docs/PRIVACY.md'),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.triangleAlert,
                      size: 36,
                      color: palette.red,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Could not load privacy policy: ${snap.error}',
                      style: AppText.bodySm(color: palette.muted),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return Markdown(
            data: snap.data ?? '',
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            selectable: true,
            styleSheet: _styleSheet(context, palette),
          );
        },
      ),
    );
  }

  MarkdownStyleSheet _styleSheet(BuildContext context, AppPalette palette) {
    final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
    return base.copyWith(
      p: AppText.bodyMd().copyWith(height: 1.55, fontSize: 14),
      h1: AppText.displayLg().copyWith(fontSize: 24, height: 1.3),
      h2: AppText.titleLg().copyWith(fontSize: 18, height: 1.3),
      h3: AppText.titleMd().copyWith(fontSize: 15, height: 1.3),
      em: AppText.bodySm(
        color: palette.muted,
      ).copyWith(fontStyle: FontStyle.italic),
      strong: AppText.bodyMd().copyWith(fontWeight: FontWeight.w700),
      a: AppText.bodyMd(
        color: AppColors.primary,
      ).copyWith(decoration: TextDecoration.underline),
      code: GoogleFonts.jetBrainsMono(
        fontSize: 13,
        backgroundColor: palette.secondary,
        color: AppColors.foreground,
      ),
      tableHead: AppText.bodyMd().copyWith(fontWeight: FontWeight.w700),
      tableBody: AppText.bodySm().copyWith(height: 1.4),
      tableBorder: TableBorder.all(color: palette.border),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      tableColumnWidth: const FlexColumnWidth(),
      blockquoteDecoration: BoxDecoration(
        color: palette.secondary,
        borderRadius: BorderRadius.circular(kRadiusS),
        border: Border(left: BorderSide(color: palette.muted, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    );
  }
}
