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
///
/// Except one case, so two phones (or the Play and dev builds) on one account
/// agree: a phone that has *never* set the switch, signed in to an account
/// that already has a backup, starts with it ON. That backup is the user's
/// earlier "yes" on another phone. Turning it on uploads nothing by itself,
/// and automatic backup stops rather than replace cards this phone lacks
/// ([WalletBackupController.maybeAutoBackup]). A phone where the user chose
/// OFF stays off.
class BackupEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final auth = ref.watch(authProvider);
    final userId = auth.userId;
    if (userId != null) {
      Future.microtask(() async {
        if (!ref.mounted || ref.read(authProvider).userId != userId) return;
        await ref.read(walletBackupControllerProvider)._track(() async {
          var loaded = await _settings.getBackupEnabledOrNull(userId);
          if (loaded == null &&
              auth.email != null &&
              WalletBackupClient.isConfigured) {
            // A failed lookup reads as "no backup" and leaves the switch unset,
            // so the next launch asks again.
            final remote = await ref
                .read(walletBackupControllerProvider)
                .remoteInfo();
            if (!ref.mounted || ref.read(authProvider).userId != userId) return;
            if (remote.exists) {
              await _settings.setBackupEnabled(userId, true);
              loaded = true;
            }
          }
          if (ref.mounted &&
              ref.read(authProvider).userId == userId &&
              state != (loaded ?? false)) {
            state = loaded ?? false;
          }
        });
      });
    }
    return false;
  }

  /// [seedBackup] uploads immediately on enable. Callers that have *asked* the
  /// user about replacing an existing backup pass true; the UI passes false
  /// when it has not, because switching a toggle is consent to start backing
  /// up — not consent to destroy a backup made from another phone.
  Future<void> setEnabled(bool enabled, {bool seedBackup = true}) => ref
      .read(walletBackupControllerProvider)
      ._track(() => _setEnabled(enabled, seedBackup: seedBackup));

  Future<void> _setEnabled(bool enabled, {required bool seedBackup}) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    state = enabled;
    await _settings.setBackupEnabled(userId, enabled);
    if (enabled && seedBackup && ref.read(authProvider).userId == userId) {
      await ref.read(walletBackupControllerProvider).backUpNow();
    }
  }
}

final backupEnabledProvider = NotifierProvider<BackupEnabledNotifier, bool>(
  BackupEnabledNotifier.new,
);

/// Whether this build has a sync service at all.
///
/// Separate from [backupAvailableProvider] because the two have different
/// answers in the UI: a build with no service configured has no backup
/// feature, and should say nothing rather than explain how to enable
/// something that cannot exist. Only a *configured* build shows the row and
/// asks the user to sign in.
final backupSupportedProvider = Provider<bool>(
  (ref) => WalletBackupClient.isConfigured,
);

/// Whether the toggle can actually be operated: a configured service *and* a
/// signed-in account. When this is false but [backupSupportedProvider] is
/// true, Profile shows the row disabled with the reason rather than hiding
/// it, so the feature is discoverable before it is usable.
final backupAvailableProvider = Provider<bool>((ref) {
  final signedIn = ref.watch(authProvider.select((s) => s.email != null));
  return signedIn && ref.watch(backupSupportedProvider);
});

enum RestoreOutcome { restored, nothingToRestore, unavailable, failed }

enum AutoBackupOutcome { off, unchanged, uploaded, held, failed }

/// What the service already holds, so the UI can warn before overwriting it.
class RemoteBackupInfo {
  const RemoteBackupInfo({
    required this.exists,
    this.capturedAt,
    this.cards,
    this.cardsNotOnThisPhone = 0,
  });

  final bool exists;
  final DateTime? capturedAt;
  final int? cards;

  /// Cards in the backup that this phone does not have.
  ///
  /// The only number that justifies interrupting anyone. A backup merely
  /// *existing* means the user already agreed to back up — re-enabling on the
  /// same phone is not a new question. Overwriting a backup that holds cards
  /// they would lose is.
  final int cardsNotOnThisPhone;

  bool get uploadWouldLoseCards => cardsNotOnThisPhone > 0;
}

class WalletBackupController {
  WalletBackupController(this._ref);
  final Ref _ref;
  final _pending = <Future<Object?>>{};

  Future<T> _track<T>(Future<T> Function() operation) {
    final future = operation();
    _pending.add(future);
    future.whenComplete(() => _pending.remove(future)).ignore();
    return future;
  }

  Future<void> waitUntilIdle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(
        _pending.toList().map((f) => f.catchError((_) => null)),
      );
    }
  }

  bool _isCurrent(String userId) => _ref.mounted && _userId == userId;

  String? get _userId => _ref.read(authProvider).userId;

  /// What the service currently holds for this user, if anything.
  ///
  /// Exists so the UI can say *what* it is about to overwrite. "Replace your
  /// backup?" is a question nobody can answer; "replace the backup from
  /// 9 Aug with 5 cards?" is.
  Future<RemoteBackupInfo> remoteInfo() => _track(_remoteInfo);

  Future<RemoteBackupInfo> _remoteInfo() async {
    final userId = _userId;
    if (userId == null) return const RemoteBackupInfo(exists: false);
    final result = await _ref.read(walletBackupClientProvider).pull();
    final snapshot = result.snapshot;
    if (result.status != BackupStatus.ok ||
        snapshot == null ||
        !_isCurrent(userId)) {
      return const RemoteBackupInfo(exists: false);
    }
    final here = await _ref
        .read(walletBackupRepositoryProvider)
        .localCardIds(userId);
    final missing = snapshot.cards.where((c) => !here.contains(c['id'])).length;
    return RemoteBackupInfo(
      exists: true,
      capturedAt: snapshot.capturedAt,
      cards: snapshot.cards.length,
      cardsNotOnThisPhone: missing,
    );
  }

  /// Uploads the current wallet, replacing whatever the service holds.
  Future<BackupStatus> backUpNow() => _track(_backUpNow);

  Future<BackupStatus> _backUpNow() async {
    final userId = _userId;
    if (userId == null) return BackupStatus.unavailable;
    final snapshot = await _ref
        .read(walletBackupRepositoryProvider)
        .capture(userId);
    if (!_isCurrent(userId)) return BackupStatus.unavailable;
    final status = await _ref.read(walletBackupClientProvider).push(snapshot);
    if (status == BackupStatus.ok && _isCurrent(userId)) {
      await _recordSynced(userId, snapshot);
    }
    return status;
  }

  /// Uploads the wallet if backup is on and it changed since this phone last
  /// uploaded or restored. Called when the app goes to the background.
  ///
  /// Holds back instead of uploading when the stored backup was written
  /// elsewhere (its fingerprint isn't the one this phone left) *and* has
  /// cards this phone lacks: another phone added them, or this is a new phone
  /// whose switch came on because the account had a backup. Replacing it
  /// would lose those cards, and only the user can say which copy wins, so
  /// Profile says why it stopped. Cards deleted here are not a conflict:
  /// when the backup is still the one this phone uploaded, it is replaced.
  Future<AutoBackupOutcome> maybeAutoBackup() => _track(_maybeAutoBackup);

  Future<AutoBackupOutcome> _maybeAutoBackup() async {
    final userId = _userId;
    if (userId == null || !await _settings.getBackupEnabled(userId)) {
      return AutoBackupOutcome.off;
    }
    final snapshot = await _ref
        .read(walletBackupRepositoryProvider)
        .capture(userId);
    final known = await _settings.getBackupFingerprint(userId);
    if (snapshot.fingerprint == known) return AutoBackupOutcome.unchanged;

    final client = _ref.read(walletBackupClientProvider);
    final remote = await client.pull();
    if (!_isCurrent(userId)) return AutoBackupOutcome.off;
    if (remote.status == BackupStatus.failed ||
        remote.status == BackupStatus.unavailable) {
      return AutoBackupOutcome.failed;
    }
    final stored = remote.snapshot;
    if (stored != null && stored.fingerprint != known) {
      final here = snapshot.cards.map((c) => c['id']).toSet();
      final missing = stored.cards.where((c) => !here.contains(c['id'])).length;
      if (missing > 0) {
        await _settings.setBackupHeldCards(userId, missing);
        _ref.invalidate(backupHeldCardsProvider);
        return AutoBackupOutcome.held;
      }
    }
    if (await client.push(snapshot) != BackupStatus.ok) {
      return AutoBackupOutcome.failed;
    }
    if (_isCurrent(userId)) await _recordSynced(userId, snapshot);
    return AutoBackupOutcome.uploaded;
  }

  /// This phone and the stored backup now agree on [snapshot].
  Future<void> _recordSynced(
    String userId,
    WalletSnapshot snapshot, {
    bool uploaded = true,
  }) async {
    if (uploaded) {
      await _settings.setLastBackupAt(userId, DateTime.now());
      _ref.invalidate(lastBackupAtProvider);
    }
    await _settings.setBackupFingerprint(userId, snapshot.fingerprint);
    await _settings.setBackupHeldCards(userId, 0);
    _ref.invalidate(backupHeldCardsProvider);
  }

  /// Pulls the stored backup and applies it over the local wallet.
  ///
  /// Unconditionally destructive — every caller has either checked the wallet
  /// is empty or asked the user first.
  Future<RestoreOutcome> restoreNow() => _track(_restoreNow);

  Future<RestoreOutcome> _restoreNow() async {
    final userId = _userId;
    if (userId == null) return RestoreOutcome.unavailable;
    final result = await _ref.read(walletBackupClientProvider).pull();
    if (!_isCurrent(userId)) return RestoreOutcome.unavailable;
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
    await _recordSynced(userId, snapshot, uploaded: false);
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
  Future<RestoreOutcome> maybeAutoRestore() => _track(_maybeAutoRestore);

  Future<RestoreOutcome> _maybeAutoRestore() async {
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
    if (!_isCurrent(userId)) return RestoreOutcome.unavailable;
    if (!empty) return RestoreOutcome.nothingToRestore;

    final outcome = await restoreNow();
    if (outcome == RestoreOutcome.restored && _isCurrent(userId)) {
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

/// When this phone last uploaded a backup, or null if it never has.
final lastBackupAtProvider = FutureProvider<DateTime?>((ref) async {
  final userId = ref.watch(authProvider.select((s) => s.userId));
  if (userId == null) return null;
  return _settings.getLastBackupAt(userId);
});

/// Cards in the stored backup this phone lacks, while automatic backup is
/// held back rather than overwrite them; 0 otherwise. See
/// [WalletBackupController.maybeAutoBackup].
final backupHeldCardsProvider = FutureProvider<int>((ref) async {
  final userId = ref.watch(authProvider.select((s) => s.userId));
  if (userId == null) return 0;
  return _settings.getBackupHeldCards(userId);
});

final walletBackupControllerProvider = Provider<WalletBackupController>(
  WalletBackupController.new,
);
