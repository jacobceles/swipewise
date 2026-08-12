import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'app_check_service.dart';

/// Asks the account service whether this user is Pro.
///
/// Returns null for "could not find out" — no network, not signed in, no
/// service configured — which is deliberately different from `false`. The
/// caller keeps its cached answer on null and only downgrades on an explicit
/// `false`, so a flat battery on a plane does not demote a subscriber.
class EntitlementClient {
  EntitlementClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _kRawBaseUrl = String.fromEnvironment('ACCOUNT_API_URL');
  static final String _kBaseUrl = _kRawBaseUrl.replaceAll(RegExp(r'/+$'), '');
  static const _timeout = Duration(seconds: 10);

  static bool get isConfigured => _kBaseUrl.isNotEmpty;

  Future<bool?> isPro() async {
    if (!isConfigured) return null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    try {
      final token = await user.getIdToken();
      if (token == null || token.isEmpty) return null;
      final headers = {'Authorization': 'Bearer $token'};
      final appCheck = await AppCheckService.token();
      if (appCheck != null) headers['X-Firebase-AppCheck'] = appCheck;

      final resp = await _client
          .get(Uri.parse('$_kBaseUrl/entitlement'), headers: headers)
          .timeout(_timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded['pro'] == true;
    } catch (_) {
      return null;
    }
  }
}
