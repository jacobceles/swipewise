import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'app_check_service.dart';

/// Why a delete can't finish, when it can't.
enum DeleteFailure {
  /// No signed-in user, or no account service configured.
  unavailable,

  /// Firebase refused because the sign-in is too old. The user has to sign in
  /// again before the account can be removed — Google's rule, not ours.
  needsRecentLogin,

  /// The service could not be reached, or refused.
  failed,
}

/// Deletes everything held server-side for the signed-in user.
///
/// ⚠️ **Order is load-bearing.** This must run *before* the Firebase account is
/// deleted, because it authenticates with an ID token that stops existing the
/// moment the account does. Delete Firebase first and the server rows become
/// unreachable orphans — the user is gone, their data is not, and nothing can
/// ever find it again.
class AccountDeleteClient {
  AccountDeleteClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _kRawBaseUrl = String.fromEnvironment('ACCOUNT_API_URL');
  static final String _kBaseUrl = _kRawBaseUrl.replaceAll(RegExp(r'/+$'), '');
  static const _timeout = Duration(seconds: 30);

  static bool get isConfigured => _kBaseUrl.isNotEmpty;

  /// Returns null on success, or why it failed.
  Future<DeleteFailure?> deleteServerSide() async {
    if (!isConfigured) return DeleteFailure.unavailable;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return DeleteFailure.unavailable;

    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return DeleteFailure.unavailable;
      final headers = {'Authorization': 'Bearer $token'};
      final appCheck = await AppCheckService.token();
      if (appCheck != null) headers['X-Firebase-AppCheck'] = appCheck;

      final resp = await _client
          .delete(Uri.parse('$_kBaseUrl/account'), headers: headers)
          .timeout(_timeout);
      final ok = resp.statusCode >= 200 && resp.statusCode < 300;
      return ok ? null : DeleteFailure.failed;
    } catch (_) {
      return DeleteFailure.failed;
    }
  }

  /// Deletes the Firebase account itself. Call only after [deleteServerSide].
  Future<DeleteFailure?> deleteFirebaseUser() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null; // already gone; nothing to do
    try {
      await user.delete();
      return null;
    } on FirebaseAuthException catch (e) {
      // Firebase requires a fresh sign-in before destructive account changes.
      // Surfaced rather than swallowed: the user has to act, and "it didn't
      // work" with no reason is the worst possible answer here.
      if (e.code == 'requires-recent-login') return DeleteFailure.needsRecentLogin;
      return DeleteFailure.failed;
    } catch (_) {
      return DeleteFailure.failed;
    }
  }
}
