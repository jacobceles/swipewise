import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:swipewise/api/card_repository.dart';
import 'package:swipewise/api/database_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late CardRepository repository;

  setUp(() async {
    DatabaseHelper.setTestDatabaseFactory(
      () => databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, _) => DatabaseHelper.bootstrapSchema(db),
        ),
      ),
    );
    repository = CardRepository(DatabaseHelper());
    final db = await DatabaseHelper().database;
    await db.insert('users', {'id': 'u1', 'identifier': 'u1@test'});
  });

  tearDown(() async {
    final db = await DatabaseHelper().database;
    await db.close();
    DatabaseHelper.setTestDatabaseFactory(null);
  });

  test(
    'manual card is durable, catalog-linked, and rejects a duplicate',
    () async {
      final added = await repository.addManualCard(
        userId: 'u1',
        productId: 'chase.sapphire-preferred',
        issuer: 'Chase',
        name: 'Chase Sapphire Preferred',
        network: 'Visa',
        imageUrl: 'https://example.com/card.png',
        lastFour: '1234',
        creditLimit: 10000,
        dueDay: 15,
        institutionLogo: 'https://example.com/chase-logo.png',
      );
      expect(added.status, ManualCardAddStatus.added);

      final db = await DatabaseHelper().database;
      final card = await db.query(
        'cards',
        where: 'id = ?',
        whereArgs: [added.cardId],
      );
      expect(card.single['source'], 'manual');
      expect(card.single['last_four'], '1234');
      expect(
        card.single['institution_id'],
        CardRepository.manualInstitutionId('Chase'),
        reason:
            'per-issuer synthetic institution id — Cards screen groups '
            'manual cards as "Chase (Manual)" instead of one flat bucket',
      );
      expect(
        card.single['institution_logo'],
        'https://example.com/chase-logo.png',
      );
      final override = await db.query(
        'card_overrides',
        where: 'card_id = ?',
        whereArgs: [added.cardId],
      );
      expect(override.single['manual_credit_limit'], 10000.0);
      expect(override.single['due_day'], 15);
      final link = await db.query(
        'card_links',
        where: 'card_id = ?',
        whereArgs: [added.cardId],
      );
      expect(link.single['card_product_id'], 'chase.sapphire-preferred');
      expect(link.single['source'], 'manual');

      final duplicate = await repository.addManualCard(
        userId: 'u1',
        productId: 'chase.sapphire-preferred',
        issuer: 'Chase',
        name: 'Chase Sapphire Preferred',
        network: 'Visa',
        imageUrl: null,
      );
      expect(duplicate.status, ManualCardAddStatus.alreadyInWallet);

      await repository.updateManualCreditLimit(
        'u1',
        added.cardId!,
        limit: 12000,
        name: 'Chase Sapphire Preferred',
      );
      final preserved = await db.query(
        'card_overrides',
        where: 'card_id = ?',
        whereArgs: [added.cardId],
      );
      expect(preserved.single['due_day'], 15);
    },
  );

  test(
    'manualInstitutionId is stable per issuer regardless of casing/spacing',
    () {
      expect(
        CardRepository.manualInstitutionId('Chase'),
        CardRepository.manualInstitutionId(' chase '),
      );
      expect(
        CardRepository.manualInstitutionId('Chase'),
        isNot(CardRepository.manualInstitutionId('Amex')),
      );
    },
  );
}
