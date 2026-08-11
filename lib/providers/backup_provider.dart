import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/data_repository.dart';
import '../api/settings_repository.dart';
import '../sync/wallet_backup_client.dart';
import '../sync/wallet_snapshot.dart';
import 'auth_provider.dart';
import 'data_providers.dart';

final _settings = SettingsRepository(DataRepository());

final walletBackupClientProvider = Provider<WalletBackupClient>(
  (ref) => WalletBackupClient(),
);

final walletBackupRepositoryProvider = Provider<WalletBackupRepository>(
  (ref) => WalletBackupRepository(),
);

/// Whether *this device* backs the wallet up.
///
/// Two conditions, both required, and neither implied by the other: the user
/// must be signed in — a backup keyed to a device-local UUID could never be
/// restored anywhere, because nothing identifies its owner — and they must
/// have switched this on. Default OFF; nothing leaves the device otherwise.
class BackupEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final auth = ref.watch(authProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getBackupEnabled(auth.userId!);
        if (ref.mounted && state != loaded) state = loaded;
      });
    }
    return false;
  }

  Future<void> setEnabled(bool enabled) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    state = enabled;
    await _settings.setBackupEnabled(userId, enabled);
    // Switching it on is itself consent to upload, so seed the service
    // immediately rather than leaving the first backup until some later edit.
    if (enabled) {
      await ref.read(walletBackupControllerProvider).backUpNow();
    }
  }
}

final backupEnabledProvider = NotifierProvider<BackupEnabledNotifier, bool>(
  BackupEnabledNotifier.new,
);

/// Whether the backup toggle can be operated at all: a configured service and
/// a signed-in account. Drives the disabled-with-an-explanation state in
/// Profile rather than hiding the row, so the feature is discoverable before
/// it is usable.
final backupAvailableProvider = Provider<bool>((ref) {
  final signedIn = ref.watch(authProvider.select((s) => s.email != null));
  return signedIn && WalletBackupClient.isConfigured;
});

enum RestoreOutcome { restored, nothingToRestore, unavailable, failed }

class WalletBackupController {
  WalletBackupController(this._ref);
  final Ref _ref;

  String? get _userId => _ref.read(authProvider).userId;

  /// Uploads the current wallet, replacing whatever the service holds.
  Future<BackupStatus> backUpNow() async {
    final userId = _userId;
    if (userId == null) return BackupStatus.unavailable;
    final snapshot = await _ref
        .read(walletBackupRepositoryProvider)
        .capture(userId);
    return _ref.read(walletBackupClientProvider).push(snapshot);
  }

  /// Pulls the stored backup and applies it over the local wallet.
  ///
  /// Unconditionally destructive — every caller has either checked the wallet
  /// is empty or asked the user first.
  Future<RestoreOutcome> restoreNow() async {
    final userId = _userId;
    if (userId == null) return RestoreOutcome.unavailable;
    final result = await _ref.read(walletBackupClientProvider).pull();
    switch (result.status) {
      case BackupStatus.unavailable:
        return RestoreOutcome.unavailable;
      case BackupStatus.empty:
        return RestoreOutcome.nothingToRestore;
      case BackupStatus.failed:
        return RestoreOutcome.failed;
      case BackupStatus.ok:
        break;
    }
    final snapshot = result.snapshot;
    if (snapshot == null) return RestoreOutcome.nothingToRestore;
    await _ref
        .read(walletBackupRepositoryProvider)
        .apply(snapshot, userId: userId);
    for (final p in syncInvalidatedProviders) {
      _ref.invalidate(p);
    }
    return RestoreOutcome.restored;
  }

  /// The one thing that happens without being asked for.
  ///
  /// Restores on launch **only onto an empty wallet** — the new-phone case.
  /// When both the device and the service hold cards, this does nothing: the
  /// user can see those cards, and silently replacing them with a copy from
  /// elsewhere would destroy edits they never agreed to lose. That collision
  /// is what the two manual buttons in Profile are for, where the direction is
  /// stated and confirmed.
  Future<RestoreOutcome> maybeAutoRestore() async {
    final userId = _userId;
    if (userId == null) return RestoreOutcome.unavailable;
    if (!_ref.read(backupAvailableProvider)) return RestoreOutcome.unavailable;
    // Deliberately *not* gated on [backupEnabledProvider]. That setting is
    // device-local and defaults to off, so requiring it here would mean a new
    // phone — the one case this exists for — could never restore. The opt-in
    // governs uploading; pulling a user's own backup onto their own
    // signed-in device needs no separate permission.
    final empty = await _ref
        .read(walletBackupRepositoryProvider)
        .isWalletEmpty(userId);
    if (!empty) return RestoreOutcome.nothingToRestore;

    final outcome = await restoreNow();
    if (outcome == RestoreOutcome.restored) {
      // A restore proves this account uses backup. Leaving the new phone with
      // the toggle off would quietly stop protecting it while the user
      // reasonably assumes otherwise — a silent trap, and the more dangerous
      // of the two defaults.
      await _settings.setBackupEnabled(userId, true);
      _ref.invalidate(backupEnabledProvider);
    }
    return outcome;
  }
}

final walletBackupControllerProvider = Provider<WalletBackupController>(
  WalletBackupController.new,
);
