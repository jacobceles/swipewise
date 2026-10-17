import 'package:material_ui/material_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../theme/app_theme.dart';

/// Wireframe `HPtUB` (Settings v4): the shared pieces of the Profile tab and
/// the pages it opens.
///
/// One grid everywhere: a [kGutter] screen margin, rows inset [kRowInset]
/// inside their group, a [kIconSlot] icon column, and every row's text
/// starting at [kTextColumn] — section labels, captions and divider insets
/// line up with that edge, and all trailing controls end on the same right
/// edge.
const double kGutter = 20;
const double kRowInset = 16;
const double kIconSlot = 32;
const double kTextColumn = kRowInset + kIconSlot + 12;
const double kGroupRadius = kRadiusM;

/// Gap between groups on a detail page.
const double kGroupGap = 28;

// The same scale as the other tabs: 14 px row titles, 12 px secondary text.
TextStyle rowTitleStyle() =>
    AppText.bodyMd().copyWith(fontWeight: FontWeight.w600);

TextStyle rowSubtitleStyle(AppPalette palette) =>
    AppText.bodySm(color: palette.muted);

TextStyle rowValueStyle(AppPalette palette) =>
    AppText.bodyMd(color: palette.muted);

/// A rounded group of rows, dividers inset to the text column.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children, this.color});

  final List<Widget> children;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      color: color ?? AppColors.card,
      borderRadius: BorderRadius.circular(kGroupRadius),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(height: 1, indent: kTextColumn, color: palette.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// The 32 px rounded square a row's icon sits in.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color, this.background});

  final IconData icon;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      width: kIconSlot,
      height: kIconSlot,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? palette.secondary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 18, color: color ?? AppColors.foreground),
    );
  }
}

/// One setting: icon, title, optional subtitle, and a trailing value,
/// control or chevron. Rows without an icon still start text at the column.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.icon,
    this.iconTile,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.value,
    this.trailing,
    this.chevron = false,
    this.onTap,
    this.enabled = true,
  });

  final IconData? icon;

  /// Replaces the default [IconTile] built from [icon].
  final Widget? iconTile;
  final String title;
  final Color? titleColor;
  final String? subtitle;

  /// Muted text before the chevron ("2 on", "Cards · Stores").
  final String? value;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final lead =
        iconTile ?? (icon == null ? null : IconTile(icon!, color: titleColor));
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          lead == null ? kTextColumn : kRowInset,
          subtitle == null ? 8 : 12,
          kRowInset,
          subtitle == null ? 8 : 12,
        ),
        child: Row(
          children: [
            if (lead != null) ...[lead, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: rowTitleStyle().copyWith(color: titleColor),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: rowSubtitleStyle(palette)),
                  ],
                ],
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 12),
              // Capped rather than flexible, so the value hugs the right edge
              // and a long one ("Sapphire Preferred first") is shortened.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  value!,
                  style: rowValueStyle(palette),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            if (chevron) ...[
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronRight, size: 18, color: palette.muted),
            ],
          ],
        ),
      ),
    );
    final body = Opacity(opacity: enabled ? 1 : 0.45, child: row);
    if (onTap == null) return body;
    return InkWell(onTap: enabled ? onTap : null, child: body);
  }
}

/// The label above a group, aligned with the group's row inset, with an
/// optional action on the right ("Reset").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.action, this.onAction});

  final String label;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kRowInset, 0, kRowInset, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppText.bodyMd(
                color: palette.muted,
              ).copyWith(fontWeight: FontWeight.w500, fontSize: 12),
            ),
          ),
          if (action != null) LinkAction(label: action!, onTap: onAction),
        ],
      ),
    );
  }
}

/// One or two lines under a group explaining it.
class GroupCaption extends StatelessWidget {
  const GroupCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kRowInset, 10, kRowInset, 0),
      child: Text(text, style: rowSubtitleStyle(AppPalette.of(context))),
    );
  }
}

/// Orange text action ("Reset", "Unmute").
class LinkAction extends StatelessWidget {
  const LinkAction({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            label,
            style: AppText.bodyMd(
              color: AppColors.primary,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

/// Fixed-width orange button so a column of them ends on one edge
/// ("Allow", "Fix").
class ActionPill extends StatelessWidget {
  const ActionPill({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 30,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          padding: EdgeInsets.zero,
          shape: const StadiumBorder(),
        ),
        child: Text(
          label,
          style: AppText.bodyMd(
            color: AppColors.onPrimary,
          ).copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// A detail page: round back button and title, then [children] on the grid.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kGutter, 12, kGutter, 8),
              child: Row(
                children: [
                  Semantics(
                    label: 'Back',
                    button: true,
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: palette.secondary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(LucideIcons.arrowLeft, size: 18),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: AppText.titleLg().copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(kGutter, 12, kGutter, 40),
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> pushSettingsPage(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

/// Opens a bottom sheet (Advisor's store filter).
Future<void> showProfileSheet(BuildContext context, Widget sheet) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.card,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => sheet,
  );
}

/// One-of-N choice, every option visible at once.
class SegmentedChoice<T> extends StatelessWidget {
  const SegmentedChoice({
    super.key,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
    this.background = AppColors.card,
  });

  final List<T> options;
  final Color background;

  /// Null when no option matches.
  final T? selected;
  final String Function(T) labelOf;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(kGroupRadius),
      ),
      child: Row(
        children: [
          for (final o in options)
            Expanded(
              child: Semantics(
                selected: o == selected,
                button: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onChanged == null ? null : () => onChanged!(o),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: o == selected
                          ? palette.secondary
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(kRadiusS + 2),
                    ),
                    child: Text(
                      labelOf(o),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          AppText.bodyMd(
                            color: o == selected
                                ? AppColors.foreground
                                : palette.muted,
                          ).copyWith(
                            fontSize: 14,
                            fontWeight: o == selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The orange initials circle for a signed-in user.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.identifier, this.size = 64});

  final String? identifier;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
      ),
      child: Text(
        initialsOf(identifier),
        style: AppText.titleLg(
          color: AppColors.onPrimary,
        ).copyWith(fontSize: size * 0.34, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Two letters from a Google display name ("Jacob Celestine" → "JC"), or from
/// the local part of an email when that is all there is.
String initialsOf(String? identifier) {
  if (identifier == null || identifier.trim().isEmpty) return '?';
  final local = identifier.contains('@')
      ? identifier.split('@').first
      : identifier;
  final parts = local
      .split(RegExp(r'[._\-+ ]'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return local.substring(0, local.length >= 2 ? 2 : 1).toUpperCase();
}

/// "1 min", "90 s", "1m 30s".
String formatWait(int seconds) {
  if (seconds < 60) return '$seconds s';
  final m = seconds ~/ 60;
  final r = seconds % 60;
  return r == 0 ? '$m min' : '${m}m ${r}s';
}

/// Plural-aware "N things".
String countOf(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';
