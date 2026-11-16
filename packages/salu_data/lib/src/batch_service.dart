import 'dart:convert';

import 'package:salu_core/salu_core.dart';

import 'database/app_database.dart';
import 'document_validation.dart';
import 'repositories/drift_entry_repository.dart';
import 'snapshot_codec.dart';
import 'workspace_store.dart';

/// A finite batch and its intake commit together; retries cannot spend stock twice.
///
/// Each command stores a receipt in `applied_commands` in the same transaction
/// as its effects. Retries resolve from that receipt rather than from mutable
/// batch state, so an identical retry still returns the original result after
/// later reservations, releases or corrections, while reusing a request id with
/// different arguments is rejected instead of silently returning other work.
///
/// Stock quantities are always expressed in the batch document's own `unit`:
/// grams for a weighed batch or finished servings for a portioned batch.
/// [reserveAmount] and [consumeAmount] take that unit explicitly, so a serving
/// count is never interpreted as grams or the reverse. Receipts written before
/// the unit became explicit stored only grams; those receipts still replay for
/// gram requests and are never treated as serving quantities.
final class BatchService {
  BatchService(this.db, this.clock, this.ids);
  final AppDatabase db;
  final Clock clock;
  final IdGenerator ids;

  static String _key(String operation, String requestId) =>
      'batch-$operation:$requestId';

  static Exact _amount(Object? json) =>
      Exact.fromJson(Map<String, Object?>.from(json! as Map));

  static bool _isStockUnit(FoodUnit unit) =>
      unit == FoodUnit.g || unit == FoodUnit.serving;

  /// Whether a stored receipt describes exactly [amount] in [unit].
  ///
  /// Receipts written before stock became unit-explicit only contain `grams`
  /// and only ever described gram batches, so they match a gram request and
  /// never a serving request. A serving amount is never read out of a gram
  /// field, and a gram request is never satisfied by a serving receipt.
  static bool _receiptMatches(
      Map<String, Object?> receipt, Exact amount, FoodUnit unit) {
    final stored = receipt['amount'];
    if (stored != null) {
      // An amount without an explicit unit is never guessed as grams.
      if (receipt['unit'] != unit.name) return false;
      return _amount(stored) == amount;
    }
    final grams = receipt['grams'];
    if (grams == null || unit != FoodUnit.g) return false;
    return _amount(grams) == amount;
  }

  static Map<String, Object?>? _payload(Map<String, Object?> receipt) {
    final payload = receipt['payload'];
    final decoded = payload is String ? jsonDecode(payload) : payload;
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  }

  static List<BatchAllocation> _allocations(Map<String, Object?> data) => [
        for (final raw in data['allocations']! as List)
          BatchAllocation(
              (raw as Map)['id']! as String,
              _amount(raw['amount']),
              raw['status']! as String,
              intakeRequestId: raw['intakeRequestId'] as String?)
      ];

  static Map<String, Object?> _withAllocations(
          Map<String, Object?> data, List<BatchAllocation> allocations) =>
      {
        ...data,
        'allocations': [
          for (final a in allocations)
            {
              'id': a.id,
              'amount': a.amount.toJson(),
              'status': a.status,
              if (a.intakeRequestId != null) 'intakeRequestId': a.intakeRequestId
            }
        ]
      };

  static FoodUnit _documentUnit(Map<String, Object?> data) {
    final unit = FoodUnit.values.byName(data['unit']! as String);
    if (!_isStockUnit(unit)) throw StateError('BATCH_UNIT_MISMATCH');
    return unit;
  }

  /// Reconstructs the domain batch so its stock ceiling and allocation rules
  /// are enforced before any document write. Serving batches may omit the
  /// measured finished weight; gram batches cannot.
  static CookedBatch _batch(
      String id, int revision, Map<String, Object?> data) {
    final finished = data['finishedWeightG'];
    return CookedBatch(
        id: id,
        recipe: recipeFromSnapshot(
            Map<String, Object?>.from(data['recipe']! as Map)),
        revision: revision,
        available: _amount(data['available']),
        unit: _documentUnit(data),
        finishedWeightG: finished == null ? null : _amount(finished),
        allocations: _allocations(data));
  }

  /// Reads a receipt previously committed in the same transaction as its
  /// effects. Legacy receipts lack a complete request fingerprint and are
  /// rejected for review rather than replayed as a potentially different call.
  Future<Map<String, Object?>?> _applied(String requestId) async {
    final row = await (db.select(db.appliedCommands)
          ..where((t) => t.requestId.equals(requestId)))
        .getSingleOrNull();
    if (row == null) return null;
    final decoded = jsonDecode(row.resultJson);
    if (decoded is! Map) throw StateError('REQUEST_ID_REUSED');
    return Map<String, Object?>.from(decoded);
  }

  Future<Map<String, Object?>?> _receipt(
          String operation, String requestId) =>
      _applied(_key(operation, requestId));

  Future<void> _record(String operation, String requestId,
      Map<String, Object?> receipt) async {
    await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
        requestId: _key(operation, requestId),
        resultJson: jsonEncode({'operation': operation, ...receipt})));
  }

  /// Writes a batch document together with the one receipt that describes the
  /// whole command. [LocalWorkspace.put] would add a second, fingerprint-free
  /// receipt; a batch command instead stores its arguments once so a retry can
  /// be told apart from a request id that was reused for other work.
  Future<int> _writeBatch({
    required String requestId,
    required String operation,
    required String batchId,
    required int expectedRevision,
    required Map<String, Object?> data,
    required Map<String, Object?> fingerprint,
  }) async {
    validateUserDocument('batch', data);
    final latest = await LocalWorkspace(db).read('batch', batchId);
    if ((latest?.revision ?? 0) != expectedRevision) {
      throw StateError('STALE_BATCH');
    }
    final revision = expectedRevision + 1;
    await db.into(db.userDocuments).insertOnConflictUpdate(
        UserDocumentsCompanion.insert(
            collection: 'batch',
            id: batchId,
            revision: revision,
            payload: jsonEncode(data)));
    await _record(operation, requestId, {...fingerprint, 'revision': revision});
    return revision;
  }

  /// Resolves a retried reservation from its receipt, rejecting a request id
  /// that was already used for a different reservation.
  Future<int?> _reserveOutcome(String requestId, String batchId,
      String allocationId, int expectedRevision, Exact amount,
      FoodUnit unit) async {
    final receipt = await _receipt('reserve', requestId);
    if (receipt != null) {
      if (receipt['operation'] != 'reserve' ||
          receipt['batchId'] != batchId ||
          receipt['allocationId'] != allocationId ||
          receipt['expectedRevision'] != expectedRevision ||
          !_receiptMatches(receipt, amount, unit)) {
        throw StateError('REQUEST_ID_REUSED');
      }
      return receipt['revision']! as int;
    }
    final legacy = await _applied('reserve:$requestId');
    if (legacy == null) return null;
    final payload = _payload(legacy);
    if (legacy['collection'] != 'batch' ||
        legacy['id'] != batchId ||
        legacy['revision'] != expectedRevision + 1 ||
        payload == null) {
      throw StateError('REQUEST_ID_REUSED');
    }
    // Legacy reservation receipts predate serving stock; they can only
    // describe a gram reservation.
    if (unit != FoodUnit.g) throw StateError('REQUEST_ID_REUSED');
    final allocations = payload['allocations'];
    if (allocations is! List) throw StateError('REQUEST_ID_REUSED');
    for (final raw in allocations) {
      if (raw is! Map || raw['id'] != allocationId) continue;
      if (raw['status'] != BatchAllocation.plannedStatus ||
          _amount(raw['amount']) != amount) {
        throw StateError('REQUEST_ID_REUSED');
      }
      // The legacy receipt only stored the final allocation list, so this
      // allocation may have existed before the request. Do not guess.
      throw StateError('LEGACY_REQUEST_REVIEW_REQUIRED');
    }
    throw StateError('REQUEST_ID_REUSED');
  }

  /// Resolves a retried release from its receipt, rejecting a request id
  /// that was already used for a different allocation.
  Future<int?> _releaseOutcome(String requestId, String batchId,
      String allocationId, int expectedRevision) async {
    final receipt = await _receipt('release', requestId);
    if (receipt != null) {
      if (receipt['operation'] != 'release' ||
          receipt['batchId'] != batchId ||
          receipt['allocationId'] != allocationId ||
          receipt['expectedRevision'] != expectedRevision) {
        throw StateError('REQUEST_ID_REUSED');
      }
      return receipt['revision']! as int;
    }
    final legacy = await _applied('release:$requestId');
    if (legacy == null) return null;
    final payload = _payload(legacy);
    if (legacy['collection'] != 'batch' ||
        legacy['id'] != batchId ||
        legacy['revision'] != expectedRevision + 1 ||
        payload == null) {
      throw StateError('REQUEST_ID_REUSED');
    }
    final allocations = payload['allocations'];
    if (allocations is! List) throw StateError('REQUEST_ID_REUSED');
    for (final raw in allocations) {
      if (raw is Map && raw['id'] == allocationId) {
        throw StateError('REQUEST_ID_REUSED');
      }
    }
    // A post-release snapshot does not identify which allocation was removed.
    throw StateError('LEGACY_REQUEST_REVIEW_REQUIRED');
  }

  /// Resolves a retried consumption from its receipt and returns the diary
  /// entry written by the first attempt, or null when this is a first attempt.
  Future<LoggedEntry?> _consumeOutcome(
      DriftEntryRepository entries,
      {required String requestId,
      required String batchId,
      required int expectedRevision,
      required Exact amount,
      required FoodUnit unit,
      required int offsetMinutes,
      required String? reservedAllocationId,
      EntryChannel channel = EntryChannel.manual,
      EventStamp? occurredAt,
      DiaryDate? assignedDiaryDate}) async {
    final receipt = await _receipt('consume', requestId);
    if (receipt != null) {
      final stampJson = occurredAt == null
          ? null
          : {
              'utc': occurredAt.instantUtc.toIso8601String(),
              'offset': occurredAt.offsetMinutes
            };
      if (receipt['operation'] != 'consume' ||
          receipt['batchId'] != batchId ||
          receipt['expectedRevision'] != expectedRevision ||
          !_receiptMatches(receipt, amount, unit) ||
          receipt['offsetMinutes'] != offsetMinutes ||
          receipt['reservedAllocationId'] != reservedAllocationId) {
        throw StateError('REQUEST_ID_REUSED');
      }
      // Receipts predating channel/stamp/day carry none of these keys; accept
      // only default/absent args against them. Explicit new values on an old
      // receipt are a reuse conflict, never a silent second spend.
      final hasChannel = receipt.containsKey('channel');
      if (hasChannel) {
        if (receipt['channel'] != channel.name) {
          throw StateError('REQUEST_ID_REUSED');
        }
      } else if (channel != EntryChannel.manual) {
        throw StateError('REQUEST_ID_REUSED');
      }
      final hasStamp = receipt.containsKey('occurredAt');
      if (hasStamp) {
        if (jsonEncode(receipt['occurredAt']) != jsonEncode(stampJson)) {
          throw StateError('REQUEST_ID_REUSED');
        }
      } else if (occurredAt != null) {
        throw StateError('REQUEST_ID_REUSED');
      }
      final hasDay = receipt.containsKey('assignedDiaryDate');
      if (hasDay) {
        if (receipt['assignedDiaryDate'] != assignedDiaryDate?.toIso()) {
          throw StateError('REQUEST_ID_REUSED');
        }
      } else if (assignedDiaryDate != null) {
        throw StateError('REQUEST_ID_REUSED');
      }
      final prior = await entries.findByRequestId(requestId);
      if (prior == null) throw StateError('BATCH_CONSUMPTION_MISSING');
      if (receipt['entryId'] != prior.id) {
        throw StateError('REQUEST_ID_REUSED');
      }
      return prior;
    }
    final legacy = await _applied('stock:$requestId');
    if (legacy == null) return null;
    final payload = _payload(legacy);
    if (legacy['collection'] != 'batch' ||
        legacy['id'] != batchId ||
        legacy['revision'] != expectedRevision + 1 ||
        payload == null) {
      throw StateError('REQUEST_ID_REUSED');
    }
    // Legacy stock receipts predate serving stock; they only described grams.
    if (unit != FoodUnit.g) throw StateError('REQUEST_ID_REUSED');
    final allocations = payload['allocations'];
    if (allocations is! List) throw StateError('REQUEST_ID_REUSED');
    var found = false;
    for (final raw in allocations) {
      if (raw is! Map || raw['id'] != requestId) continue;
      if (raw['status'] != BatchAllocation.consumedStatus ||
          _amount(raw['amount']) != amount) {
        throw StateError('REQUEST_ID_REUSED');
      }
      found = true;
    }
    if (!found) throw StateError('REQUEST_ID_REUSED');
    final prior = await entries.findByRequestId(requestId);
    if (prior == null) throw StateError('BATCH_CONSUMPTION_MISSING');
    if (prior.stamp.offsetMinutes != offsetMinutes) {
      throw StateError('REQUEST_ID_REUSED');
    }
    // Legacy stock receipts did not preserve the reservation identifier.
    throw StateError('LEGACY_REQUEST_REVIEW_REQUIRED');
  }

  /// Reserve [amount] of stock, measured in [unit], for a planned meal without
  /// logging intake.
  ///
  /// [unit] must equal the batch document's stored unit, so a serving count is
  /// never interpreted as grams or the reverse. [allocationId] is stable across
  /// retries and unique within the batch.
  Future<int> reserveAmount(
      {required String requestId,
      required String batchId,
      required String allocationId,
      required int expectedRevision,
      required Exact amount,
      required FoodUnit unit}) async {
    if (requestId.isEmpty || allocationId.isEmpty || !amount.positive) {
      throw ArgumentError(
          'A positive quantity and stable identifiers are required');
    }
    if (!_isStockUnit(unit)) {
      throw ArgumentError('Cooked stock is measured in grams or servings');
    }
    return db.transaction(() async {
      final prior = await _reserveOutcome(
          requestId, batchId, allocationId, expectedRevision, amount, unit);
      if (prior != null) return prior;
      final workspace = LocalWorkspace(db);
      final doc = await workspace.read('batch', batchId);
      if (doc == null || doc.revision != expectedRevision) {
        throw StateError('STALE_BATCH');
      }
      final data = doc.data;
      if (_documentUnit(data) != unit) {
        throw StateError('BATCH_UNIT_MISMATCH');
      }
      final allocations = _allocations(data);
      final existing =
          allocations.where((a) => a.id == allocationId).firstOrNull;
      if (existing != null) {
        if (existing.status != BatchAllocation.plannedStatus ||
            existing.amount != amount) {
          throw StateError('BATCH_ALLOCATION_CONFLICT');
        }
        // Another request already holds this exact reservation: a no-op, but
        // recorded so a retry still resolves after the allocation is consumed
        // or released by later work.
        await _record('reserve', requestId, {
          'batchId': batchId,
          'allocationId': allocationId,
          'expectedRevision': expectedRevision,
          'amount': amount.toJson(),
          'unit': unit.name,
          'revision': doc.revision
        });
        return doc.revision;
      }
      final batch = _batch(batchId, doc.revision, data);
      final next = batch.allocate(
          BatchAllocation(
              allocationId, amount, BatchAllocation.plannedStatus),
          expectedRevision: expectedRevision);
      return _writeBatch(
          requestId: requestId,
          operation: 'reserve',
          batchId: batchId,
          expectedRevision: expectedRevision,
          data: _withAllocations(data, next.allocations),
          fingerprint: {
            'batchId': batchId,
            'allocationId': allocationId,
            'expectedRevision': expectedRevision,
            'amount': amount.toJson(),
            'unit': unit.name
          });
    });
  }

  /// Free an unconsumed reservation; a consumed allocation is never removed.
  /// Releasing an already absent reservation is an idempotent no-op.
  Future<int> releaseReservation(
      {required String requestId,
      required String batchId,
      required String allocationId,
      required int expectedRevision}) async {
    if (requestId.isEmpty || allocationId.isEmpty) {
      throw ArgumentError('Stable identifiers are required');
    }
    return db.transaction(() async {
      final prior = await _releaseOutcome(
          requestId, batchId, allocationId, expectedRevision);
      if (prior != null) return prior;
      final workspace = LocalWorkspace(db);
      final doc = await workspace.read('batch', batchId);
      if (doc == null || doc.revision != expectedRevision) {
        throw StateError('STALE_BATCH');
      }
      final allocations = (doc.data['allocations']! as List)
          .map((v) => Map<String, Object?>.from(v as Map))
          .toList();
      final found =
          allocations.where((a) => a['id'] == allocationId).firstOrNull;
      if (found == null) {
        // Nothing to free, but record the outcome so a retry can never later
        // release a reservation created after this request.
        await _record('release', requestId, {
          'batchId': batchId,
          'allocationId': allocationId,
          'expectedRevision': expectedRevision,
          'revision': doc.revision
        });
        return doc.revision;
      }
      if (found['status'] != BatchAllocation.plannedStatus) {
        throw StateError('BATCH_ALLOCATION_ALREADY_CONSUMED');
      }
      allocations.removeWhere((a) => a['id'] == allocationId);
      return _writeBatch(
          requestId: requestId,
          operation: 'release',
          batchId: batchId,
          expectedRevision: expectedRevision,
          data: {...doc.data, 'allocations': allocations},
          fingerprint: {
            'batchId': batchId,
            'allocationId': allocationId,
            'expectedRevision': expectedRevision
          });
    });
  }

  /// Record confirmed intake of [amount], measured in [unit], from a batch.
  ///
  /// Serving batches scale recipe nutrients by `amount / recipe.servings`;
  /// gram batches scale by `grams / finishedWeightG`. The frozen source
  /// snapshot records which quantity was spent, never a converted gram weight
  /// for serving stock, so later entry corrections can scale the exact amount.
  Future<LoggedEntry> consumeAmount(
      {required String requestId,
      required String batchId,
      required int expectedRevision,
      required Exact amount,
      required FoodUnit unit,
      required int offsetMinutes,
      required bool confirmed,
      String? reservedAllocationId,
      EntryChannel channel = EntryChannel.manual,
      EventStamp? occurredAt,
      DiaryDate? assignedDiaryDate}) async {
    if (!confirmed || requestId.isEmpty || !amount.positive) {
      throw ArgumentError('Confirmed positive batch quantity required');
    }
    if (occurredAt != null && occurredAt.offsetMinutes != offsetMinutes) {
      throw StateError('INVALID_TIME_OFFSET');
    }
    if (!_isStockUnit(unit)) {
      throw ArgumentError('Cooked stock is measured in grams or servings');
    }
    return db.transaction(() async {
      final entries = DriftEntryRepository(db);
      final prior = await _consumeOutcome(entries,
          requestId: requestId,
          batchId: batchId,
          expectedRevision: expectedRevision,
          amount: amount,
          unit: unit,
          offsetMinutes: offsetMinutes,
          reservedAllocationId: reservedAllocationId,
          channel: channel,
          occurredAt: occurredAt,
          assignedDiaryDate: assignedDiaryDate);
      if (prior != null) return prior;
      if (await entries.findByRequestId(requestId) != null) {
        // The request id belongs to another diary entry; returning it would
        // report unrelated intake as this batch consumption.
        throw StateError('REQUEST_ID_REUSED');
      }
      final workspace = LocalWorkspace(db);
      final doc = await workspace.read('batch', batchId);
      if (doc == null || doc.revision != expectedRevision) {
        throw StateError('STALE_BATCH');
      }
      final data = doc.data;
      if (_documentUnit(data) != unit) {
        throw StateError('BATCH_UNIT_MISMATCH');
      }
      final batch = _batch(batchId, doc.revision, data);
      final recipe = batch.recipe;
      final allocations = batch.allocations;
      final CookedBatch next;
      if (reservedAllocationId == null) {
        next = batch.allocate(
            BatchAllocation(
                requestId, amount, BatchAllocation.consumedStatus),
            expectedRevision: expectedRevision);
      } else {
        final reservation =
            allocations.where((a) => a.id == reservedAllocationId).firstOrNull;
        if (reservation == null ||
            reservation.status != BatchAllocation.plannedStatus ||
            reservation.amount != amount) {
          throw StateError('BATCH_RESERVATION_MISMATCH');
        }
        // Keep the plan's reservation identity stable; the separate intake
        // request links diary corrections to the same finite allocation.
        next = CookedBatch(
            id: batch.id,
            recipe: batch.recipe,
            revision: batch.revision + 1,
            available: batch.available,
            unit: batch.unit,
            finishedWeightG: batch.finishedWeightG,
            allocations: [
              for (final a in allocations)
                if (a.id == reservedAllocationId)
                  BatchAllocation(a.id, a.amount,
                      BatchAllocation.consumedStatus,
                      intakeRequestId: requestId)
                else
                  a
            ]);
      }
      final factor = unit == FoodUnit.g
          ? amount / batch.finishedWeightG!
          : amount / recipe.servings;
      final stamp = occurredAt ??
          EventStamp(instant: clock.nowUtc(), offsetMinutes: offsetMinutes);
      if (stamp.offsetMinutes != offsetMinutes) {
        throw StateError('INVALID_TIME_OFFSET');
      }
      final entry = LoggedEntry(
          id: ids.next(),
          requestId: requestId,
          diaryDate: assignedDiaryDate ?? DiaryDate.assign(stamp),
          stamp: stamp,
          channel: channel,
          recordedAt: clock.nowUtc(),
          items: [
            for (final ingredient in recipe.ingredients)
              LoggedItem(
                  name: ingredient.food.name,
                  grams: null,
                  nutrients: ingredient.nutrients.scaledExact(factor),
                  foodId: ingredient.food.id,
                  quantity:
                      FoodAmount.exact(ingredient.grams * factor, FoodUnit.g),
                  sourceSnapshot: {
                    'batchId': batchId,
                    'batchRevision': doc.revision,
                    'recipeId': recipe.id,
                    'recipeRevision': recipe.revision,
                    'recipeName': recipe.name,
                    'recipePortions': (factor * recipe.servings).toJson(),
                    'consumedBatchUnit': unit.name,
                    if (unit == FoodUnit.g)
                      'finishedWeightG': batch.finishedWeightG!.toJson()
                    else
                      'recipeServings': recipe.servings.toJson(),
                    'allocationScale': factor.toJson(),
                    if (unit == FoodUnit.g)
                      'consumedBatchGrams': amount.toJson()
                    else
                      'consumedBatchServings': amount.toJson(),
                    'reservedAllocationId': reservedAllocationId,
                    'quantityBasis': 'raw-edible-ingredient-allocation',
                    'ingredientQuantityG': ingredient.grams.toJson(),
                    'dataset': ingredient.food.source.dataset,
                    'sourceId': ingredient.food.source.datasetId,
                    'sourceVersion': ingredient.food.source.datasetVersion,
                    'cookingLossesModeled': false
                  })
          ]);
      await _writeBatch(
          requestId: requestId,
          operation: 'consume',
          batchId: batchId,
          expectedRevision: expectedRevision,
          data: _withAllocations(data, next.allocations),
          fingerprint: {
            'batchId': batchId,
            'expectedRevision': expectedRevision,
            'amount': amount.toJson(),
            'unit': unit.name,
            'offsetMinutes': offsetMinutes,
            'reservedAllocationId': reservedAllocationId,
            'channel': channel.name,
            'occurredAt': occurredAt == null
                ? null
                : {
                    'utc': occurredAt.instantUtc.toIso8601String(),
                    'offset': occurredAt.offsetMinutes
                  },
            'assignedDiaryDate': assignedDiaryDate?.toIso(),
            'entryId': entry.id
          });
      await entries.append(entry);
      return entry;
    });
  }
}
