import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../api/app_check_service.dart';
import 'wallet_snapshot.dart';

/// Outcome of a backup call, so callers can tell "nothing there" apart from
/// "it went wrong" — the two need opposite handling and a bool cannot say
/// which happened.
enum BackupStatus {
  ok,

  /// The service has no backup for this user yet. Expected, not an error.
  empty,

  /// No signed-in user, or no service configured in this build.
  unavailable,

  /// Reached the service and it refused or failed.
  failed,
}

class BackupResult {
  const BackupResult(this.status, [this.snapshot]);
  final BackupStatus status;
  final WalletSnapshot? snapshot;
}

/// Talks to the wallet sync service.
///
/// Two tokens on every call, the same pairing the Places proxy already uses: a
/// Firebase ID token proves *which user*, and an App Check token proves *a
/// genuine install*. Neither substitutes for the other — App Check says "a
/// real copy of the app", not "this person".
///
/// The service URL is a `--dart-define`. When it is unset the client reports
/// [BackupStatus.unavailable] rather than throwing, so a build without a sync
/// service configured simply has no backup feature instead of a broken one.
class WalletBackupClient {
  WalletBackupClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _kBaseUrl = String.fromEnvironment('SYNC_API_URL');
  static const _timeout = Duration(seconds: 20);

  /// Whether this build has a sync service at all.
  static bool get isConfigured => _kBaseUrl.isNotEmpty;

  Future<Map<String, String>?> _authHeaders() async {
    if (!isConfigured) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final String idToken;
    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return null;
      idToken = token;
    } catch (_) {
      return null;
    }
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $idToken',
    };
    // Best-effort: a missing App Check token is left to the service to reject
    // on its own terms, exactly as `AppCheckService` documents.
    final appCheck = await AppCheckService.token();
    if (appCheck != null) headers['X-Firebase-AppCheck'] = appCheck;
    return headers;
  }

  /// Uploads [snapshot], replacing whatever the service holds for this user.
  Future<BackupStatus> push(WalletSnapshot snapshot) async {
    final headers = await _authHeaders();
    if (headers == null) return BackupStatus.unavailable;
    try {
      final resp = await _client
          .put(
            Uri.parse('$_kBaseUrl/wallet'),
            headers: headers,
            body: jsonEncode(snapshot.toJson()),
          )
          .timeout(_timeout);
      return resp.statusCode >= 200 && resp.statusCode < 300
          ? BackupStatus.ok
          : BackupStatus.failed;
    } catch (_) {
      return BackupStatus.failed;
    }
  }

  /// Fetches this user's backup, if the service holds one.
  Future<BackupResult> pull() async {
    final headers = await _authHeaders();
    if (headers == null) return const BackupResult(BackupStatus.unavailable);
    try {
      final resp = await _client
          .get(Uri.parse('$_kBaseUrl/wallet'), headers: headers)
          .timeout(_timeout);
      if (resp.statusCode == 404) return const BackupResult(BackupStatus.empty);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return const BackupResult(BackupStatus.failed);
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        return const BackupResult(BackupStatus.failed);
      }
      final snapshot = WalletSnapshot.fromJson(decoded);
      // An empty payload is "nothing to restore", not something to apply over
      // a wallet.
      if (snapshot.isEmpty) return const BackupResult(BackupStatus.empty);
      return BackupResult(BackupStatus.ok, snapshot);
    } catch (_) {
      return const BackupResult(BackupStatus.failed);
    }
  }
}
