

class MissingSophtronCreds implements Exception {
  @override
  String toString() =>
      'Bank linking is unavailable: no account service configured '
      '(ACCOUNT_API_URL), or nobody is signed in. The aggregator credentials '
      'are no longer in the app — the service holds them.';
}

/// Client-side configuration for the bank aggregator.
///
/// **There are no credentials here any more.** `SOPHTRON_USER_ID`,
/// `SOPHTRON_ACCESS_KEY` and `SOPHTRON_CUSTOMER_SALT` used to be
/// `String.fromEnvironment` constants, which a release compiles in and
/// decompiling recovers — every subscriber would have held our aggregator
/// credentials, able to sign any request against our account for any customer.
/// They live in the account service now (B3-S1), which signs on our behalf
/// after checking who is asking and whether they are entitled.
///
/// The salt is gone rather than moved. It existed to derive a stable Customer
/// id (`sha256(email | salt)`) because there was no server to remember one —
/// which made it unrotatable forever, since changing it orphans every bank
/// link. The service stores the mapping instead, so there is nothing to derive
/// and nothing to leak.
class SophtronConfig {
  /// The account service, which proxies every aggregator call. Not the
  /// aggregator's own host — the app no longer talks to it directly.
  static const String _rawAccountUrl = String.fromEnvironment('ACCOUNT_API_URL');
  static final String accountBaseUrl = _rawAccountUrl.replaceAll(
    RegExp(r'/+$'),
    '',
  );

  /// Stands in for this user's Customer id in a proxied path. The server
  /// substitutes the real one, looked up from the verified token — so the app
  /// cannot name a Customer, because there is no field for it.
  static const String meToken = '~me';

  /// Whether bank linking can work at all. Now a question about *the service*
  /// being configured, not about baked-in secrets.
  static bool get isConfigured => accountBaseUrl.isNotEmpty;
}
