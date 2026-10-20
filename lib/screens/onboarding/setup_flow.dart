import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/card.dart';
import '../../models/reward_category.dart';
import '../../nearby/nearby_permission_gate.dart';
import '../../providers/data_providers.dart';
import '../../theme/app_theme.dart';
import '../../util/units.dart';
import '../add_cards_screen.dart';
import 'onboarding_ui.dart';

/// The screens after sign-in, drawn to the `wireframe.pen` section
/// "Onboarding v4 — hybrid".
enum FlowStep {
  cards, // 2a
  cardsAdded, // 2b
  notifications, // 3
  notificationsBlocked, // 3, Android won't ask again
  location, // 4
  locationBlocked, // 4-blocked
  always, // 5, Play's background-location disclosure
  done, // 6
  alertsOff, // 6b
  noCards, // 6c
}

/// What Android has granted, read fresh whenever the flow needs to decide.
class Perms {
  const Perms({
    this.notifications = false,
    this.notificationsBlocked = false,
    this.location = false,
    this.locationBlocked = false,
    this.always = false,
    this.activity = false,
    this.alarms = false,
    this.battery = false,
  });

  final bool notifications;
  final bool notificationsBlocked;
  final bool location;
  final bool locationBlocked;
  final bool always;
  final bool activity;
  final bool alarms;
  final bool battery;

  /// A store alert can reach the user only with both.
  bool get alertsOn => notifications && always;

  static Future<Perms> read() async {
    final n = await Permission.notification.status;
    final loc = await Geolocator.checkPermission();
    return Perms(
      notifications: n.isGranted,
      notificationsBlocked: n.isPermanentlyDenied,
      location:
          loc == LocationPermission.whileInUse ||
          loc == LocationPermission.always,
      locationBlocked: loc == LocationPermission.deniedForever,
      always: (await Permission.locationAlways.status).isGranted,
      activity: (await Permission.activityRecognition.status).isGranted,
      alarms: (await Permission.scheduleExactAlarm.status).isGranted,
      battery: (await Permission.ignoreBatteryOptimizations.status).isGranted,
    );
  }
}

/// The first alert step still to do, or [FlowStep.done]. A step Android
/// won't ask for again goes to its Settings screen.
FlowStep nextAlertStep(Perms p) {
  if (!p.notifications) {
    return p.notificationsBlocked
        ? FlowStep.notificationsBlocked
        : FlowStep.notifications;
  }
  if (!p.location) {
    return p.locationBlocked ? FlowStep.locationBlocked : FlowStep.location;
  }
  if (!p.always) return FlowStep.always;
  return FlowStep.done;
}

/// The tracker for [step]: done steps in their colour, the current one
/// ringed, and on "alerts off" the first missing step red.
Map<SetupStep, TrackState> trackerFor(FlowStep step, Perms p, bool hasCards) {
  final done = {
    SetupStep.cards: hasCards,
    SetupStep.notifications: p.notifications,
    SetupStep.location: p.location,
    SetupStep.always: p.always,
  };
  final now = switch (step) {
    FlowStep.cards => SetupStep.cards,
    FlowStep.notifications => SetupStep.notifications,
    FlowStep.location => SetupStep.location,
    FlowStep.always => SetupStep.always,
    _ => null,
  };
  final off = switch (step) {
    FlowStep.notificationsBlocked => SetupStep.notifications,
    FlowStep.locationBlocked => SetupStep.location,
    FlowStep.alertsOff => [
      SetupStep.notifications,
      SetupStep.location,
      SetupStep.always,
    ].firstWhere((s) => !done[s]!, orElse: () => SetupStep.always),
    _ => null,
  };
  if (step == FlowStep.noCards) {
    return {for (final s in SetupStep.values) s: TrackState.todo};
  }
  return {
    for (final s in SetupStep.values)
      s: s == off
          ? TrackState.off
          : done[s]!
          ? TrackState.done
          : s == now
          ? TrackState.now
          : TrackState.todo,
  };
}

/// Runs from Home over the app, as a full-screen route. Pops with true once
/// any alert permission has been offered, so Home stops asking on its own.
class SetupFlow extends ConsumerStatefulWidget {
  const SetupFlow({
    super.key,
    required this.start,
    this.readPerms = Perms.read,
  });
  final FlowStep start;

  /// Injectable so widget tests can run without Android's permission plugins.
  final Future<Perms> Function() readPerms;

  @override
  ConsumerState<SetupFlow> createState() => _SetupFlowState();
}

class _SetupFlowState extends ConsumerState<SetupFlow>
    with WidgetsBindingObserver {
  late FlowStep _step = widget.start;
  Perms _perms = const Perms();
  bool _offered = false;
  bool _busy = false;

  /// Waiting on the user in Android Settings: re-decide on return.
  bool _inSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _offered = _isAlertStep(widget.start);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static bool _isAlertStep(FlowStep s) =>
      s != FlowStep.cards && s != FlowStep.cardsAdded && s != FlowStep.noCards;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _refresh().then((_) {
      if (!_inSettings || !mounted) return;
      _inSettings = false;
      // Back from Settings: on to the next step if it's now granted,
      // otherwise the honest summary.
      final next = nextAlertStep(_perms);
      final unchanged =
          (_step == FlowStep.notificationsBlocked && !_perms.notifications) ||
          (_step == FlowStep.locationBlocked && !_perms.location);
      _go(unchanged ? FlowStep.alertsOff : _afterGrant(next));
    });
  }

  Future<void> _refresh() async {
    final p = await widget.readPerms();
    if (mounted) setState(() => _perms = p);
  }

  void _go(FlowStep step) {
    if (_isAlertStep(step)) _offered = true;
    setState(() => _step = step);
  }

  /// Every grant leads on to the next missing step, ending on the summary.
  FlowStep _afterGrant(FlowStep next) =>
      next == FlowStep.done && !_perms.alertsOn ? FlowStep.alertsOff : next;

  void _finish() => Navigator.of(context).pop(_offered);

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addCards() => _run(() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AddCardsScreen()));
    ref.invalidate(cardsProvider);
    final cards = await ref.read(cardsProvider.future);
    if (!mounted) return;
    if (cards.isNotEmpty) _go(FlowStep.cardsAdded);
  });

  Future<void> _continueToAlerts() async {
    await _refresh();
    if (!mounted) return;
    final next = nextAlertStep(_perms);
    _offered = true;
    _go(next);
  }

  Future<void> _askNotifications() => _run(() async {
    final r = await NearbyPermissionGate.askNotifications();
    await _refresh();
    if (!mounted) return;
    _go(switch (r) {
      AskResult.granted => _afterGrant(nextAlertStep(_perms)),
      AskResult.blocked => FlowStep.notificationsBlocked,
      // No notifications, no alert: location isn't asked for nothing.
      AskResult.denied => FlowStep.alertsOff,
    });
  });

  Future<void> _askLocation() => _run(() async {
    final r = await NearbyPermissionGate.askLocation();
    await _refresh();
    if (!mounted) return;
    _go(switch (r) {
      AskResult.granted => _afterGrant(nextAlertStep(_perms)),
      AskResult.blocked => FlowStep.locationBlocked,
      AskResult.denied => FlowStep.alertsOff,
    });
  });

  Future<void> _askAlways() => _run(() async {
    final granted = await NearbyPermissionGate.askLocationAlways();
    await _refresh();
    if (!mounted) return;
    _go(granted && _perms.alertsOn ? FlowStep.done : FlowStep.alertsOff);
  });

  Future<void> _openSettings() async {
    _inSettings = true;
    await openAppSettings();
  }

  Future<void> _toggleExtra(Future<bool> Function() ask, bool on) async {
    // Android can't take a grant back from inside the app: off means Settings.
    if (on) {
      await _run(() async => ask());
    } else {
      await openAppSettings();
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cards = ref.watch(cardsProvider).value ?? const <CardSummary>[];
    final tiles =
        ref.watch(categoryTilesProvider).value ?? const <CategoryTileData>[];
    final picks = _Picks.from(tiles);
    final tracker = SetupTracker(
      states: trackerFor(_step, _perms, cards.isNotEmpty),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finish();
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0.06, 0),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey(_step),
          child: _screen(tracker, cards, picks),
        ),
      ),
    );
  }

  Widget _screen(Widget tracker, List<CardSummary> cards, _Picks picks) {
    final drug = picks.drug;
    switch (_step) {
      case FlowStep.cards:
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: const _WalletHero(cards: []),
          content: const [
            ObHeading(
              title: 'Add your cards',
              body:
                  'SwipeWise only compares cards you own. Pick them by name — '
                  'Chase, Amex, Citi, Capital One and more. No bank login.',
            ),
            ObSection(
              label: 'ONCE YOUR CARDS ARE IN',
              rows: [
                ObRow(
                  icon: LucideIcons.pill,
                  iconColor: Ob.muted,
                  tileColor: Ob.secondary,
                  title: 'Walgreens',
                  subtitle: 'Drugstore',
                  dimTitle: true,
                  trailing: _Placeholder(),
                ),
                ObRow(
                  icon: LucideIcons.utensils,
                  iconColor: Ob.muted,
                  tileColor: Ob.secondary,
                  title: 'Dining',
                  subtitle: 'Category',
                  dimTitle: true,
                  trailing: _Placeholder(),
                ),
              ],
            ),
          ],
          primary: 'Add a card',
          primaryIcon: LucideIcons.plus,
          onPrimary: _addCards,
          secondary: 'Not now',
          onSecondary: () => _go(FlowStep.noCards),
        );

      case FlowStep.cardsAdded:
        final n = cards.length;
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: _WalletHero(cards: cards),
          content: [
            ObHeading(
              title: '$n ${n == 1 ? 'card' : 'cards'} added',
              body: 'SwipeWise is already ranking them:',
            ),
            if (picks.wins.isNotEmpty)
              ObSection(
                label: n == 1 ? 'WHERE YOUR CARD WINS' : 'WHERE EACH CARD WINS',
                rows: [
                  for (final (i, w) in picks.wins.indexed)
                    ObRow(
                      icon: w.category.icon,
                      iconColor: _tileTints[i % _tileTints.length].$2,
                      tileColor: _tileTints[i % _tileTints.length].$1,
                      title: w.category.label,
                      subtitle: 'Category',
                      trailing: BestCardTrailing(card: w.card, rate: w.rate),
                    ),
                ],
              ),
            const ObSection(
              label: 'NEXT',
              rows: [
                ObRow(
                  icon: LucideIcons.bell,
                  iconColor: Ob.gold,
                  tileColor: Ob.inkSun,
                  title: 'Store alerts',
                  subtitle: 'Three quick permissions. Optional.',
                  trailing: Icon(
                    LucideIcons.chevronRight,
                    size: 18,
                    color: Ob.muted,
                  ),
                ),
              ],
            ),
          ],
          primary: 'Continue',
          primaryIcon: LucideIcons.arrowRight,
          onPrimary: _continueToAlerts,
          secondary: 'Add another card',
          onSecondary: _addCards,
        );

      case FlowStep.notifications:
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: _BellHero(card: drug?.card, rate: drug?.rate),
          content: const [
            ObHeading(
              title: 'Turn on notifications',
              body:
                  'So SwipeWise can tell you which card to use when you walk '
                  'into a store.',
            ),
            ObSection(
              label: 'WHAT NOTIFICATIONS ARE FOR',
              rows: [
                ObRow(
                  icon: LucideIcons.store,
                  iconColor: Ob.gold,
                  tileColor: Ob.inkSun,
                  title: 'Store alerts',
                  subtitle: 'Your best card as you walk in',
                ),
                ObRow(
                  icon: LucideIcons.calendarClock,
                  iconColor: AppColors.foreground,
                  tileColor: Ob.secondary,
                  title: 'Payment reminders',
                  subtitle: 'Only if you set a due date',
                ),
              ],
            ),
            ObHint('Android asks next — tap Allow.'),
          ],
          primary: 'Allow notifications',
          primaryIcon: LucideIcons.bell,
          onPrimary: _askNotifications,
          secondary: 'Not now',
          onSecondary: () => _go(FlowStep.alertsOff),
        );

      case FlowStep.notificationsBlocked:
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: _BellHero(card: drug?.card, rate: drug?.rate, blocked: true),
          content: [
            const ObHeading(
              title: 'Turn on notifications in Settings',
              body:
                  "You chose “Don't allow” before, so Android won't ask "
                  'again.',
            ),
            const _SettingsPath(
              color: Ob.gold,
              ink: Ob.inkSun,
              crumbs: ['Notifications'],
              last: 'Allow',
            ),
          ],
          primary: 'Open settings',
          primaryIcon: LucideIcons.externalLink,
          onPrimary: _openSettings,
          secondary: 'Not now',
          onSecondary: () => _go(FlowStep.alertsOff),
        );

      case FlowStep.location:
        final dining = picks.dining;
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: _MapHero(card: drug?.card, rate: drug?.rate),
          content: [
            const ObHeading(
              title: 'Allow location',
              body:
                  "So SwipeWise knows which store you're in and picks the "
                  'right card.',
            ),
            ObSection(
              label: "NEAR YOU, ONCE IT'S ON",
              rows: [
                ObRow(
                  icon: LucideIcons.pill,
                  iconColor: Ob.gold,
                  tileColor: Ob.inkSun,
                  title: 'Walgreens',
                  subtitle: 'Drugstore · ${formatDistanceMi(0.1)}',
                  trailing: drug == null
                      ? null
                      : BestCardTrailing(card: drug.card, rate: drug.rate),
                ),
                ObRow(
                  icon: LucideIcons.utensils,
                  iconColor: Ob.pink,
                  tileColor: Ob.inkViolet,
                  title: "Joe's Diner",
                  subtitle: 'Dining · ${formatDistanceMi(0.3)}',
                  trailing: dining == null
                      ? null
                      : BestCardTrailing(card: dining.card, rate: dining.rate),
                ),
              ],
            ),
            const ObHint('Android asks next — choose “While using the app”.'),
          ],
          primary: 'Allow location',
          primaryIcon: LucideIcons.mapPin,
          onPrimary: _askLocation,
          secondary: 'Not now',
          onSecondary: () => _go(FlowStep.alertsOff),
        );

      case FlowStep.locationBlocked:
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: const _BlockedMapHero(),
          content: const [
            ObHeading(
              title: 'Turn on location in Settings',
              body:
                  "You chose “Don't allow” before, so Android won't ask "
                  'again.',
            ),
            DisclosureBox(
              color: Ob.teal,
              title: NearbyPermissionGate.disclosureTitle,
              paragraphs: [
                NearbyPermissionGate.disclosureCollect,
                NearbyPermissionGate.disclosureUse,
              ],
            ),
            _SettingsPath(
              color: Ob.teal,
              ink: Ob.inkTeal,
              crumbs: ['Permissions', 'Location'],
              last: 'Allow all the time',
            ),
          ],
          primary: 'Open settings',
          primaryIcon: LucideIcons.externalLink,
          onPrimary: _openSettings,
          secondary: 'Not now',
          onSecondary: () => _go(FlowStep.alertsOff),
        );

      case FlowStep.always:
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: _NightHero(card: drug?.card, rate: drug?.rate),
          content: const [
            ObHeading(
              title: 'Allow location all the time',
              body:
                  'Store alerts need this while SwipeWise is closed. On the '
                  'next screen, choose “Allow all the time”.',
            ),
            DisclosureBox(
              color: Ob.violet,
              title: NearbyPermissionGate.disclosureTitle,
              paragraphs: [
                NearbyPermissionGate.disclosureCollect,
                NearbyPermissionGate.disclosureUse,
              ],
            ),
          ],
          primary: 'Continue to settings',
          onPrimary: _askAlways,
          secondary: 'Not now',
          onSecondary: () => _go(FlowStep.alertsOff),
        );

      case FlowStep.done:
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: _DoneHero(card: drug?.card, rate: drug?.rate),
          content: [
            const ObHeading(
              title: "You're set up",
              body: 'Store alerts are on — all four steps above are done.',
            ),
            ObSection(
              label: 'OPTIONAL · FASTER ALERTS',
              rows: [
                ObRow(
                  icon: LucideIcons.footprints,
                  iconColor: AppColors.foreground,
                  tileColor: Ob.secondary,
                  title: 'Physical activity',
                  subtitle: 'Skips stores you drive past',
                  trailing: ObSwitch(
                    value: _perms.activity,
                    onChanged: (on) =>
                        _toggleExtra(NearbyPermissionGate.askActivity, on),
                  ),
                ),
                ObRow(
                  icon: LucideIcons.alarmClock,
                  iconColor: AppColors.foreground,
                  tileColor: Ob.secondary,
                  title: 'Exact alarms',
                  subtitle: 'Fires right as you walk in',
                  trailing: ObSwitch(
                    value: _perms.alarms,
                    onChanged: (on) =>
                        _toggleExtra(NearbyPermissionGate.askExactAlarms, on),
                  ),
                ),
                ObRow(
                  icon: LucideIcons.batteryCharging,
                  iconColor: AppColors.foreground,
                  tileColor: Ob.secondary,
                  title: 'Unrestricted battery',
                  subtitle: 'Never paused · uses a little more',
                  trailing: ObSwitch(
                    value: _perms.battery,
                    onChanged: (on) =>
                        _toggleExtra(NearbyPermissionGate.askBattery, on),
                  ),
                ),
              ],
            ),
          ],
          primary: 'Go to SwipeWise',
          primaryIcon: LucideIcons.arrowRight,
          onPrimary: _finish,
        );

      case FlowStep.alertsOff:
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: _PausedHero(card: drug?.card, rate: drug?.rate),
          content: [
            ObHeading(
              title: 'Store alerts are off',
              body: switch (nextAlertStep(_perms)) {
                FlowStep.notifications || FlowStep.notificationsBlocked =>
                  'They need notifications to reach you — the red step '
                      'above. Everything else in SwipeWise works.',
                FlowStep.location || FlowStep.locationBlocked =>
                  "They need location to know which store you're in — the "
                      'red step above. Everything else in SwipeWise works.',
                _ =>
                  'They need location “all the time” to notice store visits '
                      '— the red step above. Everything else in SwipeWise '
                      'works.',
              },
            ),
            const ObSection(
              label: 'STILL WORKS',
              rows: [
                ObRow(
                  icon: LucideIcons.lightbulb,
                  iconColor: Ob.primary,
                  tileColor: Ob.amberBg,
                  title: 'Best card at any store',
                  subtitle: 'Open the Advisor tab when you pay',
                ),
              ],
            ),
          ],
          primary: 'Go to SwipeWise',
          onPrimary: _finish,
          secondary: 'Turn on store alerts',
          onSecondary: () => _go(nextAlertStep(_perms)),
        );

      case FlowStep.noCards:
        return ObScreen(
          tracker: tracker,
          busy: _busy,
          hero: const _NoCardsHero(),
          content: const [
            ObHeading(
              title: 'Add a card to get started',
              body:
                  'SwipeWise compares only your own cards. Store alerts are '
                  'offered after your first card — nothing has been asked '
                  'yet.',
            ),
          ],
          primary: 'Add a card',
          primaryIcon: LucideIcons.plus,
          onPrimary: _addCards,
          secondary: 'Look around first',
          onSecondary: _finish,
        );
    }
  }
}

/// Icon tile colours for the "where each card wins" rows, in turn.
const _tileTints = [
  (Ob.inkSun, Ob.gold),
  (Ob.inkNight, Ob.sky),
  (Ob.inkViolet, Ob.pink),
];

/// A card and its rate, ready to show: ("Freedom Flex", "3%").
typedef _Pick = ({String card, String rate});

typedef _Win = ({RewardCategory category, String card, String rate});

/// What the screens show of the user's own wallet, from the Categories tab's
/// data.
class _Picks {
  const _Picks(this.drug, this.dining, this.wins);
  final _Pick? drug;
  final _Pick? dining;

  /// One category per card where it's the best pick, best rate first, two
  /// rows at most.
  final List<_Win> wins;

  static _Picks from(List<CategoryTileData> tiles) {
    _Pick? pick(RewardCategory c) {
      final t = tiles.where((t) => t.category == c).firstOrNull;
      if (t == null || t.bestCardName == null || t.bestRate == null) {
        return null;
      }
      return (
        card: shortCardName(t.bestCardName!),
        rate: formatPickRate(t.bestRate!, t.currency),
      );
    }

    final priced = [
      for (final t in tiles)
        if (t.isBonus && t.bestCardName != null && t.bestRate != null) t,
    ]..sort((a, b) => b.bestRate!.compareTo(a.bestRate!));
    final seen = <String>{};
    final wins = <_Win>[];
    for (final t in priced) {
      if (!seen.add(t.bestCardName!)) continue;
      wins.add((
        category: t.category,
        card: shortCardName(t.bestCardName!),
        rate: formatPickRate(t.bestRate!, t.currency),
      ));
      if (wins.length == 2) break;
    }
    return _Picks(
      pick(RewardCategory.drugStores),
      pick(RewardCategory.dining),
      wins,
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('Your best card', style: AppText.bodyMd(color: Ob.muted)),
        const SizedBox(height: 2),
        Text('—', style: AppText.monoMd(color: Ob.muted)),
      ],
    );
  }
}

/// "Permissions › Location › Allow all the time".
class _SettingsPath extends StatelessWidget {
  const _SettingsPath({
    required this.color,
    required this.ink,
    required this.crumbs,
    required this.last,
  });
  final Color color, ink;
  final List<String> crumbs;
  final String last;

  @override
  Widget build(BuildContext context) {
    Widget crumb(String t, {bool end = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: end ? ink : Ob.secondary,
        borderRadius: BorderRadius.circular(999),
        border: end ? Border.all(color: color) : null,
      ),
      child: Text(
        t,
        style: AppText.labelSm(color: end ? color : AppColors.foreground),
      ),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final c in crumbs) ...[
          crumb(c),
          const Icon(LucideIcons.chevronRight, size: 14, color: Ob.muted),
        ],
        crumb(last, end: true),
      ],
    );
  }
}

// ── Heroes ──────────────────────────────────────────────────────────────

/// The user's wallet: empty slots, or their cards dropping in with a +N.
class _WalletHero extends StatefulWidget {
  const _WalletHero({required this.cards});
  final List<CardSummary> cards;

  @override
  State<_WalletHero> createState() => _WalletHeroState();
}

class _WalletHeroState extends State<_WalletHero>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cards = widget.cards;
    final empty = cards.isEmpty;
    final shown = cards.take(2).toList();
    Animation<double> slide(int i) => CurvedAnimation(
      parent: _c,
      curve: Interval(i * 0.17, 0.6 + i * 0.17, curve: Curves.easeOutBack),
    );
    return ObHero(
      height: empty ? 210 : 182,
      top: Ob.inkViolet,
      glows: const [
        Glow(Ob.violet, -40, -20, 220, 200, 0.4),
        Glow(Ob.pink, 200, 40, 200, 180, 0.25),
      ],
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (empty) ...[
            const Positioned(left: 80, top: 16, child: _EmptySlot()),
            const Positioned(left: 80, top: 50, child: _EmptySlot()),
          ] else ...[
            const Positioned.fill(
              child: Confetti(
                pieces: [
                  (339, 81, 8, 6, -137),
                  (24, 94, 8, 11, -152),
                  (314, 97, 8, 11, -21),
                  (319, 97, 6, 11, -67),
                  (69, 0, 8, 11, -15),
                  (331, 108, 6, 11, -55),
                  (316, 106, 8, 6, -90),
                  (26, 62, 6, 6, -32),
                  (45, 26, 8, 11, -61),
                  (31, 98, 6, 6, -14),
                  (38, 56, 6, 6, -154),
                  (314, 104, 6, 11, -167),
                  (26, 78, 6, 6, -52),
                  (329, 78, 8, 6, -174),
                  (309, 81, 6, 6, -137),
                  (27, 76, 6, 11, -61),
                ],
              ),
            ),
            for (final (i, c) in shown.reversed.indexed)
              Positioned(
                left: 68,
                top: shown.length == 2 && i == 0 ? 8 : 42,
                child: AnimatedBuilder(
                  animation: slide(i),
                  builder: (_, child) => Transform.translate(
                    offset: Offset(0, -40 * (1 - slide(i).value)),
                    child: Opacity(
                      opacity: slide(i).value.clamp(0, 1),
                      child: child,
                    ),
                  ),
                  child: _CardArt(card: c, front: shown.length == 1 || i == 1),
                ),
              ),
          ],
          Positioned(
            left: 30,
            top: empty ? 118 : 104,
            child: _Pocket(
              height: empty ? 80 : 76,
              label:
                  'YOUR WALLET · ${cards.length} '
                  '${cards.length == 1 ? 'CARD' : 'CARDS'}',
            ),
          ),
          if (!empty)
            Positioned(
              left: 292,
              top: 12,
              child: ScaleTransition(
                scale: CurvedAnimation(
                  parent: _c,
                  curve: const Interval(0.5, 1, curve: Curves.elasticOut),
                ),
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(
                    color: Ob.mint,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Ob.shadow,
                        offset: Offset(0, 6),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '+${cards.length}',
                    style: AppText.monoLg(color: Ob.onPrimary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptySlot extends StatelessWidget {
  const _EmptySlot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 190,
      height: 120,
      decoration: BoxDecoration(
        color: Ob.glass,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Ob.glassStrong, width: 1.5),
      ),
      alignment: Alignment.center,
      child: const Icon(LucideIcons.plus, size: 22, color: Ob.pink),
    );
  }
}

class _Pocket extends StatelessWidget {
  const _Pocket({required this.height, required this.label});
  final double height;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 290,
      height: height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Ob.violet, Ob.inkViolet],
        ),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(16),
          bottom: Radius.circular(24),
        ),
        border: Border.all(color: Ob.glassStrong),
        boxShadow: const [
          BoxShadow(color: Ob.shadow, offset: Offset(0, -8), blurRadius: 24),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 240,
            height: 2,
            decoration: BoxDecoration(
              color: Ob.glassStrong,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, style: AppText.labelSm(color: AppColors.foreground)),
        ],
      ),
    );
  }
}

/// One of the user's cards, drawn as card art.
class _CardArt extends StatelessWidget {
  const _CardArt({required this.card, required this.front});
  final CardSummary card;
  final bool front;

  @override
  Widget build(BuildContext context) {
    final (a, b) = front
        ? (Ob.cardFlexA, Ob.cardFlexB)
        : (Ob.sapphireA, Ob.sapphireB);
    final four = card.lastFour;
    return Container(
      width: 214,
      height: 135,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: front ? [a, b] : [b, a],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Ob.glassStrong),
        boxShadow: const [
          BoxShadow(color: Ob.shadow, offset: Offset(0, 10), blurRadius: 24),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  shortCardName(card.displayName),
                  style: AppText.labelSm(color: AppColors.foreground),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Opacity(
                opacity: 0.9,
                child: Container(
                  width: 24,
                  height: 17,
                  decoration: BoxDecoration(
                    color: Ob.gold,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                four == null || four.isEmpty ? '••••' : '•••• $four',
                style: AppText.monoXs(color: AppColors.foreground),
              ),
              Text(
                card.network ?? '',
                style: AppText.labelSm(color: AppColors.foreground),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The alert this permission delivers, under a ringing bell.
class _BellHero extends StatefulWidget {
  const _BellHero({this.card, this.rate, this.blocked = false});
  final String? card;
  final String? rate;
  final bool blocked;

  @override
  State<_BellHero> createState() => _BellHeroState();
}

class _BellHeroState extends State<_BellHero>
    with SingleTickerProviderStateMixin {
  // ±12°, three cycles (design note).
  late final _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (!widget.blocked) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) _ring.forward();
      });
    }
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ObHero(
      height: 200,
      top: Ob.inkSun,
      glows: const [Glow(Ob.gold, 40, -40, 280, 200, 0.3)],
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Positioned(left: 116, top: -7, child: _Ring(118, Ob.gold, .28)),
          const Positioned(left: 131, top: 8, child: _Ring(88, Ob.gold, .48)),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedBuilder(
                animation: _ring,
                builder: (_, child) => Transform.rotate(
                  angle:
                      math.sin(_ring.value * math.pi * 6) *
                      (1 - _ring.value) *
                      12 *
                      math.pi /
                      180,
                  child: child,
                ),
                child: Medal(
                  icon: widget.blocked
                      ? LucideIcons.bellOff
                      : LucideIcons.bellRing,
                  from: Ob.gold,
                  to: Ob.flame,
                ),
              ),
              const SizedBox(height: 14),
              AlertMock(cardName: widget.card, rate: widget.rate),
            ],
          ),
        ],
      ),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring(this.size, this.color, this.opacity);
  final double size;
  final Color color;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.5),
        ),
      ),
    );
  }
}

const _streets = [
  (0.0, 63.0, 350.0, 12.0),
  (0.0, 151.0, 350.0, 10.0),
  (95.0, 0.0, 12.0, 210.0),
  (245.0, 0.0, 14.0, 210.0),
];

const _blocks = [
  (14.0, 85.0, 70.0, 67.0),
  (118.0, 85.0, 116.0, 67.0),
  (272.0, 85.0, 64.0, 67.0),
  (14.0, 8.0, 70.0, 47.0),
  (272.0, 8.0, 64.0, 47.0),
];

Widget _map({
  required List<(double, double, double, double)> streets,
  required List<(double, double, double, double)> blocks,
  double opacity = 1,
}) {
  return Opacity(
    opacity: opacity,
    child: Stack(
      children: [
        for (final (l, t, w, h) in streets)
          Positioned(
            left: l,
            top: t,
            width: w,
            height: h,
            child: const ColoredBox(color: Ob.glassStrong),
          ),
        for (final (l, t, w, h) in blocks)
          Positioned(
            left: l,
            top: t,
            width: w,
            height: h,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Ob.glass,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
      ],
    ),
  );
}

/// The user's dot matched to Walgreens, tagged with their card.
class _MapHero extends StatefulWidget {
  const _MapHero({this.card, this.rate});
  final String? card;
  final String? rate;

  @override
  State<_MapHero> createState() => _MapHeroState();
}

class _MapHeroState extends State<_MapHero>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ObHero(
      height: 210,
      top: Ob.inkTeal,
      glows: const [Glow(Ob.teal, 40, 20, 280, 200, 0.25)],
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _map(streets: _streets, blocks: _blocks),
          ),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, _) {
                final t = _pulse.value;
                return Stack(
                  children: [
                    for (final (size, base) in const [
                      (112.0, 0.213),
                      (82.0, 0.28),
                      (52.0, 0.48),
                    ])
                      Positioned(
                        left: 176 - size / 2,
                        top: 119 - size / 2,
                        child: Transform.scale(
                          scale: 0.9 + 0.1 * t,
                          child: _Ring(size, Ob.teal, base * (1.2 - 0.4 * t)),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          Positioned(
            left: 166,
            top: 109,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: Ob.teal,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.foreground, width: 3),
              ),
            ),
          ),
          Positioned(
            left: 96,
            top: 61,
            child: _Tag(
              outline: Ob.teal,
              icon: LucideIcons.store,
              iconColor: Ob.teal,
              label: 'Walgreens',
              rate: widget.rate,
            ),
          ),
          if (widget.card != null)
            Positioned(
              left: 200,
              top: 150,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Ob.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Ob.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 20,
                      height: 13,
                      decoration: BoxDecoration(
                        color: Ob.cardFlexA,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 110),
                      child: Text(
                        widget.card!,
                        style: AppText.labelSm(color: AppColors.foreground),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A floating pill on a hero: "Walgreens 3%", "Location blocked".
class _Tag extends StatelessWidget {
  const _Tag({
    required this.outline,
    required this.icon,
    required this.iconColor,
    required this.label,
    this.rate,
  });
  final Color outline, iconColor;
  final IconData icon;
  final String label;
  final String? rate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Ob.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: outline, width: 1.5),
        boxShadow: const [
          BoxShadow(color: Ob.shadow, offset: Offset(0, 6), blurRadius: 16),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 8),
          Text(label, style: AppText.titleMd(color: AppColors.foreground)),
          if (rate != null) ...[
            const SizedBox(width: 8),
            Text(rate!, style: AppText.monoMd(color: Ob.green)),
          ],
        ],
      ),
    );
  }
}

/// The map dimmed, with "Location blocked".
class _BlockedMapHero extends StatelessWidget {
  const _BlockedMapHero();

  @override
  Widget build(BuildContext context) {
    return ObHero(
      height: 120,
      top: Ob.inkTeal,
      child: Stack(
        children: [
          Positioned.fill(
            child: _map(
              opacity: 0.5,
              streets: const [
                (0, 36, 350, 12),
                (0, 86, 350, 10),
                (95, 0, 12, 120),
                (245, 0, 14, 120),
              ],
              blocks: const [
                (14, 58, 70, 38),
                (118, 58, 116, 38),
                (272, 58, 64, 38),
                (14, 8, 70, 20),
                (272, 8, 64, 20),
              ],
            ),
          ),
          const Positioned(
            left: 96,
            top: 19,
            child: _Tag(
              outline: Ob.red,
              icon: LucideIcons.mapPinOff,
              iconColor: Ob.red,
              label: 'Location blocked',
            ),
          ),
        ],
      ),
    );
  }
}

/// The alert arriving while the app is closed, under a night sky.
class _NightHero extends StatelessWidget {
  const _NightHero({this.card, this.rate});
  final String? card;
  final String? rate;

  @override
  Widget build(BuildContext context) {
    final body = card == null
        ? 'Open SwipeWise to see the best card here'
        : 'Use $card for ${rate ?? ''}'.trim();
    return ObHero(
      height: 108,
      top: Ob.inkNight,
      glows: const [Glow(Ob.violet, 60, -40, 240, 160, 0.35)],
      child: Stack(
        children: [
          for (final (l, t, s) in const [
            (20.0, 18.0, 5.0),
            (330.0, 14.0, 3.0),
            (300.0, 86.0, 5.0),
            (44.0, 84.0, 3.0),
            (180.0, 8.0, 5.0),
          ])
            Positioned(
              left: l,
              top: t,
              child: Opacity(
                opacity: 0.6,
                child: Container(
                  width: s,
                  height: s,
                  decoration: const BoxDecoration(
                    color: AppColors.foreground,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 80,
                  decoration: BoxDecoration(
                    color: Ob.inkNight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Ob.glassStrong, width: 1.5),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(LucideIcons.lock, size: 14, color: Ob.muted),
                      const SizedBox(height: 4),
                      Text('CLOSED', style: AppText.monoXs(color: Ob.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Container(
                  constraints: const BoxConstraints(maxWidth: 236),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Ob.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Ob.violet),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Ob.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(
                          LucideIcons.sparkles,
                          size: 15,
                          color: Ob.onPrimary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "You're at Walgreens",
                              style: AppText.bodyMd(
                                color: AppColors.foreground,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              body,
                              style: AppText.bodySm(color: Ob.muted),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A check medal, the live alert, and confetti.
class _DoneHero extends StatelessWidget {
  const _DoneHero({this.card, this.rate});
  final String? card;
  final String? rate;

  @override
  Widget build(BuildContext context) {
    return ObHero(
      height: 200,
      top: Ob.inkMint,
      glows: const [Glow(Ob.mint, 40, -40, 280, 200, 0.3)],
      child: Stack(
        children: [
          const Positioned.fill(
            child: Confetti(
              pieces: [
                (92, 76, 6, 11, -93),
                (313, 43, 8, 11, -5),
                (328, 64, 8, 11, -155),
                (79, 83, 6, 6, -63),
                (83, 49, 8, 11, -150),
                (36, 67, 6, 6, -115),
                (58, 84, 8, 6, -19),
                (90, 48, 6, 11, -100),
                (314, 64, 8, 6, -60),
                (274, 79, 8, 11, -139),
                (333, 40, 6, 11, -35),
                (97, 54, 6, 11, -170),
                (328, 67, 8, 6, -64),
                (80, 26, 8, 6, -135),
                (26, 37, 6, 11, -86),
                (41, 48, 8, 11, -154),
                (309, 85, 6, 6, -41),
                (38, 14, 8, 11, -166),
              ],
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 1.4, end: 1),
                  duration: const Duration(milliseconds: 450),
                  curve: Curves.easeOutBack,
                  builder: (_, s, child) =>
                      Transform.scale(scale: s, child: child),
                  child: const Medal(
                    icon: LucideIcons.check,
                    from: Ob.mint,
                    to: Ob.teal,
                  ),
                ),
                const SizedBox(height: 12),
                AlertMock(cardName: card, rate: rate),
              ],
            ),
          ),
          const Positioned(
            left: 266,
            top: 66,
            child: StatusPill(
              label: 'LIVE',
              color: Ob.mint,
              background: Ob.inkMint,
            ),
          ),
        ],
      ),
    );
  }
}

/// The alert greyed out, PAUSED.
class _PausedHero extends StatelessWidget {
  const _PausedHero({this.card, this.rate});
  final String? card;
  final String? rate;

  @override
  Widget build(BuildContext context) {
    return ObHero(
      height: 190,
      top: Ob.amberBg,
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Medal(
                  icon: LucideIcons.bellOff,
                  from: Ob.amber,
                  to: Ob.flame,
                  size: 52,
                  iconSize: 24,
                ),
                const SizedBox(height: 12),
                Opacity(
                  opacity: 0.45,
                  child: AlertMock(cardName: card, rate: rate),
                ),
              ],
            ),
          ),
          const Positioned(
            left: 250,
            top: 70,
            child: StatusPill(
              label: 'PAUSED',
              color: Ob.amber,
              background: Ob.amberBg,
            ),
          ),
        ],
      ),
    );
  }
}

/// An empty wallet and an alert with no card to name, locked.
class _NoCardsHero extends StatelessWidget {
  const _NoCardsHero();

  @override
  Widget build(BuildContext context) {
    return ObHero(
      height: 264,
      top: Ob.inkViolet,
      glows: const [Glow(Ob.violet, -40, -20, 220, 200, 0.35)],
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned(left: 80, top: 14, child: _EmptySlot()),
          const Positioned(
            left: 30,
            top: 56,
            child: _Pocket(height: 70, label: 'YOUR WALLET · 0 CARDS'),
          ),
          const Positioned(
            left: 20,
            top: 146,
            child: Opacity(
              opacity: 0.6,
              child: AlertMock(cardName: null, rate: null),
            ),
          ),
          Positioned(
            left: 12,
            top: 136,
            child: Container(
              width: 28,
              height: 28,
              decoration: const BoxDecoration(
                color: Ob.violet,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(
                LucideIcons.lock,
                size: 14,
                color: Ob.onPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
