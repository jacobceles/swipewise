import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import 'auth_provider.dart';
import 'data_providers.dart';
import 'bank_sync_provider.dart';
import '../api/data_repository.dart';
import '../api/settings_repository.dart';
import '../nearby/place_roots.dart';

export '../api/settings_repository.dart' show DefaultScreen, AdvisorView;

const _kSyncTaskName = 'bankBackgroundSync';
const _kSyncUniqueName = '1';

String defaultScreenLabel(DefaultScreen s) {
  switch (s) {
    case DefaultScreen.transactions:
      return 'Transactions';
    case DefaultScreen.cards:
      return 'Cards';
    case DefaultScreen.breakdown:
      return 'Breakdown';
    case DefaultScreen.advisor:
      return 'Advisor';
    case DefaultScreen.profile:
      return 'Profile';
  }
}

String advisorViewLabel(AdvisorView v) {
  switch (v) {
    case AdvisorView.stores:
      return 'Stores';
    case AdvisorView.categories:
      return 'Categories';
    case AdvisorView.brands:
      return 'Brands';
  }
}

final _settings = SettingsRepository(DataRepository());

class AutoSyncNotifier extends Notifier<bool> {
  @override
  bool build() {
    final auth = ref.watch(authProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getAutoSync(auth.userId!);
        if (state != loaded) state = loaded;
        await _applyToWorkManager(loaded);
      });
    }
    return false;
  }

  Future<void> setEnabled(bool enabled) async {
    final userId = ref.read(authProvider).userId;
    state = enabled;
    if (userId != null) await _settings.setAutoSync(userId, enabled);
    await _applyToWorkManager(enabled);
  }

  Future<void> _applyToWorkManager(bool enabled) async {
    if (enabled) {
      // setInitialDelay spreads the first sync 0–10 min after registration,
      // so devices waking on the same OS tick don't all hit the API at the
      // same instant. Sleeping inside the dispatcher (the prior approach)
      // held the worker process alive past Android 12's foreground-service
      // threshold.
      final jitterSecs = Random().nextInt(10 * 60);
      await Workmanager().registerPeriodicTask(
        _kSyncUniqueName,
        _kSyncTaskName,
        frequency: const Duration(hours: 8),
        initialDelay: Duration(seconds: jitterSecs),
      );
    } else {
      await Workmanager().cancelByUniqueName(_kSyncUniqueName);
    }
  }
}

class DefaultScreenNotifier extends Notifier<DefaultScreen> {
  @override
  DefaultScreen build() {
    final auth = ref.watch(authProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getDefaultScreen(auth.userId!);
        if (state != loaded) state = loaded;
      });
    }
    return DefaultScreen.transactions;
  }

  Future<void> set(DefaultScreen s) async {
    final userId = ref.read(authProvider).userId;
    state = s;
    if (userId != null) await _settings.setDefaultScreen(userId, s);
  }
}

class AdvisorViewNotifier extends Notifier<AdvisorView> {
  @override
  AdvisorView build() {
    final auth = ref.watch(authProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getDefaultAdvisorView(auth.userId!);
        if (state != loaded) state = loaded;
      });
    }
    return AdvisorView.stores;
  }

  Future<void> set(AdvisorView v) async {
    final userId = ref.read(authProvider).userId;
    state = v;
    if (userId != null) await _settings.setDefaultAdvisorView(userId, v);
  }
}

final autoSyncProvider = NotifierProvider<AutoSyncNotifier, bool>(
  AutoSyncNotifier.new,
);

final defaultScreenProvider =
    NotifierProvider<DefaultScreenNotifier, DefaultScreen>(
      DefaultScreenNotifier.new,
    );

final advisorViewProvider = NotifierProvider<AdvisorViewNotifier, AdvisorView>(
  AdvisorViewNotifier.new,
);

class NearbyEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final auth = ref.watch(sessionProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getNearbyEnabled(auth.userId!);
        if (state != loaded) state = loaded;
      });
    }
    return true;
  }

  Future<void> setEnabled(bool enabled) async {
    final userId = ref.read(authProvider).userId;
    state = enabled;
    if (userId != null) await _settings.setNearbyEnabled(userId, enabled);
  }
}

class NearbyRadiusNotifier extends Notifier<int> {
  @override
  int build() {
    final auth = ref.watch(sessionProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getNearbyRadiusMi(auth.userId!);
        if (state != loaded) state = loaded;
      });
    }
    return 10;
  }

  Future<void> set(int miles) async {
    final userId = ref.read(authProvider).userId;
    state = miles;
    if (userId != null) await _settings.setNearbyRadiusMi(userId, miles);
  }
}

class NearbyDwellNotifier extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() {
    final auth = ref.watch(sessionProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getDwellSecondsByCategory(auth.userId!);
        state = loaded;
      });
    }
    return Map.of(SettingsRepository.defaultDwellSeconds);
  }

  Future<void> setSeconds(String category, int seconds) async {
    final userId = ref.read(authProvider).userId;
    final next = Map<String, int>.of(state)..[category] = seconds;
    state = next;
    if (userId != null) {
      await _settings.setDwellSecondsByCategory(userId, next);
    }
  }
}

final nearbyEnabledProvider = NotifierProvider<NearbyEnabledNotifier, bool>(
  NearbyEnabledNotifier.new,
);

final nearbyRadiusProvider = NotifierProvider<NearbyRadiusNotifier, int>(
  NearbyRadiusNotifier.new,
);

final nearbyDwellProvider =
    NotifierProvider<NearbyDwellNotifier, Map<String, int>>(
      NearbyDwellNotifier.new,
    );

class NearbyPlaceTypesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final auth = ref.watch(sessionProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getNearbyPlaceTypeIds(auth.userId!);
        // Guard on contents, not identity: `getNearbyPlaceTypeIds` returns a
        // fresh Set each call, so a bare `state = loaded` would notify
        // watchers (re-running the nearby chain) even when nothing changed.
        if (loaded != null &&
            (loaded.length != state.length || !loaded.containsAll(state))) {
          state = loaded;
        }
      });
    }
    return defaultEnabledPlaceRootIds;
  }

  Future<void> setAll(Set<String> ids) async {
    final userId = ref.read(authProvider).userId;
    state = ids;
    if (userId != null) await _settings.setNearbyPlaceTypeIds(userId, ids);
  }

  Future<void> toggle(String id) async {
    final next = Set<String>.of(state);
    if (!next.add(id)) next.remove(id);
    await setAll(next);
  }

  Future<void> resetToDefault() => setAll(defaultEnabledPlaceRootIds);
}

final nearbyPlaceTypesProvider =
    NotifierProvider<NearbyPlaceTypesNotifier, Set<String>>(
      NearbyPlaceTypesNotifier.new,
    );

class CardPreferenceOrderNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async {
    final auth = ref.watch(authProvider);
    if (auth.userId == null) return const [];
    return _settings.getCardPreferenceOrder(auth.userId!);
  }

  Future<void> set(List<String> ids) async {
    final userId = ref.read(authProvider).userId;
    final next = List<String>.unmodifiable(ids);
    state = AsyncData(next);
    if (userId != null) {
      await _settings.setCardPreferenceOrder(userId, next);
    }
  }
}

final cardPreferenceOrderProvider =
    AsyncNotifierProvider<CardPreferenceOrderNotifier, List<String>>(
      CardPreferenceOrderNotifier.new,
    );

/// Flips true once `NearbyPermissionGate` has finished running (or was
/// skipped because we'd already asked). The Stores-tab nearby providers
/// watch this and return empty until it's true so their `Geolocator`
/// permission request doesn't race the gate's own prompts - that race
/// caused `permission_handler`'s bulk request to silently return null on
/// fresh installs, hiding the notification + activity-recognition dialogs.
class PermissionGateCompleteNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void markComplete() {
    if (!state) state = true;
  }
}

final permissionGateCompleteProvider =
    NotifierProvider<PermissionGateCompleteNotifier, bool>(
      PermissionGateCompleteNotifier.new,
    );

/// Whether the first-run welcome screen has already been answered.
///
/// `/` renders the welcome screen until this is true, which puts the
/// sign-in-or-skip choice ahead of everything else — including the four OS
/// permission dialogs, which only fire once `HomeScreen` builds.
class OnboardingSeenNotifier extends AsyncNotifier<bool> {
  /// Sticky for the life of the provider. Signing in re-keys `users.id` from
  /// the local UUID to the Firebase UID, which changes the value watched
  /// below and rebuilds this notifier — and that rebuild would re-read the
  /// flag under the *new* id, where nothing has been written yet, throwing
  /// the user back to the welcome screen at the exact moment they finished
  /// with it. Once answered, the answer stands.
  bool _answered = false;

  @override
  Future<bool> build() async {
    if (_answered) return true;
    final userId = ref.watch(authProvider.select((s) => s.userId));
    if (userId == null) {
      // The device-local identity is minted asynchronously on first launch,
      // so a null id here means "not known yet", not "new user". Answering
      // false would flash the welcome screen on *every* launch; instead stay
      // in `loading` and let the watch above rebuild us when the id lands.
      //
      // The delay is a floor, not a wait: if identity arrives first this
      // future is discarded. It only matters when identity never arrives at
      // all, and then falling through to the welcome screen is the right
      // failure — it is still skippable. Ten seconds matches the identity
      // timeout `HomeScreen` uses for the permission gate.
      return Future<bool>.delayed(const Duration(seconds: 10), () => false);
    }
    return _settings.getOnboardingSeen(userId);
  }

  /// Records that the choice was made, and shows the app immediately rather
  /// than waiting on the write.
  Future<void> markSeen() async {
    final userId = ref.read(authProvider).userId;
    _answered = true;
    state = const AsyncData(true);
    if (userId != null) await _settings.setOnboardingSeen(userId);
  }
}

final onboardingSeenProvider =
    AsyncNotifierProvider<OnboardingSeenNotifier, bool>(
      OnboardingSeenNotifier.new,
    );

/// "Include debit accounts" - when ON, Sophtron sync pulls deposit
/// accounts (checking/savings) alongside credit cards. Default OFF.
///
/// On change: flip immediately on the UI (state=enabled), then act:
///   - ON  → trigger a sync to backfill the deposit data.
///   - OFF → prune deposit rows locally so the UI reflects it without
///           waiting for the next sync.
/// Either direction gives instant feedback; "ON" still needs network.
class IncludeDebitAccountsNotifier extends Notifier<bool> {
  @override
  bool build() {
    final auth = ref.watch(authProvider);
    if (auth.userId != null) {
      Future.microtask(() async {
        final loaded = await _settings.getIncludeDebitAccounts(auth.userId!);
        if (state != loaded) state = loaded;
      });
    }
    return false;
  }

  Future<void> setEnabled(bool enabled) async {
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;
    state = enabled;
    await _settings.setIncludeDebitAccounts(userId, enabled);
    if (enabled) {
      // Backfill via a normal sync. Provider invalidates consumers when
      // it finishes.
      // ignore: unawaited_futures
      ref.read(bankSyncProvider.notifier).runSync();
    } else {
      // Cheap local-only prune so deposit txs / accounts disappear
      // immediately. Future syncs already skip them because the engine
      // reads the setting at run start.
      await DataRepository().pruneDebitBankData(userId);
      for (final p in syncInvalidatedProviders) {
        ref.invalidate(p);
      }
    }
  }
}

final includeDebitAccountsProvider =
    NotifierProvider<IncludeDebitAccountsNotifier, bool>(
      IncludeDebitAccountsNotifier.new,
    );
