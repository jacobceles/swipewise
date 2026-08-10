import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../providers/data_providers.dart';
import '../providers/nearby_providers.dart';
import '../theme/app_theme.dart';

/// Manage the per-store mute list. Each row is a store the user silenced from
/// the Nearby Stores list; Unmute removes it and re-registers the fence set so
/// the store's dwell alerts come back promptly.
class MutedStoresScreen extends ConsumerWidget {
  const MutedStoresScreen({super.key});

  Future<void> _unmute(WidgetRef ref, String merchantId) async {
    await ref.read(dataRepositoryProvider).unmuteMerchant(merchantId);
    ref.invalidate(mutedMerchantsListProvider);
    ref.invalidate(mutedMerchantIdsProvider);
    // ignore: unawaited_futures
    reregisterAfterMuteChange(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = AppPalette.of(context);
    final muted = ref.watch(mutedMerchantsListProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: palette.secondary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(LucideIcons.chevronLeft, size: 18),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Muted Stores',
                    style: AppText.titleLg().copyWith(fontSize: 18),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Muted stores stay in the Nearby list but never send an '
                'arrival alert. Unmute to turn their alerts back on.',
                style: AppText.bodySm(),
              ),
            ),
            Expanded(
              child: muted.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) =>
                    const _EmptyState(message: "Couldn't load muted stores."),
                data: (rows) {
                  if (rows.isEmpty) {
                    return const _EmptyState(
                      message:
                          'No muted stores. Mute a store from the Nearby '
                          'list to stop its alerts.',
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final row = rows[i];
                      return _MutedRow(
                        name: (row['name'] as String?) ?? 'Unknown store',
                        onUnmute: () =>
                            _unmute(ref, row['merchant_id'] as String),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MutedRow extends StatelessWidget {
  const _MutedRow({required this.name, required this.onUnmute});

  final String name;
  final VoidCallback onUnmute;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.secondary,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              LucideIcons.bellOff,
              size: 18,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              name,
              style: AppText.titleMd(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onUnmute,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: AppColors.primary,
            ),
            child: Text(
              'Unmute',
              style: AppText.titleMd(
                color: AppColors.primary,
              ).copyWith(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: AppText.bodyMd(),
        ),
      ),
    );
  }
}
