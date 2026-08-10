import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/card_repository.dart';
import 'package:swipewise/api/database_helper.dart';

/// Pins per-card payment-reminder overrides (wireframe M5ray / CuqEE).
///
/// Settings supplies the default; the card sheet can pin its own. NULL on either
/// column means "inherit" — so a card that has never been touched must not be
/// frozen to whatever the default happened to be when it was created.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late CardRepository repo;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await DatabaseHelper.bootstrapSchema(db);
    await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});
    await db.insert('cards', {
      'id': 'c1',
      'user_id': 'u1',
      'source': 'bank',
      'name': 'Card',
      'last_four': '1111',
    });
    DatabaseHelper.setTestDatabaseFactory(() async => db);
    repo = CardRepository(DatabaseHelper());
  });

  tearDown(() async {
    DatabaseHelper.setTestDatabaseFactory(null);
    await db.close();
  });

  Future<Map<String, Object?>> overrideRow() async => (await db.query(
    'card_overrides',
    where: 'card_id = ?',
    whereArgs: ['c1'],
  )).single;

  test('an untouched card inherits — both columns stay null', () async {
    await repo.setDueDay('u1', 'c1', 15);
    final row = await overrideRow();
    expect(row['due_day'], 15);
    expect(
      row['reminder_enabled'],
      isNull,
      reason: 'null = follow the global toggle',
    );
    expect(
      row['reminder_lead_days'],
      isNull,
      reason: 'null = use the Settings default',
    );
  });

  test('pinning a per-card lead time persists it', () async {
    await repo.setDueDay('u1', 'c1', 15);
    await repo.setReminderPrefs('u1', 'c1', enabled: true, leadDays: 7);
    final row = await overrideRow();
    expect(row['reminder_enabled'], 1);
    expect(row['reminder_lead_days'], 7);
    expect(
      row['due_day'],
      15,
      reason: 'setting reminders must not clobber the due day',
    );
  });

  test('opting a card out is recorded distinctly from inheriting', () async {
    await repo.setDueDay('u1', 'c1', 15);
    await repo.setReminderPrefs('u1', 'c1', enabled: false, leadDays: null);
    final row = await overrideRow();
    expect(
      row['reminder_enabled'],
      0,
      reason: '0 = off, null = inherit — not the same',
    );
  });

  test('clearing back to null restores inheritance', () async {
    await repo.setDueDay('u1', 'c1', 15);
    await repo.setReminderPrefs('u1', 'c1', enabled: true, leadDays: 5);
    await repo.setReminderPrefs('u1', 'c1', enabled: null, leadDays: null);
    final row = await overrideRow();
    expect(row['reminder_enabled'], isNull);
    expect(row['reminder_lead_days'], isNull);
  });

  test('an out-of-range lead time is refused rather than stored', () async {
    await repo.setDueDay('u1', 'c1', 15);
    await repo.setReminderPrefs('u1', 'c1', enabled: true, leadDays: 999);
    expect((await overrideRow())['reminder_lead_days'], isNull);
  });

  test('reminder prefs survive a due-day edit', () async {
    await repo.setDueDay('u1', 'c1', 15);
    await repo.setReminderPrefs('u1', 'c1', enabled: true, leadDays: 7);
    await repo.setDueDay('u1', 'c1', 20);
    final row = await overrideRow();
    expect(row['due_day'], 20);
    expect(
      row['reminder_lead_days'],
      7,
      reason: 'the merge must not drop them',
    );
  });
}
