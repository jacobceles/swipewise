import 'package:flutter_test/flutter_test.dart';
import 'package:swipewise/api/settings_repository.dart';

import 'package:swipewise/widgets/app_tab_bar.dart';

/// `HomeScreen` indexes its `IndexedStack` by position in [kShellTabs], and
/// resolves the saved "default screen" preference through
/// [shellTabForDefaultScreen]. Both are easy to get subtly wrong — a tab this
/// build doesn't have yields `indexOf == -1`, which throws inside
/// `IndexedStack` rather than failing anywhere legible.
void main() {
  test('without Pro, the transaction-backed tab is absent', () {
    expect(shellTabs(false), [
      ShellTab.cards,
      ShellTab.advisor,
      ShellTab.profile,
    ]);
  });

  test('with Pro, all four appear and the shared order is preserved', () {
    // Pro inserts its tab, it does not reshuffle: Cards still precedes
    // Advisor which still precedes Profile, so a user who subscribes does not
    // find their tab bar rearranged underneath them.
    final pro = shellTabs(true);
    expect(pro, hasLength(4));
    expect(
      pro.where((t) => shellTabs(false).contains(t)).toList(),
      shellTabs(false),
    );
  });

  test('every DefaultScreen maps to a real tab', () {
    for (final s in DefaultScreen.values) {
      expect(
        shellTabForDefaultScreen(s),
        isA<ShellTab>(),
        reason: '$s has no tab',
      );
    }
  });

  test('the mapping is injective, so no two settings collide', () {
    final tabs = DefaultScreen.values.map(shellTabForDefaultScreen).toSet();
    expect(tabs, hasLength(DefaultScreen.values.length));
  });

  test('the shipped default names a tab free does NOT have', () {
    // The reason `HomeScreen` can't just seed `_active` from the shipped
    // default: it is `transactions`, and free has no such tab. If this ever
    // changes, the seeding comment there is stale.
    expect(
      shellTabs(
        false,
      ).contains(shellTabForDefaultScreen(DefaultScreen.transactions)),
      isFalse,
    );
  });

  test('Advisor is available as the fallback landing tab', () {
    // `_shellTabFromDefault` falls through to Advisor for any preference this
    // build can't honour, so Advisor must always be present.
    expect(shellTabs(false), contains(ShellTab.advisor));
    expect(shellTabs(true), contains(ShellTab.advisor));
  });

  test('the Profile row never claims a tab this build lacks', () {
    // The stored preference is left alone (a later Pro install should still
    // honour it) — only the *displayed* value is resolved.
    expect(
      effectiveDefaultScreen(DefaultScreen.transactions, isPro: false),
      DefaultScreen.advisor,
    );
    // ...and a Pro user keeps theirs.
    expect(
      effectiveDefaultScreen(DefaultScreen.transactions, isPro: true),
      DefaultScreen.transactions,
    );
    for (final s in [
      DefaultScreen.cards,
      DefaultScreen.advisor,
      DefaultScreen.profile,
    ]) {
      expect(
        effectiveDefaultScreen(s, isPro: false),
        s,
        reason: '$s exists without Pro',
      );
    }
  });

  test('tab order is stable — indices are what IndexedStack keys on', () {
    expect(shellTabs(false).indexOf(ShellTab.cards), 0);
    expect(shellTabs(false).indexOf(ShellTab.advisor), 1);
    expect(shellTabs(false).indexOf(ShellTab.profile), 2);
  });
}
