import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// The local database.
///
/// Schema v1 covers the replaceable catalogue and the diary. Targets, plans,
/// weight and water arrive in later versions, each with a migration step - see
/// `docs/architecture.md` for the rule that no version ships without one.
@DriftDatabase(tables: [CatalogFoods, LogEntries, LogEntryItems])
class AppDatabase extends _$AppDatabase {
  /// Opens a database over [executor].
  AppDatabase(super.executor);

  /// A throwaway in-memory database, for tests.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {
          // No upgrade path exists yet: v1 is the first schema. When v2 lands, add a
          // `stepByStep` block here and a test that migrates a v1 fixture forward.
          throw UnsupportedError('No migration from schema $from to $to');
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
