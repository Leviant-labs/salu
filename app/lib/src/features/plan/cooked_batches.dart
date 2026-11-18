import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'recipe_library.dart';

typedef StoredBatch = ({String id, CookedRecipeBatch batch});

class CookedBatches {
  const CookedBatches(this.documents);
  final LocalDocumentStore documents;
  static const _key = 'cooked-batches';

  Future<List<StoredBatch>> available() async => [
        for (final row
            in (await documents.read(_key))?.data['batches'] as List? ??
                const [])
          if ((row['remainingFraction'] as num) > 0)
            _decode(row as Map<String, dynamic>),
      ];

  Future<void> add(String id, CookedRecipeBatch batch) async {
    final old = await documents.read(_key);
    final entries = old?.data['batches'] as List? ?? const [];
    if (!await documents.put(_key, old?.revision ?? 0, {
      'batches': [
        ...entries,
        {
          'id': id,
          'recipe': RecipeLibrary.encodeRecipe(batch.recipe),
          'cookedServings': batch.cookedServings,
          'finishedGrams': batch.finishedGrams,
          'remainingFraction': batch.remainingFraction,
        }
      ]
    })) {
      throw StateError('Batch list changed');
    }
  }

  /// The stock debit and diary snapshot succeed together. The same meal ID
  /// cannot consume stock again on a retry.
  Future<bool> log(String id, MealPortion portion, PhotoMeal meal) =>
      documents.db.transaction(() async {
        final repository = DriftPhotoMealRepository(documents.db);
        if ((await repository.listFor(meal.date))
            .any((record) => record.id == meal.id)) {
          return false;
        }
        final old = await documents.read(_key);
        if (old == null) throw StateError('Batch no longer exists');
        final entries =
            (old.data['batches'] as List).cast<Map<String, dynamic>>();
        final index = entries.indexWhere((row) => row['id'] == id);
        if (index < 0) throw StateError('Batch no longer exists');
        final row = entries[index];
        final batch = _decode(row).batch;
        final amount = batch.consumptionFraction(portion);
        if (amount == null || amount <= 0) {
          throw StateError('Not enough batch remaining');
        }
        final items = batch
            .snapshot(amount)
            .indexed
            .map((entry) => entry.$2.copyWith(id: '${meal.id}:${entry.$1}'))
            .toList();
        if (!await repository.saveNew(meal.copyWith(items: items))) {
          return false;
        }
        final remaining = batch.remainingFraction - amount;
        entries[index] = {
          ...row,
          'remainingFraction': remaining < 1e-10 ? 0 : remaining
        };
        if (!await documents.put(_key, old.revision, {'batches': entries})) {
          throw StateError('Batch amount changed');
        }
        return true;
      });

  StoredBatch _decode(Map<String, dynamic> row) => (
        id: row['id'] as String,
        batch: CookedRecipeBatch(
            recipe: RecipeLibrary.decodeRecipe(
                row['recipe'] as Map<String, dynamic>),
            cookedServings: (row['cookedServings'] as num).toDouble(),
            finishedGrams: (row['finishedGrams'] as num?)?.toDouble(),
            remainingFraction: (row['remainingFraction'] as num).toDouble())
      );
}
