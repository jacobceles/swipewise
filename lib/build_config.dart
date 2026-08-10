/// Build-time configuration. Not a feature switch — see `proEntitlementProvider`
/// in `providers/entitlement_provider.dart` for that.
class BuildConfig {
  const BuildConfig._();

  /// Seed for the Pro entitlement until the entitlement server exists.
  ///
  /// Set by `--dart-define=SWIPEWISE_PRO=true` (carried in `keys.pro.json`) and
  /// absent everywhere else, so the published build fails closed. It is the
  /// *temporary source* of the answer, not the mechanism: UI asks
  /// `proEntitlementProvider`, and when the server lands only that provider's
  /// body changes — every call site stays put.
  ///
  /// Deliberately `static final`, not `static const`. A const would let the
  /// compiler prove `if (isPro)` false and delete the Pro code outright, which
  /// is exactly what an earlier revision did. That is wrong now: Pro is sold as
  /// an in-app subscription, so the code has to be *present and dormant* in the
  /// one binary everyone installs, ready to light up when the server says the
  /// user has paid. What must stay out of that binary is the credentials, and
  /// those never come from here.
  static final bool proSeed = const bool.fromEnvironment('SWIPEWISE_PRO');
}
