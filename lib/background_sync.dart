import 'package:workmanager/workmanager.dart';

/// What the background tick should actually do, or null if this build has
/// nothing to sync.
///
/// Assigned once, from `main`, when the build is Pro-seeded — see
/// `runBankBackgroundSync`. Otherwise it stays null and WorkManager is never
/// initialised either, so nothing schedules a tick in the first place.
///
/// The indirection keeps this file — which the compiler must retain, see
/// [callbackDispatcher] — importing nothing but WorkManager, rather than
/// dragging the sync engine and the aggregator client in behind it. That is
/// now about keeping the dependency graph honest rather than about excluding
/// code: both tiers ship in one binary.
Future<bool> Function()? backgroundSyncTask;

/// WorkManager's Dart entry point.
///
/// `vm:entry-point` makes this a permanent root — the compiler has to assume
/// something outside Dart calls it, so everything reachable from here stays in
/// the binary regardless of any guard placed inside it. That is exactly why
/// the real work lives behind [backgroundSyncTask] rather than inline: this
/// file deliberately imports nothing but WorkManager.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final run = backgroundSyncTask;
    // Nothing registered: return true so WorkManager treats the tick as done
    // rather than backing off and retrying a task that will never do work.
    if (run == null) return true;
    return run();
  });
}
