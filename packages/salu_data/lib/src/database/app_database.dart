import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// The local database.
///
/// Schema v1 covers the replaceable catalogue and the diary. Targets, plans,
/// weight and water arrive in later versions, each with a migration step - see
/// `docs/architecture.md` for the rule that no version ships without one.
@DriftDatabase(tables: [
  CatalogFoods,
  LogEntries,
  LogEntryItems,
  UserDocuments,
  AppliedCommands
])
class AppDatabase extends _$AppDatabase {
  /// Opens a database over [executor].
  AppDatabase(super.executor);

  /// A throwaway in-memory database, for tests.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from != 1 || to != 2) {
            throw UnsupportedError('No migration from $from to $to');
          }
          await transaction(() async {
            await m.addColumn(catalogFoods, catalogFoods.basisUnit);
            await m.addColumn(catalogFoods, catalogFoods.basisValue);
            await m.alterTable(TableMigration(logEntryItems, newColumns: [
              logEntryItems.quantityJson,
              logEntryItems.sourceJson
            ]));
            await m.createTable(userDocuments);
            await m.createTable(appliedCommands);
          });
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
