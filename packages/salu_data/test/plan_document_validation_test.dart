import 'package:salu_core/salu_core.dart';
import 'package:salu_data/src/document_validation.dart';
import 'package:salu_data/src/snapshot_codec.dart';
import 'package:test/test.dart';

void main() {
  final food = Food(id: 'f', name: 'Food', per100g: NutrientProfile({}), source: const FoodSource(dataset: 'test', datasetId: 'f'));
  final recipe = RecipeVersion(id: 'r', revision: 1, name: 'Recipe', minutes: 1, servings: Exact.one, ingredients: [RecipeIngredient(food, Exact.parse('100'))]);
  Map<String, Object?> meal(String slot, Object? batchUse) => {
    'slot': slot, 'date': '2026-01-01', 'label': 'Dinner',
    'recipe': recipeSnapshot(recipe), 'portions': Exact.one.toJson(),
    if (batchUse != null) 'batchUse': batchUse,
  };
  final use = {'batchId': 'batch', 'batchRevision': 1, 'allocationId': 'allocation'};

  test('rejects malformed and duplicate restored batch reservations', () {
    expect(() => validateUserDocument('plan', {'meals': [meal('a', use)]}), returnsNormally);
    expect(() => validateUserDocument('plan', {'meals': [meal('a', {...use, 'batchRevision': 0})]}), throwsArgumentError);
    expect(() => validateUserDocument('plan', {'meals': [meal('a', use), meal('b', use)]}), throwsFormatException);
    expect(
        () => validateUserDocument('plan', {
              'meals': [
                meal('a', use),
                meal('b', {...use, 'allocationId': 'another-allocation'})
              ]
            }),
        returnsNormally);
    expect(() => validateUserDocument('plan', {'meals': [meal('a', null)]}), returnsNormally);
  });

  test('serving stock needs no measured grams; gram stock still does', () {
    final batch = <String, Object?>{
      'recipe': recipeSnapshot(recipe),
      'available': Exact.parse('2').toJson(),
      'unit': 'serving',
      'allocations': <Object?>[],
    };
    expect(() => validateUserDocument('batch', batch), returnsNormally);
    expect(() => validateUserDocument('batch', {...batch, 'unit': 'g'}),
        throwsStateError);
  });
}
