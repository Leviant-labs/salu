import 'package:drift/drift.dart';

/// Replaceable catalogue data, separate from anything the user created.
///
/// Nutrient values are stored as the JSON form of `NutrientProfile` so the
/// unknown/trace/estimated states survive the database round trip. A column per
/// nutrient would flatten those states into NULLs with no way back.
class CatalogFoods extends Table {
  TextColumn get basisUnit => text().withDefault(const Constant('g'))();
  TextColumn get basisValue => text().withDefault(const Constant('100'))();

  /// Local identifier, stable across catalogue updates.
  TextColumn get id => text()();

  /// Display name.
  TextColumn get name => text()();

  /// Dataset name, e.g. `usda-fdc`.
  TextColumn get source => text()();

  /// Identifier inside the source dataset.
  TextColumn get sourceId => text()();

  /// Dataset revision the row came from.
  TextColumn get sourceVersion => text().nullable()();

  /// `NutrientProfile.toJson()` against a 100 g basis.
  TextColumn get per100gJson => text()();

  /// Declared mass of one piece, when the source declares it.
  RealColumn get portionGrams => real().nullable()();

  /// Declared density in g/ml, when the source declares it.
  RealColumn get densityGPerMl => real().nullable()();

  /// `DataQuality` wire name.
  TextColumn get quality => text()();

  /// Declared allergens as a JSON array; NULL means unknown status.
  TextColumn get allergensJson => text().nullable()();

  /// Dietary tags as a JSON array.
  TextColumn get dietaryTagsJson => text().withDefault(const Constant('[]'))();

  /// `Preparation` wire name.
  TextColumn get preparation => text()();

  /// When the row was imported or last replaced.
  DateTimeColumn get importedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The diary: one row per logged entry.
///
/// `requestId` is unique, so the database itself refuses a retried request that
/// races the application-level idempotency check.
@TableIndex(name: 'log_entries_request_id', columns: {#requestId}, unique: true)
@TableIndex(name: 'log_entries_diary_date', columns: {#diaryDate})
class LogEntries extends Table {
  /// Local identifier.
  TextColumn get id => text()();

  /// Idempotency key from the originating request.
  TextColumn get requestId => text()();

  /// Diary date as ISO `yyyy-MM-dd`; deliberately not a timestamp.
  TextColumn get diaryDate => text()();

  /// Eating instant, epoch milliseconds UTC.
  IntColumn get instantUtcMs => integer()();

  /// UTC offset in minutes where the meal was eaten.
  IntColumn get offsetMinutes => integer()();

  /// `EntryChannel` wire name.
  TextColumn get channel => text()();

  /// When the row was written, epoch milliseconds UTC.
  IntColumn get recordedAtMs => integer()();

  /// Revision number, incremented by explicit corrections.
  IntColumn get revision => integer().withDefault(const Constant(1))();

  /// Optional user note.
  TextColumn get note => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Frozen snapshots of each item in an entry.
///
/// Nutrients here are for the eaten amount. Catalogue edits must never rewrite
/// these rows; a correction is a new revision, not an update in place.
class LogEntryItems extends Table {
  TextColumn get quantityJson => text().nullable()();
  TextColumn get sourceJson => text().nullable()();

  /// Local identifier.
  TextColumn get id => text()();

  /// Owning entry.
  ///
  /// Declared as an explicit constraint: drift's `references()` helper is not
  /// resolving under the current analyzer, and this keeps the cascade visible and
  /// testable against the actual SQLite schema.
  TextColumn get entryId =>
      text().customConstraint('REFERENCES log_entries(id) ON DELETE CASCADE')();

  /// Catalogue food the item came from, when it came from one.
  TextColumn get foodId => text().nullable()();

  /// Name captured at log time.
  TextColumn get name => text()();

  /// Eaten mass in grams.
  RealColumn get grams => real().nullable()();

  /// `NutrientProfile.toJson()` for the eaten amount.
  TextColumn get nutrientsJson => text()();

  /// Ordering within the entry.
  IntColumn get position => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Versioned user-owned feature records. Catalogue refreshes cannot touch these.
class UserDocuments extends Table {
  TextColumn get collection => text()();
  TextColumn get id => text()();
  IntColumn get revision => integer()();
  TextColumn get payload => text()();
  @override
  Set<Column<Object>> get primaryKey => {collection, id};
}

class AppliedCommands extends Table {
  TextColumn get requestId => text()();
  TextColumn get resultJson => text()();
  @override
  Set<Column<Object>> get primaryKey => {requestId};
}
