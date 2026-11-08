import 'package:salu_core/salu_core.dart';
import 'database/app_database.dart';
import 'workspace_store.dart';
import 'snapshot_codec.dart';
import 'repositories/drift_entry_repository.dart';

/// A finite batch and its intake commit together; retries cannot spend stock twice.
final class BatchService {
  BatchService(this.db, this.clock, this.ids);
  final AppDatabase db;
  final Clock clock;
  final IdGenerator ids;

  /// Reserve measured cooked stock for a planned meal without logging intake.
  /// [allocationId] is stable across retries and unique within the batch.
  Future<int> reserve(
      {required String requestId,
      required String batchId,
      required String allocationId,
      required int expectedRevision,
      required Exact grams}) async {
    if (requestId.isEmpty || allocationId.isEmpty || !grams.positive) {
      throw ArgumentError(
          'A positive quantity and stable identifiers are required');
    }
    return db.transaction(() async {
      final workspace = LocalWorkspace(db);
      final doc = await workspace.read('batch', batchId);
      if (doc == null) throw StateError('STALE_BATCH');
      final data = doc.data;
      if (data['unit'] != 'g') throw StateError('BATCH_UNIT_MISMATCH');
      final allocations = <BatchAllocation>[
        for (final v in data['allocations']! as List)
          BatchAllocation(
              (v as Map)['id']! as String,
              Exact.fromJson(Map<String, Object?>.from(v['amount']! as Map)),
              v['status']! as String)
      ];
      final existing =
          allocations.where((a) => a.id == allocationId).firstOrNull;
      if (existing != null) {
        if (existing.status == 'planned' && existing.amount == grams) {
          return doc.revision;
        }
        throw StateError('BATCH_ALLOCATION_CONFLICT');
      }
      if (doc.revision != expectedRevision) throw StateError('STALE_BATCH');
      final recipe =
          recipeFromSnapshot(Map<String, Object?>.from(data['recipe']! as Map));
      final batch = CookedBatch(
          id: batchId,
          recipe: recipe,
          revision: doc.revision,
          available: Exact.fromJson(
              Map<String, Object?>.from(data['available']! as Map)),
          unit: FoodUnit.g,
          finishedWeightG: Exact.fromJson(
              Map<String, Object?>.from(data['finishedWeightG']! as Map)),
          allocations: allocations);
      final next = batch.allocate(
          BatchAllocation(allocationId, grams, 'planned'),
          expectedRevision: expectedRevision);
      return workspace.put(
          requestId: 'reserve:$requestId',
          collection: 'batch',
          id: batchId,
          expectedRevision: expectedRevision,
          data: {
            ...data,
            'allocations': [
              for (final a in next.allocations)
                {'id': a.id, 'amount': a.amount.toJson(), 'status': a.status}
            ]
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
      final workspace = LocalWorkspace(db);
      final doc = await workspace.read('batch', batchId);
      if (doc == null) throw StateError('STALE_BATCH');
      final allocations = (doc.data['allocations']! as List)
          .map((v) => Map<String, Object?>.from(v as Map))
          .toList();
      final found =
          allocations.where((a) => a['id'] == allocationId).firstOrNull;
      if (found == null) return doc.revision;
      if (doc.revision != expectedRevision) throw StateError('STALE_BATCH');
      if (found['status'] != 'planned') {
        throw StateError('BATCH_ALLOCATION_ALREADY_CONSUMED');
      }
      allocations.removeWhere((a) => a['id'] == allocationId);
      return workspace.put(
          requestId: 'release:$requestId',
          collection: 'batch',
          id: batchId,
          expectedRevision: expectedRevision,
          data: {...doc.data, 'allocations': allocations});
    });
  }

  Future<LoggedEntry> consume(
      {required String requestId,
      required String batchId,
      required int expectedRevision,
      required Exact grams,
      required int offsetMinutes,
      required bool confirmed,
      String? reservedAllocationId}) async {
    if (!confirmed || requestId.isEmpty || !grams.positive) {
      throw ArgumentError('Confirmed positive batch quantity required');
    }
    return db.transaction(() async {
      final entries = DriftEntryRepository(db);
      final prior = await entries.findByRequestId(requestId);
      if (prior != null) return prior;
      final workspace = LocalWorkspace(db);
      final doc = await workspace.read('batch', batchId);
      if (doc == null || doc.revision != expectedRevision) {
        throw StateError('STALE_BATCH');
      }
      final data = doc.data;
      if (data['unit'] != 'g') throw StateError('BATCH_UNIT_MISMATCH');
      final recipe =
          recipeFromSnapshot(Map<String, Object?>.from(data['recipe']! as Map));
      final stock =
          Exact.fromJson(Map<String, Object?>.from(data['available']! as Map));
      final finished = Exact.fromJson(
          Map<String, Object?>.from(data['finishedWeightG']! as Map));
      final allocations = <BatchAllocation>[
        for (final v in data['allocations']! as List)
          BatchAllocation(
              (v as Map)['id']! as String,
              Exact.fromJson(Map<String, Object?>.from(v['amount']! as Map)),
              v['status']! as String)
      ];
      final batch = CookedBatch(
          id: batchId,
          recipe: recipe,
          revision: doc.revision,
          available: stock,
          unit: FoodUnit.g,
          finishedWeightG: finished,
          allocations: allocations);
      final CookedBatch next;
      if (reservedAllocationId == null) {
        next = batch.allocate(BatchAllocation(requestId, grams, 'consumed'),
            expectedRevision: expectedRevision);
      } else {
        final reservation =
            allocations.where((a) => a.id == reservedAllocationId).firstOrNull;
        if (reservation == null ||
            reservation.status != 'planned' ||
            reservation.amount != grams) {
          throw StateError('BATCH_RESERVATION_MISMATCH');
        }
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
                  BatchAllocation(requestId, a.amount, 'consumed')
                else
                  a
            ]);
      }
      final stamp =
          EventStamp(instant: clock.nowUtc(), offsetMinutes: offsetMinutes);
      final factor = grams / finished;
      final entry = LoggedEntry(
          id: ids.next(),
          requestId: requestId,
          diaryDate: DiaryDate.assign(stamp),
          stamp: stamp,
          channel: EntryChannel.manual,
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
                    'finishedWeightG': finished.toJson(),
                    'allocationScale': factor.toJson(),
                    'consumedBatchGrams': grams.toJson(),
                    'quantityBasis': 'raw-edible-ingredient-allocation',
                    'ingredientQuantityG': ingredient.grams.toJson(),
                    'dataset': ingredient.food.source.dataset,
                    'sourceId': ingredient.food.source.datasetId,
                    'sourceVersion': ingredient.food.source.datasetVersion,
                    'cookingLossesModeled': false
                  })
          ]);
      await workspace.put(
          requestId: 'stock:$requestId',
          collection: 'batch',
          id: batchId,
          expectedRevision: expectedRevision,
          data: {
            ...data,
            'allocations': [
              for (final a in next.allocations)
                {'id': a.id, 'amount': a.amount.toJson(), 'status': a.status}
            ]
          });
      await entries.append(entry);
      return entry;
    });
  }
}
