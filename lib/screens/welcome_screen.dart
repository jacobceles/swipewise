import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

/// First run: sign in, or skip.
///
/// Signing in attaches a Google identity to the wallet, which unlocks backup
/// and restore. The copy describes that rather than promising it.
///
/// Nothing unbuilt is advertised here. A "Carry Pro across your devices — Soon"
/// row was removed when Pro stopped being something we were about to sell: this
/// is the most-read screen in the app, and copy that outruns the build is the
/// kind of lie nobody notices writing.
///
/// Skipping is a first-class choice, not a dismissal: it takes the same path
/// the app has always taken, keeping the device-local identity minted by
/// [AuthNotifier]. Either answer sets `onboardingSeen`, so this is shown once.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  Future<void> _signIn() async {
    await ref.read(authProvider.notifier).signInWithGoogle();
    if (!mounted) return;
    // `isLoggedIn` is already true here — the device-local identity set it —
    // so the signal that Google actually completed is the email landing.
    // A cancelled picker leaves it null and keeps the user on this screen.
    if (ref.read(authProvider).email != null) {
      await ref.read(onboardingSeenProvider.notifier).markSeen();
    }
  }

  Future<void> _skip() =>
      ref.read(onboardingSeenProvider.notifier).markSeen();

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final palette = AppPalette.of(context);
    final error = authState.error;
    final busy = authState.isLoading;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 88,
                      height: 88,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        LucideIcons.creditCard,
                        size: 38,
                        color: AppColors.onPrimary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text('SwipeWise', style: AppText.displayLg()),
                    const SizedBox(height: 6),
                    Text(
                      'Smart Credit Card Management',
                      style: AppText.bodyMd(color: palette.muted),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 30, 20, 34),
              decoration: const BoxDecoration(
                color: AppColors.sheet,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Sign in, or skip for now',
                    style: AppText.titleMd(),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  // Says what is true of *this* build. Backup shipped, so the
                  // promise is now a description — but it is still off by
                  // default, and that is the part worth stating up front.
                  Text(
                    'Signing in only identifies you. Backup is opt-in — '
                    'nothing is uploaded unless you turn it on.',
                    style: AppText.bodySm(color: palette.muted),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  const _BenefitRow(
                    icon: LucideIcons.smartphone,
                    label: 'Restore your wallet on a new phone',
                  ),
                  // "Carry Pro across your devices — Soon" lived here. Removed
                  // rather than left pending: Pro is not being sold, so the
                  // first screen should not advertise it. Restore the row (with
                  // `soon: true`) when billing ships.

                  if (error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: palette.redBg,
                        borderRadius: BorderRadius.circular(kRadiusS),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.circleAlert,
                            size: 16,
                            color: palette.red,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              error,
                              style: AppText.bodySm(color: palette.red),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: busy ? null : _signIn,
                      child: busy
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppColors.onPrimary,
                              ),
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.login, size: 20),
                                SizedBox(width: 10),
                                Text('Continue with Google'),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton(
                      onPressed: busy ? null : _skip,
                      child: const Text('Skip for now'),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'You can sign in any time from Profile.',
                    style: AppText.labelSm(color: palette.muted),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A benefit of signing in. [soon] marks the ones not built yet, so the screen
/// never claims something the build cannot do — the pill comes off the day the
/// feature ships, not the day it is planned.
class _BenefitRow extends StatelessWidget {
  const _BenefitRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: palette.muted),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: AppText.bodySm())),
      ],
    );
  }
}
