import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import 'onboarding_ui.dart';

/// First run, screen 1 (design "OB4 1 · Welcome"): what SwipeWise does, shown
/// as the exact alert it posts, and what setup will cover. Nothing is asked
/// here; "Start setup" leads to the sign-in-or-skip screen.
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key, required this.onStart});
  final VoidCallback onStart;

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with SingleTickerProviderStateMixin {
  // The alert drops onto the lock screen 400 ms after load (design note).
  late final _drop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _drop.forward();
    });
  }

  @override
  void dispose() {
    _drop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _drop, curve: Curves.easeOutBack);
    return ObScreen(
      center: true,
      hero: ObHero(
        height: 230,
        top: Ob.inkSun,
        glows: const [
          Glow(Ob.flame, -40, -30, 220, 180, 0.35),
          Glow(Ob.gold, 180, 40, 220, 180, 0.25),
        ],
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('10:42', style: AppText.monoLg(color: AppColors.foreground)),
            const SizedBox(height: 4),
            Text(
              DateFormat('EEEE, MMMM d').format(DateTime.now()),
              style: AppText.bodySm(color: Ob.muted),
            ),
            const SizedBox(height: 18),
            FadeTransition(
              opacity: _drop,
              child: SlideTransition(
                position: Tween(
                  begin: const Offset(0, -0.4),
                  end: Offset.zero,
                ).animate(curve),
                child: const AlertMock(cardName: 'Freedom Flex', rate: '3x'),
              ),
            ),
          ],
        ),
      ),
      content: const [
        ObHeading(
          title: 'Welcome to SwipeWise',
          body:
              'See which of your cards earns the most wherever you pay. '
              'Setup takes about a minute.',
        ),
        ObSection(
          label: "WHAT WE'LL SET UP",
          rows: [
            ObRow(
              icon: LucideIcons.walletCards,
              iconColor: Ob.pink,
              tileColor: Ob.inkViolet,
              title: 'Add your cards',
              subtitle: 'So SwipeWise can compare them',
              trailing: _Tag('1 MIN'),
            ),
            ObRow(
              icon: LucideIcons.bell,
              iconColor: Ob.gold,
              tileColor: Ob.inkSun,
              title: 'Store alerts',
              subtitle: 'A heads-up like the one above',
              trailing: _Tag('OPTIONAL'),
            ),
          ],
        ),
      ],
      primary: 'Start setup',
      primaryIcon: LucideIcons.arrowRight,
      onPrimary: widget.onStart,
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: AppText.monoXs(color: Ob.muted));
}
