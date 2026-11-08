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
  AppliedCommands,
  CatalogDatasets
])
class AppDatabase extends _$AppDatabase {
  /// Opens a database over [executor].
  AppDatabase(super.executor);

  /// A throwaway in-memory database, for tests.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          if (from < 1 || from >= to || to != 3) {
            throw UnsupportedError('No migration from $from to $to');
          }
          await transaction(() async {
            if (from == 1) {
              await m.addColumn(catalogFoods, catalogFoods.basisUnit);
              await m.addColumn(catalogFoods, catalogFoods.basisValue);
              // ignore: experimental_member_use
              await m.alterTable(TableMigration(logEntryItems, newColumns: [
                logEntryItems.quantityJson,
                logEntryItems.sourceJson
              ]));
              await m.createTable(userDocuments);
              await m.createTable(appliedCommands);
            }
            await m.addColumn(catalogFoods, catalogFoods.detailsJson);
            await m.addColumn(catalogFoods, catalogFoods.searchAliases);
            await m.createTable(catalogDatasets);
          });
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await initializeSearch();
        },
      );
  bool ftsAvailable = false;
  Future<void> initializeSearch() async {
    final option = await customSelect(
            "SELECT sqlite_compileoption_used('ENABLE_FTS5') AS enabled")
        .getSingle();
    ftsAvailable = option.read<int>('enabled') == 1;
    if (!ftsAvailable) return;
    final existed = (await customSelect(
                "SELECT name FROM sqlite_master WHERE name='catalog_search'")
            .get())
        .isNotEmpty;
    await customStatement(
        "CREATE VIRTUAL TABLE IF NOT EXISTS catalog_search USING fts5(food_id UNINDEXED,name,aliases,tokenize='unicode61 remove_diacritics 2')");
    await customStatement(
        "CREATE TRIGGER IF NOT EXISTS catalog_search_insert AFTER INSERT ON catalog_foods BEGIN INSERT INTO catalog_search(food_id,name,aliases) VALUES(new.id,new.name,new.search_aliases); END");
    await customStatement(
        "CREATE TRIGGER IF NOT EXISTS catalog_search_delete AFTER DELETE ON catalog_foods BEGIN DELETE FROM catalog_search WHERE food_id=old.id; END");
    await customStatement(
        "CREATE TRIGGER IF NOT EXISTS catalog_search_update AFTER UPDATE ON catalog_foods BEGIN DELETE FROM catalog_search WHERE food_id=old.id; INSERT INTO catalog_search(food_id,name,aliases) VALUES(new.id,new.name,new.search_aliases); END");
    if (!existed) await rebuildSearch();
  }

  Future<void> rebuildSearch() async {
    if (!ftsAvailable) return;
    await customStatement('DELETE FROM catalog_search');
    await customStatement(
        'INSERT INTO catalog_search(food_id,name,aliases) SELECT id,name,search_aliases FROM catalog_foods');
  }
}
