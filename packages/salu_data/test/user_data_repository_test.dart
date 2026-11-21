import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test(
      'snapshot excludes connection profiles and system state but includes ordinary documents',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    await docs.put(
      'endpoint-connections',
      0,
      {'version': 1, 'activeId': 'private-endpoint'},
    );
    await docs.put('search-index-state', 0, {'version': 1, 'indexed': 42});
    await docs.put(
      'catalogue-edition:usda-fdc',
      0,
      {'version': 1, 'edition': '2026-01'},
    );
    await docs.put('day:2026-11-19', 0, {'weightKg': 75.5});

    final saved = await UserDataRepository(db).snapshot();
    final docIds = saved.documents.map((r) => r['id']).toList();
    expect(docIds, contains('day:2026-11-19'));
    expect(docIds, isNot(contains('endpoint-connections')));
    expect(docIds, isNot(contains('search-index-state')));
    expect(docIds, isNot(contains('catalogue-edition:usda-fdc')));

    expect(saved.catalogueManifest['bundledCatalogue'],
        isA<Map<Object?, Object?>>());
    final editions =
        saved.catalogueManifest['editions'] as Map<Object?, Object?>;
    expect(
        editions['catalogue-edition:usda-fdc'], isA<Map<Object?, Object?>>());
  });

  test('snapshot rejects unknown document namespace visibly', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    await docs.put('mystery-feature-doc', 0, {'foo': 'bar'});

    expect(
      () => UserDataRepository(db).snapshot(),
      throwsA(isA<UnsupportedDocumentNamespaceException>()),
    );
  });

  test(
      'full 5-table round trip preserves entries, items, meals, documents, and mutations',
      () async {
    final sourceDb = AppDatabase.memory();
    addTearDown(sourceDb.close);

    // Seed all 5 user tables + catalogue/system rows
    await installBundledCatalogue(sourceDb);
    await sourceDb.into(sourceDb.catalogBarcodes).insert(
          CatalogBarcodesCompanion.insert(
            code: '1234567890123',
            foodId: 'fdc-1001',
            dataset: 'usda-fdc',
          ),
        );

    final nutrients = NutrientProfile({
      NutrientKey.energyKcal:
          NutrientValue.fromJson({'state': 'measured', 'amount': 250}),
      NutrientKey.proteinG: NutrientValue.fromJson({'state': 'trace'}),
      NutrientKey.fatG: NutrientValue.fromJson({'state': 'unknown'}),
    });
    final nutrientsJson = jsonEncode(nutrients.toJson());

    await sourceDb.into(sourceDb.logEntries).insert(
          LogEntriesCompanion.insert(
            id: 'entry-1',
            requestId: 'req-1',
            diaryDate: '2026-11-19',
            instantUtcMs: 1795089600000,
            offsetMinutes: 0,
            channel: EntryChannel.manual.name,
            recordedAtMs: 1795089600000,
            revision: const Value(1),
            note: const Value('breakfast'),
          ),
        );
    await sourceDb.into(sourceDb.logEntryItems).insert(
          LogEntryItemsCompanion.insert(
            id: 'item-1',
            entryId: 'entry-1',
            foodId: const Value('fdc-1001'),
            name: 'Oats',
            grams: 60.0,
            nutrientsJson: nutrientsJson,
            position: 0,
          ),
        );

    final meal = PhotoMeal(
      id: 'meal-1',
      date: DiaryDate.parse('2026-11-19'),
      slot: MealSlot.lunch,
      caption: 'Grilled salmon',
      createdAt: DateTime.utc(2026, 11, 19, 12, 30),
      revision: 2,
      photoPath: 'media:abc123',
      estimateStatus: MealEstimateStatus.complete,
      recordedOffsetMinutes: 60,
      items: [
        PhotoMealItem(
          id: 'mi-1',
          name: 'Salmon',
          labelPaths: const ['media:lbl1'],
        ),
      ],
    );
    await DriftPhotoMealRepository(sourceDb).saveNew(meal);

    await sourceDb.into(sourceDb.mealMutations).insert(
          MealMutationsCompanion.insert(
            requestId: 'mut-1',
            mealId: 'meal-1',
            operation: 'revise',
            expectedRevision: 1,
            resultingRevision: 2,
            beforeJson: Value(jsonEncode(encodePhotoMeal(meal))),
            afterJson: Value(jsonEncode(encodePhotoMeal(meal))),
            createdAtMs: 1795091400000,
            undoExpiresAtMs: const Value(1795095000000),
            payloadDigest: 'sha256:deadbeef',
          ),
        );

    final docs = LocalDocumentStore(sourceDb);
    await docs.put('planning-profile', 0, {'version': 1, 'targetKcal': 2100});
    await docs.put('onboarding-draft', 0, {'version': 1, 'step': 2});
    await docs.put('food-library', 0, {'version': 1, 'items': []});
    await docs.put('recipe-library', 0, {'version': 1, 'recipes': []});
    await docs.put('cooked-batches', 0, {'version': 1, 'batches': []});
    await docs.put('check-in-settings', 0, {'version': 1, 'enabled': true});
    await docs.put('day:2026-11-19', 0, {'weightKg': 75.5});
    await docs.put('week:2026-11-16', 0, {'version': 1, 'days': {}});
    await docs.put('estimate:meal-1', 0, {'status': 'ready'});
    await docs.put('endpoint-connections', 0, {'version': 1, 'activeId': 'p1'});
    await docs.put('search-index-state', 0, {'version': 1, 'ready': true});
    await docs.put('catalogue-edition:usda', 0, {'version': 1});

    final snapshot = await UserDataRepository(sourceDb).snapshot();
    final roundTripped = UserDataSnapshot.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>,
    );

    // Restore into a target DB that already has its own catalogue & system rows
    final targetDb = AppDatabase.memory();
    addTearDown(targetDb.close);
    await installBundledCatalogue(targetDb);
    await targetDb.into(targetDb.catalogBarcodes).insert(
          CatalogBarcodesCompanion.insert(
            code: '9999999999999',
            foodId: 'fdc-2002',
            dataset: 'usda-fdc',
          ),
        );
    final targetDocs = LocalDocumentStore(targetDb);
    await targetDocs
        .put('search-index-state', 0, {'version': 1, 'local': true});
    await targetDocs.put('catalogue-edition:local', 0, {'version': 1});
    await targetDocs
        .put('endpoint-connections', 0, {'version': 1, 'activeId': 'old'});

    await UserDataRepository(targetDb).replace(roundTripped);

    // Verify all 5 user tables restored
    expect(await targetDb.select(targetDb.logEntries).get(), hasLength(1));
    expect(await targetDb.select(targetDb.logEntryItems).get(), hasLength(1));
    expect(await targetDb.select(targetDb.photoMeals).get(), hasLength(1));
    expect(await targetDb.select(targetDb.mealMutations).get(), hasLength(1));

    // Verify all 9 user documents restored, provider cleared, system/catalogue preserved
    expect(await targetDocs.read('planning-profile'), isNotNull);
    expect(await targetDocs.read('onboarding-draft'), isNotNull);
    expect(await targetDocs.read('food-library'), isNotNull);
    expect(await targetDocs.read('recipe-library'), isNotNull);
    expect(await targetDocs.read('cooked-batches'), isNotNull);
    expect(await targetDocs.read('check-in-settings'), isNotNull);
    expect(await targetDocs.read('day:2026-11-19'), isNotNull);
    expect(await targetDocs.read('week:2026-11-16'), isNotNull);
    expect(await targetDocs.read('estimate:meal-1'), isNotNull);
    expect(await targetDocs.read('endpoint-connections'), isNull);
    expect(await targetDocs.read('search-index-state'), isNotNull);
    expect(await targetDocs.read('catalogue-edition:local'), isNotNull);
    expect(await targetDb.select(targetDb.catalogFoods).get(), isNotEmpty);
    expect(await targetDb.select(targetDb.catalogBarcodes).get(), hasLength(1));
  });

  test('replace rejects broken foreign keys and preserves existing DB',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalDocumentStore(db).put('day:2026-11-19', 0, {'weightKg': 70.0});

    final invalid = UserDataSnapshot(
      entries: const [],
      entryItems: [
        {
          'id': 'item-orphan',
          'entryId': 'missing-entry',
          'foodId': null,
          'name': 'Apple',
          'grams': 100.0,
          'nutrientsJson': '{}',
          'position': 0,
        },
      ],
      meals: const [],
      documents: const [],
      mutations: const [],
    );

    await expectLater(
      UserDataRepository(db).replace(invalid),
      throwsA(isA<FormatException>()),
    );
    // Original DB untouched
    final preserved = await LocalDocumentStore(db).read('day:2026-11-19');
    expect(preserved?.data['weightKg'], 70.0);
  });

  test(
      'replace rejects unsupported future document version and invalid planning-profile',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalDocumentStore(db).put('day:2026-11-19', 0, {'weightKg': 72.0});

    final futureDoc = UserDataSnapshot(
      entries: const [],
      entryItems: const [],
      meals: const [],
      documents: [
        {
          'id': 'planning-profile',
          'revision': 1,
          'payload': jsonEncode({'version': 99, 'targetKcal': 2000}),
        },
      ],
      mutations: const [],
    );
    await expectLater(
      UserDataRepository(db).replace(futureDoc),
      throwsA(isA<FormatException>()),
    );

    final badProfile = UserDataSnapshot(
      entries: const [],
      entryItems: const [],
      meals: const [],
      documents: [
        {
          'id': 'planning-profile',
          'revision': 1,
          'payload': jsonEncode({'version': 1, 'startingWeight': -70.0}),
        },
      ],
      mutations: const [],
    );
    expect(
      () => UserDataRepository.validate(badProfile),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      UserDataRepository(db).replace(badProfile),
      throwsA(isA<FormatException>()),
    );

    final badProfileEnum = UserDataSnapshot(
      entries: const [],
      entryItems: const [],
      meals: const [],
      documents: [
        {
          'id': 'planning-profile',
          'revision': 1,
          'payload': jsonEncode({'version': 1, 'weightUnit': 'stones'}),
        },
      ],
      mutations: const [],
    );
    expect(
      () => UserDataRepository.validate(badProfileEnum),
      throwsA(isA<FormatException>()),
    );

    expect(
      (await LocalDocumentStore(db).read('day:2026-11-19'))?.data['weightKg'],
      72.0,
    );
  });

  test(
      'erase clears user and provider data while preserving catalogue and system state',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await installBundledCatalogue(db);
    final docs = LocalDocumentStore(db);
    await docs.put('day:2026-11-19', 0, {'weightKg': 75.0});
    await docs.put('endpoint-connections', 0, {'version': 1, 'activeId': 'p1'});
    await docs.put('search-index-state', 0, {'version': 1, 'ready': true});
    await docs.put('catalogue-edition:usda', 0, {'version': 1});

    await UserDataRepository(db).erase();

    expect(await docs.read('day:2026-11-19'), isNull);
    expect(await docs.read('endpoint-connections'), isNull);
    expect(await docs.read('search-index-state'), isNotNull);
    expect(await docs.read('catalogue-edition:usda'), isNotNull);
    expect(await db.select(db.catalogFoods).get(), isNotEmpty);
  });
}
