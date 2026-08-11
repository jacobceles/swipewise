import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';

/// First run: sign in, or skip.
///
/// Signing in unlocks nothing today — it only attaches a Google identity to
/// the wallet so the profile has a name and the account exists ahead of the
/// features that will need one. The copy says exactly that rather than
/// promising backup or Pro, neither of which is built; both are marked
/// "Soon" instead.
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
                  // Deliberately not "your cards stay on this device": that is
                  // true of this build and becomes false the moment backup
                  // ships — which is the feature promised two lines below.
                  // Copy that expires is worse than vague copy, so this says
                  // what will stay true: signing in is not itself an upload,
                  // and backup will be a switch the user throws.
                  Text(
                    'Signing in only identifies you. Nothing is uploaded — '
                    'and when backup arrives, it will be opt-in.',
                    style: AppText.bodySm(color: palette.muted),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  const _SoonRow(
                    icon: LucideIcons.smartphone,
                    label: 'Restore your wallet on a new phone',
                  ),
                  const SizedBox(height: 12),
                  const _SoonRow(
                    icon: LucideIcons.crown,
                    label: 'Carry Pro across your devices',
                  ),
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

/// A benefit that signing in will unlock, honestly labelled as not yet built.
class _SoonRow extends StatelessWidget {
  const _SoonRow({required this.icon, required this.label});

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
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: palette.secondary,
            borderRadius: BorderRadius.circular(kRadiusPill),
          ),
          child: Text('Soon', style: AppText.labelSm(color: palette.muted)),
        ),
      ],
    );
  }
}
