import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/data_repository.dart';
import '../api/settings_repository.dart';
import '../api/sophtron_auth_service.dart';
import '../api/bank_client.dart';
import '../util/logger.dart';
import '../util/popular_banks.dart';
import 'auth_provider.dart';

/// In-memory map of `PopularBank.displayName` → top Sophtron search hit
/// (the same `Map<String, dynamic>` shape the picker's search-results list
/// renders, with `InstitutionID`, `InstitutionName`, `Logo`).
///
/// Backed by a single JSON blob in the `settings` table so the Add Bank
/// picker can render brand logos and skip the resolve round-trip on tap.
/// Refreshed on app start (when auth resolves) and after every successful
/// sync - both no-ops if Sophtron creds aren't configured.
class PopularBanksCacheNotifier
    extends Notifier<Map<String, Map<String, dynamic>>> {
  late final DataRepository _repo = DataRepository();
  late final SettingsRepository _settings = SettingsRepository(_repo);

  bool _refreshing = false;

  @override
  Map<String, Map<String, dynamic>> build() {
    final userId = ref.watch(authProvider).userId;
    if (userId == null) return const {};
    // Load from disk in a microtask so `build()` returns synchronously.
    // The picker reads `state` directly - fine for an empty initial render;
    // the disk load lands within the same frame on warm starts.
    Future.microtask(() => _load(userId));
    return const {};
  }

  Future<void> _load(String userId) async {
    final raw = await _settings.getPopularBanksCache(userId);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final next = <String, Map<String, dynamic>>{};
      decoded.forEach((k, v) {
        if (v is Map) next[k] = Map<String, dynamic>.from(v);
      });
      state = next;
    } catch (e, st) {
      Log.w('popular-banks-cache', 'failed to decode cache: $e\n$st');
    }
  }

  /// Re-fetch top hits for every `kPopularBanks` entry in parallel and
  /// persist. Best-effort: per-bank failures are swallowed (the cache
  /// keeps its previous value for that bank); a whole-call failure leaves
  /// state untouched. Reentrant calls are coalesced into the first.
  Future<void> refresh() async {
    if (_refreshing) return;
    if (!SophtronConfig.isConfigured) return;
    final userId = ref.read(authProvider).userId;
    if (userId == null) return;

    _refreshing = true;
    try {
      final client = BankClient();
      final next = Map<String, Map<String, dynamic>>.from(state);
      await Future.wait(
        kPopularBanks.map((bank) async {
          try {
            final list = await client.searchInstitutions(
              query: bank.searchQuery,
            );
            if (list.isEmpty) return;
            final sorted = list.toList()
              ..sort((a, b) {
                final an = _nameOf(a);
                final bn = _nameOf(b);
                final byLen = an.length.compareTo(bn.length);
                return byLen != 0 ? byLen : an.compareTo(bn);
              });
            final top = sorted.first;
            if (top is Map) {
              next[bank.displayName] = Map<String, dynamic>.from(top);
            }
          } catch (e) {
            Log.w(
              'popular-banks-cache',
              'refresh failed for ${bank.displayName}: $e',
            );
          }
        }),
      );
      state = next;
      await _settings.setPopularBanksCache(userId, jsonEncode(next));
    } finally {
      _refreshing = false;
    }
  }

  static String _nameOf(dynamic inst) {
    if (inst is! Map) return '';
    return (inst['InstitutionName'] ?? inst['institutionName'])?.toString() ??
        '';
  }
}

final popularBanksCacheProvider =
    NotifierProvider<
      PopularBanksCacheNotifier,
      Map<String, Map<String, dynamic>>
    >(PopularBanksCacheNotifier.new);
