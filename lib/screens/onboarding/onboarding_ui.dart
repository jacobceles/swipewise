import 'dart:ui' as ui;

import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';

/// The first-run screens' own palette, taken one for one from the
/// `wireframe.pen` section "Onboarding v4 — hybrid" (its `ob-*` variables and
/// the house tokens it uses). Kept apart from [AppColors] on purpose: the
/// onboarding is drawn to its design exactly, and its greys and greens are the
/// design's, not the everyday app's.
abstract final class Ob {
  static const background = Color(0xFF111111);
  static const card = Color(0xFF1A1A1A);
  static const muted = Color(0xFF8E8E93);
  static const secondary = Color(0xFF2E2E2E);
  static const border = Color(0xFF2A2A2A);
  static const primary = Color(0xFFFF8400);
  static const onPrimary = Color(0xFF111111);
  static const green = Color(0xFF34C759);
  static const greenBg = Color(0xFF0A3A1A);
  static const amber = Color(0xFFFF9500);
  static const amberBg = Color(0xFF3A2A0A);
  static const red = Color(0xFFFF3B30);
  static const redBg = Color(0xFF3A0A0A);

  static const flame = Color(0xFFFF5A36);
  static const gold = Color(0xFFFFC145);
  static const violet = Color(0xFF8B6CFF);
  static const pink = Color(0xFFFF5FA2);
  static const teal = Color(0xFF22D3B4);
  static const sky = Color(0xFF4DA8FF);
  static const mint = Color(0xFF3EE08F);
  static const inkSun = Color(0xFF33170A);
  static const inkViolet = Color(0xFF1E1440);
  static const inkTeal = Color(0xFF0A2A2C);
  static const inkNight = Color(0xFF121538);
  static const inkMint = Color(0xFF0B2A1C);
  static const glass = Color(0x14FFFFFF);
  static const glassStrong = Color(0x29FFFFFF);
  static const glowPrimary = Color(0x59FF8400);
  static const shadow = Color(0x9E000000);
  static const cardFlexA = Color(0xFF2E6BFF);
  static const cardFlexB = Color(0xFF7A4DFF);
  static const sapphireA = Color(0xFF0C2A63);
  static const sapphireB = Color(0xFF2C83D6);

  /// Confetti colours, in the design's order.
  static const confetti = [gold, pink, teal, violet, sky, primary, mint];
}

/// The four steps of the tracker across the top.
enum SetupStep { cards, notifications, location, always }

enum TrackState { todo, now, done, off }

extension SetupStepStyle on SetupStep {
  String get label => switch (this) {
    SetupStep.cards => 'Cards',
    SetupStep.notifications => 'Notifications',
    SetupStep.location => 'Location',
    SetupStep.always => 'All the time',
  };

  IconData get icon => switch (this) {
    SetupStep.cards => LucideIcons.walletCards,
    SetupStep.notifications => LucideIcons.bell,
    SetupStep.location => LucideIcons.mapPin,
    SetupStep.always => LucideIcons.moonStar,
  };

  /// The step's colour: the node when done, the icon while it is the
  /// current step.
  Color get color => switch (this) {
    SetupStep.cards => Ob.pink,
    SetupStep.notifications => Ob.gold,
    SetupStep.location => Ob.teal,
    SetupStep.always => Ob.violet,
  };

  /// The node's fill while it is the current step.
  Color get ink => switch (this) {
    SetupStep.cards => Ob.inkViolet,
    SetupStep.notifications => Ob.inkSun,
    SetupStep.location => Ob.inkTeal,
    SetupStep.always => Ob.inkNight,
  };
}

/// Cards · Notifications · Location · All the time. Each node fills with its
/// step's colour when done and turns red when that step is what's missing.
class SetupTracker extends StatelessWidget {
  const SetupTracker({super.key, required this.states, this.onTap});
  final Map<SetupStep, TrackState> states;

  /// Go back to a step to change it. Null: not tappable.
  final ValueChanged<SetupStep>? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in SetupStep.values) ...[
            if (s != SetupStep.cards) const SizedBox(width: 4),
            Expanded(
              child: _TrackerStep(
                step: s,
                state: states[s] ?? TrackState.todo,
                onTap: onTap == null ? null : () => onTap!(s),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrackerStep extends StatelessWidget {
  const _TrackerStep({required this.step, required this.state, this.onTap});
  final SetupStep step;
  final TrackState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (fill, iconColor, icon, label) = switch (state) {
      TrackState.done => (
        step.color,
        Ob.onPrimary,
        LucideIcons.check,
        step.color,
      ),
      TrackState.now => (step.ink, step.color, step.icon, AppColors.foreground),
      TrackState.off => (Ob.redBg, Ob.red, LucideIcons.x, Ob.red),
      TrackState.todo => (Ob.secondary, Ob.muted, step.icon, Ob.muted),
    };
    return Semantics(
      label: '${step.label}: ${state.name}',
      button: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                border: switch (state) {
                  TrackState.off => Border.all(color: Ob.red, width: 2),
                  TrackState.now => Border.all(color: step.color, width: 2),
                  _ => null,
                },
                boxShadow: state == TrackState.now
                    ? const [BoxShadow(color: Ob.glowPrimary, blurRadius: 14)]
                    : null,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 15, color: iconColor),
            ),
            const SizedBox(height: 6),
            Text(
              step.label,
              style: AppText.labelSm(color: label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// A soft blurred colour blob behind a hero, as the design's "Glow" layers.
class Glow {
  const Glow(
    this.color,
    this.left,
    this.top,
    this.width,
    this.height,
    this.opacity,
  );
  final Color color;
  final double left, top, width, height, opacity;
}

/// The rounded picture panel at the top of each screen.
///
/// Drawn on the design's own 350-wide canvas and scaled to the real width, so
/// the absolutely placed pieces (cards, map blocks, confetti) land where the
/// design puts them on any phone. Illustration text doesn't follow the
/// system font size; the screens drop the hero entirely at large sizes.
class ObHero extends StatelessWidget {
  const ObHero({
    super.key,
    required this.height,
    required this.top,
    this.glows = const [],
    required this.child,
  });

  final double height;

  /// The gradient's top colour; it fades to [Ob.card].
  final Color top;
  final List<Glow> glows;
  final Widget child;

  static const width = 350.0;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withNoTextScaling(
      child: AspectRatio(
        aspectRatio: width / height,
        child: Container(
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Ob.border),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(
                width: width,
                height: height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [top, Ob.card],
                    ),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final g in glows)
                        Positioned(
                          left: g.left,
                          top: g.top,
                          width: g.width,
                          height: g.height,
                          child: ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(
                              sigmaX: 30,
                              sigmaY: 30,
                              tileMode: TileMode.decal,
                            ),
                            child: Opacity(
                              opacity: g.opacity,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: g.color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned.fill(child: child),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One confetti piece: (left, top, width, height, rotation in degrees).
typedef ConfettiPiece = (double, double, double, double, double);

/// Static confetti, coloured in the design's rotation. Positions come from the
/// design so pieces never land on content.
class Confetti extends StatelessWidget {
  const Confetti({super.key, required this.pieces});
  final List<ConfettiPiece> pieces;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (final (i, (l, t, w, h, deg)) in pieces.indexed)
          Positioned(
            left: l,
            top: t,
            child: Transform.rotate(
              angle: deg * 3.1415926535 / 180,
              child: Opacity(
                opacity: 0.9,
                child: Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    color: Ob.confetti[i % Ob.confetti.length],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The store alert, drawn the way SwipeWise posts it: "You're at Walgreens" /
/// "Use Freedom Flex for 3%". [cardName] null is the app's own no-card
/// wording.
class AlertMock extends StatelessWidget {
  const AlertMock({
    super.key,
    this.store = 'Walgreens',
    required this.cardName,
    required this.rate,
  });

  final String store;
  final String? cardName;
  final String? rate;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 310,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Ob.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Ob.glassStrong),
        boxShadow: const [
          BoxShadow(color: Ob.shadow, offset: Offset(0, 12), blurRadius: 28),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Ob.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(
              LucideIcons.sparkles,
              size: 18,
              color: Ob.onPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('SWIPEWISE', style: AppText.labelSm(color: Ob.muted)),
                    Text('now', style: AppText.monoXs(color: Ob.muted)),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  "You're at $store",
                  style: AppText.titleMd(color: AppColors.foreground),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                if (cardName == null)
                  Text(
                    'Open SwipeWise to see the best card here',
                    style: AppText.bodyMd(color: AppColors.foreground),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Use $cardName for',
                          style: AppText.bodyMd(color: AppColors.foreground),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (rate != null) ...[
                        const SizedBox(width: 6),
                        RatePill(rate!),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The green "3%" pill.
class RatePill extends StatelessWidget {
  const RatePill(this.rate, {super.key});
  final String rate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Ob.greenBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(rate, style: AppText.monoMd(color: Ob.green)),
    );
  }
}

/// Status pill on a hero ("LIVE", "PAUSED").
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    required this.background,
  });
  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: AppText.labelSm(color: color)),
        ],
      ),
    );
  }
}

/// A round gradient badge holding one icon (the bell, the check).
class Medal extends StatelessWidget {
  const Medal({
    super.key,
    required this.icon,
    required this.from,
    required this.to,
    this.size = 58,
    this.iconSize = 27,
  });
  final IconData icon;
  final Color from, to;
  final double size, iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [from, to],
        ),
        boxShadow: const [
          BoxShadow(color: Ob.shadow, offset: Offset(0, 8), blurRadius: 22),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: iconSize, color: Ob.onPrimary),
    );
  }
}

/// "Welcome to SwipeWise" + its one line.
class ObHeading extends StatelessWidget {
  const ObHeading({super.key, required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppText.displayLg(color: AppColors.foreground)),
        const SizedBox(height: 6),
        Text(body, style: AppText.bodyMd(color: Ob.muted)),
      ],
    );
  }
}

/// A labelled group of rows: "WHAT WE'LL SET UP" over a rounded card.
class ObSection extends StatelessWidget {
  const ObSection({super.key, required this.label, required this.rows});
  final String label;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: AppText.labelSm(color: Ob.muted)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(
            color: Ob.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              for (final (i, r) in rows.indexed) ...[
                if (i > 0) const Divider(height: 1, color: Ob.border),
                r,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A row in an [ObSection]: icon tile, title over subtitle, optional trailing.
class ObRow extends StatelessWidget {
  const ObRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.tileColor,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.dimTitle = false,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final Color tileColor;
  final String title;
  final String subtitle;
  final Widget? trailing;

  /// Grey title, for the "once your cards are in" placeholders.
  final bool dimTitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: tileColor, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(icon, size: 17, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppText.titleMd(
                    color: dimTitle ? Ob.muted : AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: AppText.bodyMd(color: Ob.muted)),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}

/// "Freedom Flex" over "3%": the best card at the end of a row.
class BestCardTrailing extends StatelessWidget {
  const BestCardTrailing({super.key, required this.card, required this.rate});
  final String card;
  final String rate;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 150),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            card,
            style: AppText.bodyMd(color: Ob.primary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(rate, style: AppText.monoMd(color: Ob.muted)),
        ],
      ),
    );
  }
}

/// "ⓘ Android asks next — tap Allow."
class ObHint extends StatelessWidget {
  const ObHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(LucideIcons.info, size: 16, color: Ob.muted),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: AppText.bodyMd(color: Ob.muted)),
        ),
      ],
    );
  }
}

/// Play's background-location disclosure, in a box outlined in [color].
class DisclosureBox extends StatelessWidget {
  const DisclosureBox({
    super.key,
    required this.color,
    required this.title,
    required this.paragraphs,
  });
  final Color color;
  final String title;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Ob.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(LucideIcons.mapPin, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: AppText.titleMd(color: AppColors.foreground),
                ),
              ),
            ],
          ),
          for (final p in paragraphs) ...[
            const SizedBox(height: 8),
            Text(p, style: AppText.bodyMd(color: AppColors.foreground)),
          ],
        ],
      ),
    );
  }
}

/// The design's switch: 46×28, grey with a grey knob when off.
class ObSwitch extends StatelessWidget {
  const ObSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      button: true,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 46,
          height: 28,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? Ob.primary : Ob.secondary,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: value ? AppColors.foreground : Ob.muted,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// One screen of the first run: tracker, a scrolling body, fixed buttons.
///
/// The body scrolls under the footer, so nothing is cut short at large font
/// sizes; the hero is dropped once the system font is scaled past 1.5×.
class ObScreen extends StatelessWidget {
  const ObScreen({
    super.key,
    this.tracker,
    this.hero,
    required this.content,
    required this.primary,
    required this.onPrimary,
    this.primaryIcon,
    this.secondary,
    this.onSecondary,
    this.busy = false,
    this.center = false,
  });

  final Widget? tracker;
  final Widget? hero;
  final List<Widget> content;
  final String primary;
  final VoidCallback onPrimary;
  final IconData? primaryIcon;
  final String? secondary;
  final VoidCallback? onSecondary;
  final bool busy;

  /// Centre the body vertically (the welcome screen).
  final bool center;

  @override
  Widget build(BuildContext context) {
    final big = MediaQuery.textScalerOf(context).scale(10) > 15;
    final body = <Widget>[if (hero != null && !big) hero!, ...content];
    return Scaffold(
      backgroundColor: Ob.background,
      body: SafeArea(
        child: Column(
          children: [
            ?tracker,
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: center ? constraints.maxHeight - 32 : 0,
                    ),
                    child: Column(
                      mainAxisAlignment: center
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, w) in body.indexed) ...[
                          if (i > 0) const SizedBox(height: 20),
                          w,
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: busy ? null : onPrimary,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Ob.primary,
                        foregroundColor: Ob.onPrimary,
                        disabledBackgroundColor: Ob.primary.withValues(
                          alpha: 0.5,
                        ),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              primary,
                              style: AppText.titleMd(color: Ob.onPrimary),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          if (primaryIcon != null) ...[
                            const SizedBox(width: 8),
                            Icon(primaryIcon, size: 18, color: Ob.onPrimary),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (secondary != null) ...[
                    const SizedBox(height: 2),
                    SizedBox(
                      height: 44,
                      child: TextButton(
                        onPressed: busy ? null : onSecondary,
                        child: Text(
                          secondary!,
                          style: AppText.titleMd(color: Ob.muted),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Chase Freedom Flex® Credit Card" → "Freedom Flex": the short name the
/// design uses on cards and in rows.
String shortCardName(String name) {
  var s = name.replaceAll(RegExp('[®™℠]'), '').trim();
  s = s.replaceFirst(RegExp(r'\s+(Credit\s+)?Card$', caseSensitive: false), '');
  s = s.replaceFirst(
    RegExp(
      r'^(Chase|Citi|Amex|American Express|Capital One|Discover|Wells Fargo|'
      r'Bank of America|U\.S\. Bank|US Bank|Barclays|Synchrony|TD|RBC|CIBC|'
      r'Scotiabank|BMO)\s+',
      caseSensitive: false,
    ),
    '',
  );
  return s.trim().isEmpty ? name : s.trim();
}

/// "3%" for cash back, "2x" for points and miles.
String formatPickRate(double rate, String currency) {
  final n = rate == rate.roundToDouble()
      ? rate.toStringAsFixed(0)
      : rate.toStringAsFixed(1);
  return currency == 'USD' ? '$n%' : '${n}x';
}
