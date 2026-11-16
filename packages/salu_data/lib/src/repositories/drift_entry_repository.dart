import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../codec.dart';
import '../database/app_database.dart';
import '../snapshot_codec.dart';
import '../workspace_store.dart';
import '../plan_meal_state_service.dart';

/// SQLite-backed diary.
///
/// Entries and their items are written in one transaction, in position order.
/// Reads always hydrate the stored snapshots; nothing here consults the current
/// catalogue, which is what keeps history stable when a dataset updates.
final class DriftEntryRepository
    implements EntryRepository, RecipeLogReceiptRepository {
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

  String _recipeReceiptId(String requestId) =>
      'recipe-log-receipt:${base64Url.encode(utf8.encode(requestId))}';

  @override
  Future<LoggedEntry?> replayRecipeLog(String requestId, String? fingerprint) async {
    final receipt = await (_db.select(_db.appliedCommands)
          ..where((t) => t.requestId.equals(_recipeReceiptId(requestId))))
        .getSingleOrNull();
    final entry = await findByRequestId(requestId);
    if (receipt == null) {
      if (entry != null && fingerprint != null) throw StateError('REQUEST_ID_REUSED');
      return entry;
    }
    final result = decodeJsonMap(receipt.resultJson);
    if (fingerprint == null || result['recipeLogFingerprint'] != fingerprint) {
      throw StateError('REQUEST_ID_REUSED');
    }
    if (entry == null || result['entryId'] != entry.id) {
      throw StateError('RECIPE_LOG_ENTRY_MISSING');
    }
    return entry;
  }

  @override
  Future<LoggedEntry> appendRecipeLog(LoggedEntry entry, String fingerprint) =>
      _db.transaction(() async {
        final prior = await replayRecipeLog(entry.requestId, fingerprint);
        if (prior != null) return prior;
        await append(entry);
        await _db.into(_db.appliedCommands).insert(AppliedCommandsCompanion.insert(
          requestId: _recipeReceiptId(entry.requestId),
          resultJson: jsonEncode({
            'entryId': entry.id,
            'recipeLogFingerprint': fingerprint,
          }),
        ));
        return entry;
      });

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

  /// Deletes [entryId] and, by cascade, its items. Any plan-meal link to
  /// the entry is cleared in the same transaction; no stock is returned.
  Future<void> deleteEntry(String entryId) async {
    await _db.transaction(() async {
      await PlanMealStateService(_db).clearForEntry(entryId);
      await (_db.delete(_db.logEntries)..where((t) => t.id.equals(entryId))).go();
    });
  }

  /// The only correction path; snapshots are scaled, never re-read from a catalogue.
  ///
  /// With [ReviseEntryCommand.itemIndex] exactly one frozen item is scaled and
  /// the rest stay byte-for-byte unchanged. Entries backed by finite cooked-batch
  /// stock cannot be corrected item by item: one allocation covers the whole
  /// portion, so a per-item change would leave ingredient quantities and stock
  /// inconsistent. That combination is rejected instead of guessing a
  /// replacement allocation.
  Future<int> revise(ReviseEntryCommand command) async =>
      _db.transaction(() async {
        final fingerprint = <String, Object?>{
          'entryId': command.entryId,
          'expectedRevision': command.expectedRevision,
          'itemIndex': command.itemIndex,
          'multiplier': command.multiplier?.toJson(),
          'diaryDate': command.diaryDate?.toIso(),
          'delete': command.delete,
          'stamp': command.stamp == null
              ? null
              : {
                  'utc': command.stamp!.instantUtc.toIso8601String(),
                  'offset': command.stamp!.offsetMinutes
                }
        };
        final prior = await (_db.select(_db.appliedCommands)
              ..where((t) => t.requestId.equals(command.requestId)))
            .getSingleOrNull();
        if (prior != null) {
          final result = decodeJsonMap(prior.resultJson);
          if (result['entryId'] != command.entryId ||
              !_sameFingerprint(result['fingerprint'], fingerprint)) {
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
              ..where((t) => t.entryId.equals(command.entryId))
              ..orderBy([(t) => OrderingTerm.asc(t.position), (t) => OrderingTerm.asc(t.id)]))
            .get();
        if (command.itemIndex != null) {
          if (command.itemIndex! < 0 || command.itemIndex! >= items.length) {
            throw StateError('ITEM_INDEX_OUT_OF_RANGE');
          }
          if (items.any((item) => _batchIdOf(item) != null)) {
            throw StateError('BATCH_ITEM_CORRECTION_UNSUPPORTED');
          }
        }
        final workspace = LocalWorkspace(_db);
        final revisedBatches = <String, int>{};
        if (command.multiplier != null && command.itemIndex == null) {
          final batchIds = items.map(_batchIdOf).whereType<String>().toSet();
          final consumed = _consumedBatchAmountsByBatch(items);
          for (final batchId in batchIds) {
            final batch = await workspace.read('batch', batchId);
            if (batch == null) {
              throw StateError('BATCH_RECONCILIATION_REQUIRED');
            }
            final data = batch.data;
            final rawAllocations = data['allocations'];
            if (rawAllocations is! List) {
              throw StateError('BATCH_RECONCILIATION_REQUIRED');
            }
            var found = false;
            final allocations = <BatchAllocation>[];
            for (final raw in rawAllocations) {
              final allocation = Map<String, Object?>.from(raw as Map);
              final id = allocation['id']! as String;
              var amount = _exact(allocation['amount']);
              final intakeId = allocation['intakeRequestId'] as String? ?? id;
              if (intakeId == row.requestId) {
                if (found) throw StateError('BATCH_RECONCILIATION_REQUIRED');
                found = true;
                if (allocation['status'] != 'consumed') {
                  throw StateError('BATCH_RECONCILIATION_REQUIRED');
                }
                // The frozen portion and the stock allocation must agree before
                // either is scaled; otherwise the correction would compound an
                // existing inconsistency.
                if (consumed[batchId] != (data['unit'], amount)) {
                  throw StateError('BATCH_RECONCILIATION_REQUIRED');
                }
                amount = amount * command.multiplier!;
              }
              allocations.add(BatchAllocation(
                  id, amount, allocation['status']! as String,
                  intakeRequestId: allocation['intakeRequestId'] as String?));
            }
            if (!found) {
              throw StateError('BATCH_RECONCILIATION_REQUIRED');
            }
            // Reconstructing the batch applies its stock ceiling, so an
            // over-allocation is rejected before any document is written.
            final finished = data['finishedWeightG'];
            final batchModel = CookedBatch(
                id: batchId,
                recipe: recipeFromSnapshot(
                    Map<String, Object?>.from(data['recipe']! as Map)),
                revision: batch.revision,
                available: _exact(data['available']),
                unit: FoodUnit.values.byName(data['unit']! as String),
                finishedWeightG: finished == null ? null : _exact(finished),
                allocations: allocations);
            revisedBatches[batchId] = await workspace.put(
                requestId: 'stock-correction:${command.requestId}:$batchId',
                collection: 'batch',
                id: batchId,
                expectedRevision: batch.revision,
                data: {
                  ...data,
                  'allocations': [
                    for (final a in batchModel.allocations)
                      {
                        'id': a.id,
                        'amount': a.amount.toJson(),
                        'status': a.status,
                        if (a.intakeRequestId != null)
                          'intakeRequestId': a.intakeRequestId
                      }
                  ]
                });
          }
        }
        // Everything that can reject this correction has passed; record the
        // pre-correction snapshots before mutating the current revision.
        await workspace.put(
            requestId: 'history:${command.requestId}',
            collection: 'entry-revision',
            id: '${row.id}:${row.revision}',
            expectedRevision: 0,
            data: {
              'entry': row.toJson(),
              'items': items.map((i) => i.toJson()).toList(),
              'itemIndex': command.itemIndex,
              'deleted': command.delete
            });
        final newRevision = row.revision + 1;
        final state = PlanMealStateService(_db);
        if (command.delete) {
          await state.clearForEntry(row.id);
          await (_db.delete(_db.logEntries)..where((t) => t.id.equals(row.id)))
              .go();
        } else {
          await (_db.update(_db.logEntries)..where((t) => t.id.equals(row.id)))
              .write(LogEntriesCompanion(
                  revision: Value(newRevision),
                  instantUtcMs: Value(
                      command.stamp?.instantUtc.millisecondsSinceEpoch ??
                          row.instantUtcMs),
                  offsetMinutes:
                      Value(command.stamp?.offsetMinutes ?? row.offsetMinutes),
                  diaryDate: Value(command.diaryDate?.toIso() ?? row.diaryDate),
                  recordedAtMs:
                      Value(command.recordedAt.millisecondsSinceEpoch)));
          if (command.diaryDate != null && command.diaryDate!.toIso() != row.diaryDate) {
            await state.clearForEntry(row.id);
          }
          final factor = command.multiplier;
          if (factor != null) {
            for (var index = 0; index < items.length; index++) {
              if (command.itemIndex != null && index != command.itemIndex) {
                continue;
              }
              await _scaleItem(items[index], factor, revisedBatches);
            }
            final whole = command.itemIndex == null ? factor : null;
            if (whole != null) {
              final linked = await state.readForEntry(row.id);
              if (linked != null && linked.state == PlanMealState.consumed) {
                await state.updateConsumedPortions(
                    row.id, whole, linked.portions! * whole);
              }
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
                  'itemIndex': command.itemIndex,
                  'fingerprint': jsonEncode(fingerprint)
                })));
        return newRevision;
      });

  /// Replaces one frozen item with an explicitly chosen food and amount.
  ///
  /// Only the selected item changes: its name, quantity, mass, nutrients and
  /// source snapshot are frozen from the command's replacement, the other items
  /// are left byte-for-byte unchanged, and [ReviseEntryCommand]'s day/check-in
  /// invalidation rules apply. The entry revision is validated inside the same
  /// transaction, and a replay is resolved from the stored fingerprint rather
  /// than applied twice.
  ///
  /// The replacement is the food value the user reviewed; the catalogue is
  /// deliberately not re-read here. Re-reading would let a catalogue edit
  /// between review and commit silently change the nutrients or source the user
  /// confirmed, so the transaction validates only the entry revision, item
  /// position, batch linkage and amount compatibility. The receipt pins the
  /// full reviewed food snapshot, so a retry carrying different values under the
  /// same request id is a conflict instead of a silent replay. Receipts with a
  /// different fingerprint shape have no special fallback: they conflict and
  /// must be reviewed.
  ///
  /// Cooked-batch portions are refused: one stock allocation covers the whole
  /// portion, so replacing an ingredient would leave the frozen portion and the
  /// batch stock inconsistent. The caller must record another portion instead.
  Future<int> substituteItem(SubstituteEntryItemCommand command) async =>
      _db.transaction(() async {
        final fingerprint = <String, Object?>{
          'operation': 'substitute-item',
          'entryId': command.entryId,
          'expectedRevision': command.expectedRevision,
          'itemIndex': command.itemIndex,
          'foodId': command.replacement.id,
          // The frozen nutrients and source are part of what the user
          // reviewed, so the whole snapshot identifies the action; matching the
          // id alone would replay a different payload silently.
          'replacement': foodSnapshot(command.replacement),
          'amount': command.amount.toJson()
        };
        final prior = await (_db.select(_db.appliedCommands)
              ..where((t) => t.requestId.equals(command.requestId)))
            .getSingleOrNull();
        if (prior != null) {
          final result = decodeJsonMap(prior.resultJson);
          if (result['entryId'] != command.entryId ||
              !_sameFingerprint(result['fingerprint'], fingerprint)) {
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
              ..where((t) => t.entryId.equals(command.entryId))
              ..orderBy([
                (t) => OrderingTerm.asc(t.position),
                (t) => OrderingTerm.asc(t.id)
              ]))
            .get();
        if (command.itemIndex >= items.length) {
          throw StateError('ITEM_INDEX_OUT_OF_RANGE');
        }
        if (items.any((item) => _batchIdOf(item) != null)) {
          throw StateError('BATCH_ITEM_SUBSTITUTION_UNSUPPORTED');
        }
        final ResolvedFoodAmount resolved;
        try {
          resolved = resolveFoodAmount(command.replacement, command.amount);
        } on StateError {
          throw StateError('INCOMPATIBLE_SUBSTITUTION_AMOUNT');
        } on ArgumentError {
          throw StateError('INCOMPATIBLE_SUBSTITUTION_AMOUNT');
        }
        final replacement = command.replacement;
        final workspace = LocalWorkspace(_db);
        // Everything that can reject this substitution has passed; record the
        // pre-correction snapshots before rewriting the selected item.
        await workspace.put(
            requestId: 'history:${command.requestId}',
            collection: 'entry-revision',
            id: '${row.id}:${row.revision}',
            expectedRevision: 0,
            data: {
              'entry': row.toJson(),
              'items': items.map((i) => i.toJson()).toList(),
              'itemIndex': command.itemIndex,
              'deleted': false,
              'operation': 'substitute-item',
              'replacement': {
                'foodId': replacement.id,
                'amount': command.amount.toJson()
              }
            });
        final newRevision = row.revision + 1;
        final updated = await (_db.update(_db.logEntries)
              ..where((t) =>
                  t.id.equals(row.id) &
                  t.revision.equals(command.expectedRevision)))
            .write(LogEntriesCompanion(
                revision: Value(newRevision),
                recordedAtMs:
                    Value(command.recordedAt.millisecondsSinceEpoch)));
        // The revision predicate is the last write guard: a concurrent
        // correction that committed after the read cannot be overwritten.
        if (updated != 1) throw StateError('STALE_ENTRY');
        final selected = items[command.itemIndex];
        await (_db.update(_db.logEntryItems)
              ..where((t) => t.id.equals(selected.id)))
            .write(LogEntryItemsCompanion(
          name: Value(replacement.name),
          grams: Value(resolved.grams),
          quantityJson: Value(jsonEncode(command.amount.toJson())),
          sourceJson: Value(jsonEncode(_replacementSource(replacement))),
          nutrientsJson: Value(jsonEncode(
              replacement.per100g.scaledExact(resolved.factor).toJson())),
          foodId: Value(replacement.id),
        ));
        // Substitution keeps the consumed link as actual intake; it must not
        // change the planned recipe snapshot, so no state write occurs here.
        // The plan-meal-state helper is invoked for validation parity.
        await PlanMealStateService(_db).readForEntry(row.id);
        final day = await workspace.read('day', row.diaryDate);
        await workspace.put(
            requestId: 'day-revise:${command.requestId}:${row.diaryDate}',
            collection: 'day',
            id: row.diaryDate,
            expectedRevision: day?.revision ?? 0,
            data: {'completeness': 'partial'});
        await workspace.invalidateHistory();
        await _db.into(_db.appliedCommands).insert(
            AppliedCommandsCompanion.insert(
                requestId: command.requestId,
                resultJson: jsonEncode({
                  'entryId': command.entryId,
                  'revision': newRevision,
                  'itemIndex': command.itemIndex,
                  'fingerprint': jsonEncode(fingerprint)
                })));
        return newRevision;
      });

  /// Freezes the replacement food's provenance exactly as a logged pick does.
  ///
  /// Later catalogue edits cannot change this item, and the substitution itself
  /// stays visible through the entry-revision document.
  static Map<String, Object?> _replacementSource(Food food) => {
        'dataset': food.source.dataset,
        'id': food.source.datasetId,
        'version': food.source.datasetVersion,
        'preparation': food.preparation.name,
        'basisUnit': food.basisUnit.name,
        'basisValue': food.basisValue,
        'engine': 'nutrition-v2',
        'policy': 'draft-unapproved',
        'densityGPerMl': food.portions.densityGramsPerMillilitre,
        'portionGrams': food.portions.portionGrams,
        'licence': food.source.licence,
        'observations': food.observations.map((o) => o.toJson()).toList()
      };

  /// Scales one frozen item's eaten amount without consulting a catalogue.
  ///
  /// [allocationScale] is the eaten share of a recipe/batch item and scales with
  /// the eaten amount. Source quantities that define the recipe or batch itself
  /// (`rawEdibleGrams`, `ingredientQuantityG`, `finishedWeightG`) stay unchanged,
  /// as does `repeatMultiplier`, which records how the entry was created.
  Future<void> _scaleItem(LogEntryItem item, Exact factor,
      Map<String, int> revisedBatches) async {
    final quantity = item.quantityJson == null
        ? null
        : FoodAmount.fromJson(decodeJsonMap(item.quantityJson!));
    final source =
        item.sourceJson == null ? null : _scaledSource(item.sourceJson!, factor);
    if (source != null) {
      final batchId = source['batchId'];
      if (batchId is String && revisedBatches.containsKey(batchId)) {
        source['batchRevision'] = revisedBatches[batchId];
      }
    }
    await (_db.update(_db.logEntryItems)..where((t) => t.id.equals(item.id)))
        .write(LogEntryItemsCompanion(
      sourceJson: Value(source == null ? null : jsonEncode(source)),
      grams: Value(item.grams == null
          ? null
          : (Exact.parse(item.grams!.toString()) * factor).toDouble()),
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

  /// The single stock-linked identity of [item], if it came from a cooked batch.
  String? _batchIdOf(LogEntryItem item) {
    if (item.sourceJson == null) return null;
    final batchId = decodeJsonMap(item.sourceJson!)['batchId'];
    return batchId is String ? batchId : null;
  }

  /// Reads the frozen stock unit and amount claimed by every batch item.
  ///
  /// All ingredients must agree, and legacy snapshots without an explicit unit
  /// are accepted only when they contain the original gram amount field.
  Map<String, (String, Exact)> _consumedBatchAmountsByBatch(
      List<LogEntryItem> items) {
    final result = <String, (String, Exact)>{};
    for (final item in items) {
      if (item.sourceJson == null) continue;
      final source = decodeJsonMap(item.sourceJson!);
      final batchId = source['batchId'];
      if (batchId is! String) continue;
      final grams = source['consumedBatchGrams'];
      final servings = source['consumedBatchServings'];
      final unit = source['consumedBatchUnit'];
      final String resolvedUnit;
      final Map<Object?, Object?> raw;
      if (grams is Map && servings == null && (unit == null || unit == 'g')) {
        resolvedUnit = 'g';
        raw = grams;
      } else if (servings is Map && grams == null && unit == 'serving') {
        resolvedUnit = 'serving';
        raw = servings;
      } else {
        throw StateError('BATCH_RECONCILIATION_REQUIRED');
      }
      final amount = Exact.fromJson(Map<String, Object?>.from(raw));
      final current = (resolvedUnit, amount);
      final known = result[batchId];
      if (known != null && known != current) {
        throw StateError('BATCH_RECONCILIATION_REQUIRED');
      }
      result[batchId] = current;
    }
    return result;
  }

  /// Scales only the eaten-amount fields of a frozen source snapshot.
  Map<String, Object?> _scaledSource(String sourceJson, Exact factor) {
    final source = decodeJsonMap(sourceJson);
    for (final key in [
      'consumedBatchGrams',
      'consumedBatchServings',
      'recipePortions',
      'allocationScale'
    ]) {
      final value = source[key];
      if (value != null) {
        source[key] = (Exact.fromJson(Map<String, Object?>.from(value as Map)) *
                factor)
            .toJson();
      }
    }
    return source;
  }

  /// Decodes a stored fingerprint object, or returns null when it is unusable.
  static Map<String, Object?>? _decodeStoredFingerprint(Object? stored) {
    if (stored is Map) return Map<String, Object?>.from(stored);
    if (stored is! String) return null;
    try {
      final decoded = jsonDecode(stored);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// Compares a stored correction fingerprint with [current].
  ///
  /// Receipts written before [ReviseEntryCommand.itemIndex] existed have no
  /// `itemIndex` key. They describe a whole-entry correction, which is exactly
  /// `itemIndex == null`, so an identical retry remains replayable after an
  /// upgrade while a different payload is still rejected.
  static bool _sameFingerprint(Object? stored, Map<String, Object?> current) {
    final prior = _decodeStoredFingerprint(stored);
    if (prior == null) return false;
    final priorKeys = prior.keys.where((key) => key != 'itemIndex').toSet();
    final currentKeys = current.keys.where((key) => key != 'itemIndex').toSet();
    if (priorKeys.length != currentKeys.length ||
        !priorKeys.every(currentKeys.contains)) {
      return false;
    }
    if (prior['itemIndex'] != current['itemIndex']) return false;
    for (final key in currentKeys) {
      if (jsonEncode(prior[key]) != jsonEncode(current[key])) return false;
    }
    return true;
  }

  static Exact _exact(Object? json) =>
      Exact.fromJson(Map<String, Object?>.from(json! as Map));

  Future<LoggedEntry> _hydrate(LogEntry row) async {
    final itemRows = await (_db.select(_db.logEntryItems)
          ..where((t) => t.entryId.equals(row.id))
          ..orderBy([(t) => OrderingTerm.asc(t.position), (t) => OrderingTerm.asc(t.id)]))
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
