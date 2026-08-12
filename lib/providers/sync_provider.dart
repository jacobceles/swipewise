import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';
import 'bank_sync_provider.dart';
import '../util/logger.dart';

/// Legacy `syncProvider`. Kept as a thin delegate so callers (Dashboard
/// pull-to-refresh, the link's first sync, etc.) keep working after the sync
/// engine split. Just forwards to `bankSyncProvider`.
class SyncNotifier extends Notifier<AsyncValue<void>> {
  @override
  AsyncValue<void> build() => const AsyncValue.data(null);

  Future<void> runSync({bool forceFull = false}) async {
    final auth = ref.read(authProvider);
    if (!auth.isLoggedIn || auth.userId == null) {
      Log.w('sync', 'runSync called without auth; skipping');
      return;
    }
    state = const AsyncValue.loading();
    try {
      await ref.read(bankSyncProvider.notifier).runSync();
      state = const AsyncValue.data(null);
    } catch (e, st) {
      Log.e('sync', 'sync failed', e, st);
      state = AsyncValue.error(e, st);
    }
  }
}

final syncProvider = NotifierProvider<SyncNotifier, AsyncValue<void>>(
  SyncNotifier.new,
);
