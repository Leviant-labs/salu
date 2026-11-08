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
  Future<LoggedEntry> consume(
      {required String requestId,
      required String batchId,
      required int expectedRevision,
      required Exact grams,
      required int offsetMinutes,
      required bool confirmed}) async {
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
      final next = batch.allocate(BatchAllocation(requestId, grams, 'consumed'),
          expectedRevision: expectedRevision);
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
