import 'dart:convert';

import '../util/logger.dart';
import 'data_repository.dart';

/// Typed accessors over the `settings` key/value table. Each setting has
/// exactly one read and one write method here so the default and the
/// serialization shape are colocated - no string-comparison drift between
/// the UI and the background worker.
class SettingsRepository {
  SettingsRepository(this._repo);
  final DataRepository _repo;

  static const _kAutoSync = 'auto_sync';
  static const _kDefaultScreen = 'default_screen';
  static const _kDefaultAdvisorView = 'default_advisor_view';
  static const _kLastSyncAt = 'last_sync_at';
  static const _kNearbyEnabled = 'nearby_enabled';
  static const _kNearbyRadiusMi = 'nearby_radius_mi';
  static const _kNearbyDwellSecondsByCategory = 'nearby_dwell_by_category';
  static const _kNearbyPlaceTypeIds = 'nearby_place_type_ids';
  static const _kPermissionsAsked = 'permissions_asked';
  static const _kOnboardingSeen = 'onboarding_seen';
  static const _kCardPreferenceOrder = 'card_preference_order';
  static const _kDismissedRecurringTips = 'dismissed_recurring_tips';
  static const _kIncludeDebitAccounts = 'include_debit_accounts';
  static const _kPopularBanksCache = 'popular_banks_cache';
  static const _kCatalogDataVersion = 'catalog_data_version';
  static const _kPaymentRemindersEnabled = 'payment_reminders_enabled';
  static const _kPaymentReminderLeadDays = 'payment_reminder_lead_days';

  // Auto sync: default OFF. The background worker also reads this, so the
  // default has to be defined in one place.
  Future<bool> getAutoSync(String userId) async {
    final raw = await _repo.getSetting(userId, _kAutoSync);
    return raw == 'true';
  }

  Future<void> setAutoSync(String userId, bool enabled) =>
      _repo.setSetting(userId, _kAutoSync, enabled.toString());

  // Default screen on launch.
  Future<DefaultScreen> getDefaultScreen(String userId) async {
    final raw = await _repo.getSetting(userId, _kDefaultScreen);
    return DefaultScreen.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => DefaultScreen.transactions,
    );
  }

  Future<void> setDefaultScreen(String userId, DefaultScreen screen) =>
      _repo.setSetting(userId, _kDefaultScreen, screen.name);

  // Default advisor view (stores / categories / brands).
  Future<AdvisorView> getDefaultAdvisorView(String userId) async {
    final raw = await _repo.getSetting(userId, _kDefaultAdvisorView);
    return AdvisorView.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => AdvisorView.stores,
    );
  }

  Future<void> setDefaultAdvisorView(String userId, AdvisorView view) =>
      _repo.setSetting(userId, _kDefaultAdvisorView, view.name);

  // Timestamp of the most recent successful Sophtron sync. Used by the
  // dashboard "Last synced ..." indicator. Written by the sync provider on
  // success; never set by anything else.
  Future<DateTime?> getLastSyncAt(String userId) async {
    final raw = await _repo.getSetting(userId, _kLastSyncAt);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setLastSyncAt(String userId, DateTime when) =>
      _repo.setSetting(userId, _kLastSyncAt, when.toUtc().toIso8601String());

  // Per-member timestamp of the last successful refresh *job* (re-scrape) -
  // distinct from last_sync_at (any successful read). Throttles re-scrapes on
  // background/app-open syncs so we don't hammer issuer rate limits;
  // user-initiated syncs bypass the throttle (forceRefresh).
  static String _memberRefreshedKey(String memberId) =>
      'member_refreshed_at:$memberId';

  Future<DateTime?> getMemberRefreshedAt(String userId, String memberId) async {
    final raw = await _repo.getSetting(userId, _memberRefreshedKey(memberId));
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setMemberRefreshedAt(
    String userId,
    String memberId,
    DateTime when,
  ) => _repo.setSetting(
    userId,
    _memberRefreshedKey(memberId),
    when.toUtc().toIso8601String(),
  );

  // Per-member JobID of the most recent refresh job whose outcome hasn't
  // been confirmed yet. The sync's poll window is shorter than many live
  // scrapes, so a job routinely finishes (or fails) server-side after the
  // engine stops watching; the next sync reads this to check that outcome
  // before triggering another scrape. Cleared (empty value — the settings
  // table has no delete) once the outcome is known.
  static String _memberRefreshJobKey(String memberId) =>
      'member_refresh_job:$memberId';

  Future<String?> getMemberRefreshJobId(String userId, String memberId) async {
    final raw = await _repo.getSetting(userId, _memberRefreshJobKey(memberId));
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  Future<void> setMemberRefreshJobId(
    String userId,
    String memberId,
    String jobId,
  ) => _repo.setSetting(userId, _memberRefreshJobKey(memberId), jobId);

  Future<void> clearMemberRefreshJobId(String userId, String memberId) =>
      _repo.setSetting(userId, _memberRefreshJobKey(memberId), '');

  // Nearby stores: feature toggle, default ON. We ask the four required
  // permissions once at first HomeScreen paint via NearbyPermissionGate,
  // so the feature is usable out of the box.
  Future<bool> getNearbyEnabled(String userId) async {
    final raw = await _repo.getSetting(userId, _kNearbyEnabled);
    if (raw == null) return true;
    return raw == 'true';
  }

  Future<void> setNearbyEnabled(String userId, bool enabled) =>
      _repo.setSetting(userId, _kNearbyEnabled, enabled.toString());

  // Payment-due reminders (N12). Default OFF, unlike nearby: a reminder is only
  // meaningful once the user has typed a due day (banks don't supply one), so
  // defaulting ON would promise notifications that can never fire.
  Future<bool> getPaymentRemindersEnabled(String userId) async =>
      await _repo.getSetting(userId, _kPaymentRemindersEnabled) == 'true';

  Future<void> setPaymentRemindersEnabled(String userId, bool enabled) =>
      _repo.setSetting(userId, _kPaymentRemindersEnabled, enabled.toString());

  /// How many days before the due date to fire. Default 3.
  Future<int> getPaymentReminderLeadDays(String userId) async {
    final raw = await _repo.getSetting(userId, _kPaymentReminderLeadDays);
    return int.tryParse(raw ?? '') ?? 3;
  }

  Future<void> setPaymentReminderLeadDays(String userId, int days) =>
      _repo.setSetting(userId, _kPaymentReminderLeadDays, days.toString());

  // Search radius (5 / 10 / 25 mi). Default 10.
  Future<int> getNearbyRadiusMi(String userId) async {
    final raw = await _repo.getSetting(userId, _kNearbyRadiusMi);
    final parsed = int.tryParse(raw ?? '');
    if (parsed == 5 || parsed == 10 || parsed == 25) return parsed!;
    return 10;
  }

  Future<void> setNearbyRadiusMi(String userId, int miles) =>
      _repo.setSetting(userId, _kNearbyRadiusMi, miles.toString());

  // Per-category dwell seconds. Stored as a CSV "<category>:<seconds>,..." to
  // keep the settings table value column simple. Defaults are baked in here.
  static const Map<String, int> defaultDwellSeconds = {
    'Dining': 60,
    'Coffee': 60,
    'Shopping': 60,
    'Big-box': 60,
    'Grocery': 60,
    'Gas': 60,
  };

  /// Stored as JSON now: `{"Dining": 60, "Coffee": 60, ...}`. Replaced
  /// the prior CSV `Dining:60,Coffee:60,...` because any future category
  /// label containing `:` or `,` would silently break the parser. On
  /// read, legacy CSV values are still accepted so users who upgraded
  /// without re-saving don't see defaults reappear.
  Future<Map<String, int>> getDwellSecondsByCategory(String userId) async {
    final raw = await _repo.getSetting(userId, _kNearbyDwellSecondsByCategory);
    if (raw == null || raw.isEmpty) return Map.of(defaultDwellSeconds);
    final out = Map<String, int>.of(defaultDwellSeconds);
    if (raw.startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key.toString();
            final v = entry.value;
            final secs = v is num ? v.toInt() : int.tryParse('$v');
            if (key.isEmpty || secs == null) continue;
            out[key] = secs;
          }
          return out;
        }
      } catch (e) {
        Log.w('settings', 'failed to decode dwell JSON; falling through', e);
      }
    }
    // Legacy CSV fallback.
    for (final pair in raw.split(',')) {
      final i = pair.indexOf(':');
      if (i <= 0) continue;
      final key = pair.substring(0, i).trim();
      final secs = int.tryParse(pair.substring(i + 1).trim());
      if (key.isEmpty || secs == null) continue;
      out[key] = secs;
    }
    return out;
  }

  Future<void> setDwellSecondsByCategory(
    String userId,
    Map<String, int> values,
  ) {
    return _repo.setSetting(
      userId,
      _kNearbyDwellSecondsByCategory,
      jsonEncode(values),
    );
  }

  /// Google Places root group IDs the user wants included in Nearby Stores
  /// (e.g. `{'dining', 'retail', 'travel'}`). Stored as comma-separated.
  /// Returns null when no setting exists — callers fall back to
  /// [defaultEnabledPlaceRootIds] from `place_roots.dart`.
  Future<Set<String>?> getNearbyPlaceTypeIds(String userId) async {
    final raw = await _repo.getSetting(userId, _kNearbyPlaceTypeIds);
    if (raw == null) return null;
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  Future<void> setNearbyPlaceTypeIds(String userId, Set<String> ids) {
    return _repo.setSetting(userId, _kNearbyPlaceTypeIds, ids.join(','));
  }

  /// User-defined card preference, used as a tiebreaker when two cards earn
  /// the same rate. Earlier in the list = preferred. Cards not in the list
  /// (e.g. a card added after the user last reordered) sort to the end.
  Future<List<String>> getCardPreferenceOrder(String userId) async {
    final raw = await _repo.getSetting(userId, _kCardPreferenceOrder);
    if (raw == null || raw.isEmpty) return const [];
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> setCardPreferenceOrder(String userId, List<String> ids) {
    final csv = ids.where((id) => id.isNotEmpty).join(',');
    return _repo.setSetting(userId, _kCardPreferenceOrder, csv);
  }

  /// Recurring-payment ids the user dismissed the "switch card" nudge for.
  /// Stored as a comma-set; the nudge itself is recomputed live, only the
  /// dismissed set persists.
  Future<Set<String>> getDismissedRecurringTips(String userId) async {
    final raw = await _repo.getSetting(userId, _kDismissedRecurringTips);
    if (raw == null || raw.isEmpty) return const {};
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  Future<void> setDismissedRecurringTips(String userId, Set<String> ids) {
    return _repo.setSetting(userId, _kDismissedRecurringTips, ids.join(','));
  }

  /// Whether we've already shown the OS permission prompts for this user.
  /// Set to true after the one-shot ask on first HomeScreen entry - we
  /// don't re-prompt; users who deny can re-enable from system Settings.
  Future<bool> getPermissionsAsked(String userId) async {
    final raw = await _repo.getSetting(userId, _kPermissionsAsked);
    return raw == 'true';
  }

  Future<void> setPermissionsAsked(String userId) =>
      _repo.setSetting(userId, _kPermissionsAsked, 'true');

  /// Whether the first-run welcome screen has been answered — by signing in
  /// or by skipping. Both count: the point is that the choice was offered,
  /// not which way it went.
  ///
  /// Stored per user rather than per device so it survives the sign-in
  /// re-key. `settings` is in [kUserScopedTables], so someone who skips and
  /// later signs in carries this onto their Firebase UID instead of being
  /// asked all over again.
  Future<bool> getOnboardingSeen(String userId) async {
    final raw = await _repo.getSetting(userId, _kOnboardingSeen);
    return raw == 'true';
  }

  Future<void> setOnboardingSeen(String userId) =>
      _repo.setSetting(userId, _kOnboardingSeen, 'true');

  /// Whether deposit (checking / savings) accounts are pulled in by Sophtron
  /// sync alongside credit cards. Default OFF - most users only care about
  /// credit cards for rewards optimization, and skipping deposit-account
  /// transactions roughly halves sync time on a mixed bank like Chase.
  ///
  /// Toggling ON triggers an immediate re-sync to backfill. Toggling OFF
  /// prunes the deposit rows from the local DB and skips them on every
  /// future sync. The UI never lies - both directions give instant feedback.
  Future<bool> getIncludeDebitAccounts(String userId) async {
    final raw = await _repo.getSetting(userId, _kIncludeDebitAccounts);
    return raw == 'true';
  }

  Future<void> setIncludeDebitAccounts(String userId, bool enabled) =>
      _repo.setSetting(userId, _kIncludeDebitAccounts, enabled.toString());

  /// JSON-encoded cache of top Sophtron search hits for the popular banks
  /// grid in the Add Bank picker - one entry per `kPopularBanks` row,
  /// keyed by `displayName`. Refreshed on app start and after every
  /// successful sync; read synchronously by the picker so brand logos
  /// render with zero network latency.
  Future<String?> getPopularBanksCache(String userId) =>
      _repo.getSetting(userId, _kPopularBanksCache);

  Future<void> setPopularBanksCache(String userId, String jsonStr) =>
      _repo.setSetting(userId, _kPopularBanksCache, jsonStr);

  /// The `dataVersion` of the catalog currently hydrated into the local
  /// tables. `CatalogLoader` compares the bundle's `dataVersion` against this
  /// and re-hydrates only when they differ. Defaults to 0 (nothing loaded).
  Future<int> getLoadedCatalogDataVersion(String userId) async {
    final raw = await _repo.getSetting(userId, _kCatalogDataVersion);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<void> setLoadedCatalogDataVersion(String userId, int version) =>
      _repo.setSetting(userId, _kCatalogDataVersion, version.toString());
}

enum DefaultScreen { transactions, cards, breakdown, advisor, profile }

enum AdvisorView { stores, categories, brands }
