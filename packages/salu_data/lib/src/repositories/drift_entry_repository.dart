import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../codec.dart';
import '../database/app_database.dart';
import '../workspace_store.dart';

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
      final workspace = LocalWorkspace(_db);
      await workspace.invalidateHistory();
      final day = await workspace.read('day', entry.diaryDate.toIso());
      await workspace.put(
          requestId: 'day-log:${entry.requestId}',
          collection: 'day',
          id: entry.diaryDate.toIso(),
          expectedRevision: day?.revision ?? 0,
          data: {'completeness': 'partial'});
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
                grams: Value(item.grams),
                quantityJson: Value(item.quantity == null
                    ? null
                    : jsonEncode(item.quantity!.toJson())),
                sourceJson: Value(item.sourceSnapshot == null
                    ? null
                    : jsonEncode(item.sourceSnapshot)),
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

  /// The only correction path; snapshots are scaled, never re-read from a catalogue.
  Future<int> revise(ReviseEntryCommand command) async =>
      _db.transaction(() async {
        final fingerprint = jsonEncode({
          'entryId': command.entryId,
          'expectedRevision': command.expectedRevision,
          'multiplier': command.multiplier?.toJson(),
          'diaryDate': command.diaryDate?.toIso(),
          'delete': command.delete
        });
        final prior = await (_db.select(_db.appliedCommands)
              ..where((t) => t.requestId.equals(command.requestId)))
            .getSingleOrNull();
        if (prior != null) {
          final result = decodeJsonMap(prior.resultJson);
          if (result['entryId'] != command.entryId ||
              result['fingerprint'] != fingerprint) {
            throw StateError('REQUEST_ID_REUSED');
          }
          return result['revision']! as int;
        }
        final row = await (_db.select(_db.logEntries)
              ..where((t) => t.id.equals(command.entryId)))
            .getSingleOrNull();
        if (row == null || row.revision != command.expectedRevision) {
          throw StateError('STALE_ENTRY');
        }
        final items = await (_db.select(_db.logEntryItems)
              ..where((t) => t.entryId.equals(command.entryId)))
            .get();
        final workspace = LocalWorkspace(_db);
        await workspace.put(
            requestId: 'history:${command.requestId}',
            collection: 'entry-revision',
            id: '${row.id}:${row.revision}',
            expectedRevision: 0,
            data: {
              'entry': row.toJson(),
              'items': items.map((i) => i.toJson()).toList(),
              'deleted': command.delete
            });
        final revisedBatches = <String, int>{};
        if (command.multiplier != null) {
          final batchIds = items
              .where((i) => i.sourceJson != null)
              .map((i) => decodeJsonMap(i.sourceJson!)['batchId'])
              .whereType<String>()
              .toSet();
          for (final batchId in batchIds) {
            final batch = await workspace.read('batch', batchId);
            if (batch == null) {
              throw StateError('BATCH_RECONCILIATION_REQUIRED');
            }
            var found = false;
            final allocations = <Map<String, Object?>>[];
            for (final raw in batch.data['allocations']! as List) {
              final allocation = Map<String, Object?>.from(raw as Map);
              if (allocation['id'] == row.requestId) {
                allocation['amount'] = (Exact.fromJson(
                            Map<String, Object?>.from(
                                allocation['amount']! as Map)) *
                        command.multiplier!)
                    .toJson();
                found = true;
              }
              allocations.add(allocation);
            }
            if (!found) throw StateError('BATCH_RECONCILIATION_REQUIRED');
            revisedBatches[batchId] = await workspace.put(
                requestId: 'stock-correction:${command.requestId}:$batchId',
                collection: 'batch',
                id: batchId,
                expectedRevision: batch.revision,
                data: {...batch.data, 'allocations': allocations});
          }
        }
        final newRevision = row.revision + 1;
        if (command.delete) {
          await (_db.delete(_db.logEntries)..where((t) => t.id.equals(row.id)))
              .go();
        } else {
          await (_db.update(_db.logEntries)..where((t) => t.id.equals(row.id)))
              .write(LogEntriesCompanion(
                  revision: Value(newRevision),
                  diaryDate: Value(command.diaryDate?.toIso() ?? row.diaryDate),
                  recordedAtMs:
                      Value(command.recordedAt.millisecondsSinceEpoch)));
          if (command.multiplier != null) {
            for (final item in items) {
              final factor = command.multiplier!;
              final quantity = item.quantityJson == null
                  ? null
                  : FoodAmount.fromJson(decodeJsonMap(item.quantityJson!));
              final source = item.sourceJson == null
                  ? null
                  : decodeJsonMap(item.sourceJson!);
              if (source != null) {
                for (final key in ['consumedBatchGrams', 'allocationScale']) {
                  if (source[key] != null) {
                    source[key] = (Exact.fromJson(Map<String, Object?>.from(
                                source[key]! as Map)) *
                            factor)
                        .toJson();
                  }
                }
                final batchId = source['batchId'];
                if (batchId is String && revisedBatches.containsKey(batchId)) {
                  source['batchRevision'] = revisedBatches[batchId];
                }
              }
              await (_db.update(_db.logEntryItems)
                    ..where((t) => t.id.equals(item.id)))
                  .write(LogEntryItemsCompanion(
                sourceJson: Value(source == null ? null : jsonEncode(source)),
                grams: Value(item.grams == null
                    ? null
                    : item.grams! * factor.toDouble()),
                nutrientsJson: Value(jsonEncode(
                    NutrientProfile.fromJson(decodeJsonMap(item.nutrientsJson))
                        .scaledExact(factor)
                        .toJson())),
                quantityJson: Value(quantity == null
                    ? null
                    : jsonEncode(FoodAmount.exact(
                            quantity.value * factor, quantity.unit,
                            measureId: quantity.measureId)
                        .toJson())),
              ));
            }
          }
        }
        for (final date in {
          row.diaryDate,
          command.diaryDate?.toIso() ?? row.diaryDate
        }) {
          final day = await workspace.read('day', date);
          await workspace.put(
              requestId: 'day-revise:${command.requestId}:$date',
              collection: 'day',
              id: date,
              expectedRevision: day?.revision ?? 0,
              data: {'completeness': 'partial'});
        }
        await workspace.invalidateHistory();
        await _db.into(_db.appliedCommands).insert(
            AppliedCommandsCompanion.insert(
                requestId: command.requestId,
                resultJson: jsonEncode({
                  'entryId': command.entryId,
                  'revision': newRevision,
                  'fingerprint': fingerprint
                })));
        return newRevision;
      });

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
            quantity: item.quantityJson == null
                ? null
                : FoodAmount.fromJson(decodeJsonMap(item.quantityJson!)),
            sourceSnapshot: item.sourceJson == null
                ? null
                : decodeJsonMap(item.sourceJson!),
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
