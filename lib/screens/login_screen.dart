import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';

class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final palette = AppPalette.of(context);
    final error = authState.error;

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
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        LucideIcons.creditCard,
                        size: 32,
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
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
              decoration: const BoxDecoration(
                color: AppColors.sheet,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Get Started',
                    style: AppText.bodyMd(color: palette.muted),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Sign in with Google to sync your cards and earn more rewards.',
                    style: AppText.bodySm(color: palette.muted),
                    textAlign: TextAlign.center,
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
                      onPressed: authState.isLoading
                          ? null
                          : () => ref
                                .read(authProvider.notifier)
                                .signInWithGoogle(),
                      child: authState.isLoading
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
