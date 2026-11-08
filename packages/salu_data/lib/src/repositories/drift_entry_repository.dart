import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../codec.dart';
import '../database/app_database.dart';

/// SQLite-backed diary.
///
/// Entries and their items are written in one transaction, in position order.
/// Reads always hydrate the stored snapshots; nothing here consults the current
/// catalogue, which is what keeps history stable when a dataset updates.
final class DriftEntryRepository implements EntryRepository {
  /// Wraps [db].
  DriftEntryRepository(this._db);

  final AppDatabase _db;

  @override
  Future<LoggedEntry?> findByRequestId(String requestId) async {
    final row = await (_db.select(
      _db.logEntries,
    )..where((t) => t.requestId.equals(requestId)))
        .getSingleOrNull();
    return row == null ? null : _hydrate(row);
  }

  @override
  Future<void> append(LoggedEntry entry) async {
    await _db.transaction(() async {
      await _db.into(_db.logEntries).insert(
            LogEntriesCompanion.insert(
              id: entry.id,
              requestId: entry.requestId,
              diaryDate: entry.diaryDate.toIso(),
              instantUtcMs: entry.stamp.instantUtc.millisecondsSinceEpoch,
              offsetMinutes: entry.stamp.offsetMinutes,
              channel: entry.channel.name,
              recordedAtMs: entry.recordedAt.millisecondsSinceEpoch,
              revision: Value(entry.revision),
              note: Value(entry.note),
            ),
          );

      for (var i = 0; i < entry.items.length; i++) {
        final item = entry.items[i];
        await _db.into(_db.logEntryItems).insert(
              LogEntryItemsCompanion.insert(
                id: '${entry.id}-$i',
                entryId: entry.id,
                name: item.name,
                grams: item.grams,
                nutrientsJson: jsonEncode(item.nutrients.toJson()),
                position: i,
                foodId: Value(item.foodId),
              ),
            );
      }
    });
  }

  @override
  Future<List<LoggedEntry>> entriesFor(DiaryDate date) async {
    final rows = await (_db.select(_db.logEntries)
          ..where((t) => t.diaryDate.equals(date.toIso()))
          ..orderBy([(t) => OrderingTerm.asc(t.instantUtcMs)]))
        .get();

    final entries = <LoggedEntry>[];
    for (final row in rows) {
      entries.add(await _hydrate(row));
    }
    return entries;
  }

  /// Deletes [entryId] and, by cascade, its items.
  Future<void> deleteEntry(String entryId) async {
    await (_db.delete(_db.logEntries)..where((t) => t.id.equals(entryId))).go();
  }

  Future<LoggedEntry> _hydrate(LogEntry row) async {
    final itemRows = await (_db.select(_db.logEntryItems)
          ..where((t) => t.entryId.equals(row.id))
          ..orderBy([(t) => OrderingTerm.asc(t.position)]))
        .get();

    return LoggedEntry(
      id: row.id,
      requestId: row.requestId,
      diaryDate: DiaryDate.parse(row.diaryDate),
      stamp: EventStamp(
        instant: DateTime.fromMillisecondsSinceEpoch(
          row.instantUtcMs,
          isUtc: true,
        ),
        offsetMinutes: row.offsetMinutes,
      ),
      channel: enumByWire(
        EntryChannel.values,
        row.channel,
        EntryChannel.manual,
      ),
      items: [
        for (final item in itemRows)
          LoggedItem(
            name: item.name,
            grams: item.grams,
            nutrients:
                NutrientProfile.fromJson(decodeJsonMap(item.nutrientsJson)),
            foodId: item.foodId,
          ),
      ],
      recordedAt: DateTime.fromMillisecondsSinceEpoch(
        row.recordedAtMs,
        isUtc: true,
      ),
      revision: row.revision,
      note: row.note,
    );
  }
}
