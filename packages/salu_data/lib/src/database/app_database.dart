import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// The local database.
///
@DriftDatabase(tables: [
  CatalogFoods,
  LogEntries,
  LogEntryItems,
  PhotoMeals,
  LocalDocuments,
  CatalogBarcodes,
  MealMutations,
])
class AppDatabase extends _$AppDatabase {
  /// Opens a database over [executor].
  AppDatabase(super.executor);

  /// A throwaway in-memory database, for tests.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 1 || from > 3 || to != 4) {
            throw UnsupportedError('No migration from schema $from to $to');
          }
          await transaction(() async {
            if (from < 3) {
              if (from == 1) {
                await m.createTable(photoMeals);
                await customStatement(
                  'CREATE INDEX photo_meals_diary_date ON photo_meals (diary_date)',
                );
              } else {
                await m.addColumn(photoMeals, photoMeals.estimateStatus);
                await m.addColumn(photoMeals, photoMeals.recordedOffsetMinutes);
              }
              await m.createTable(localDocuments);
              await m.createTable(catalogBarcodes);
              await customStatement(
                  'CREATE INDEX catalog_barcodes_code ON catalog_barcodes (code)');
            }
            if (from < 4) {
              await m.createTable(mealMutations);
              await customStatement(
                'CREATE INDEX meal_mutations_meal_id ON meal_mutations (meal_id)',
              );
            }
          });
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
