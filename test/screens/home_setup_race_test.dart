import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/catalog_loader.dart';
import 'package:swipewise/api/data_repository.dart';
import 'package:swipewise/api/database_helper.dart';
import 'package:swipewise/api/settings_repository.dart';
import 'package:swipewise/models/card.dart';
import 'package:swipewise/providers/activation_reminder_provider.dart';
import 'package:swipewise/providers/auth_provider.dart';
import 'package:swipewise/providers/backup_provider.dart';
import 'package:swipewise/providers/data_providers.dart';
import 'package:swipewise/providers/entitlement_provider.dart';
import 'package:swipewise/providers/nearby_providers.dart';
import 'package:swipewise/providers/payment_reminder_provider.dart';
import 'package:swipewise/providers/settings_provider.dart';
import 'package:swipewise/screens/home_screen.dart';
import 'package:swipewise/screens/onboarding/setup_flow.dart';
import 'package:swipewise/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  setUp(() async {
    DatabaseHelper.setTestDatabaseFactory(
      () => databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
          version: 1,
        ),
      ),
    );
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'u1', 'identifier': 'Test'});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (_) async => 1,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (call) async => call.method == 'checkPermission' ? 3 : 0,
    );
  });

  tearDown(() async {
    await (await DatabaseHelper().database).close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  testWidgets('a delayed first-card offer does not repeat completed setup', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    var wallet = <CardSummary>[];
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_Guest.new),
        proEntitlementProvider.overrideWith(_Free.new),
        backupSupportedProvider.overrideWithValue(false),
        walletBackupControllerProvider.overrideWithValue(_NoBackup()),
        paymentReminderControllerProvider.overrideWithValue(
          _NoPaymentReminders(),
        ),
        activationReminderControllerProvider.overrideWithValue(
          _NoActivationReminders(),
        ),
        catalogReadyProvider.overrideWith(
          (_) async => CatalogLoadResult.upToDate,
        ),
        categoryTilesProvider.overrideWith((_) async => []),
        brandTilesProvider.overrideWith((_) async => []),
        nearbyMerchantsProvider.overrideWith((_) async => []),
        alertChecksProvider.overrideWith((_) async => {}),
        locationReducedAccuracyProvider.overrideWith((_) async => false),
        cardsProvider.overrideWith((ref) async => wallet),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: darkTheme(),
          home: const HomeScreen(),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    for (
      var i = 0;
      i < 30 && !container.read(permissionGateCompleteProvider);
      i++
    ) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
    expect(container.read(permissionGateCompleteProvider), isTrue);

    // A first card arrives while another route is covering Home. The offer
    // must wait, then re-check whether that route already completed setup.
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Setup in progress')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    wallet = [
      CardSummary(
        cardId: 'x',
        source: 'manual',
        name: 'Test',
        txCount: 0,
        balance: 0,
      ),
    ];
    container.invalidate(cardsProvider);
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await SettingsRepository(DataRepository()).setPermissionsAsked('u1');
    });
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.byType(SetupFlow), findsNothing);
  });
}

class _Guest extends AuthNotifier {
  @override
  AuthState build() => AuthState(isLoggedIn: true, userId: 'u1');
}

class _Free extends ProEntitlementNotifier {
  @override
  bool build() => false;
}

class _NoBackup implements WalletBackupController {
  @override
  Future<RestoreOutcome> maybeAutoRestore() async =>
      RestoreOutcome.nothingToRestore;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoPaymentReminders implements PaymentReminderController {
  @override
  Future<void> reschedule() async {}
  @override
  Future<void> waitUntilIdle() async {}
}

class _NoActivationReminders implements ActivationReminderController {
  @override
  Future<void> reschedule() async {}
  @override
  Future<void> waitUntilIdle() async {}
}
