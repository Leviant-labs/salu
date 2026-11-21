import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

/// App-authored recipes on top of versioned edible-food reference records.
/// Where an ingredient is cooked, the shopping amount is for the ready-cooked
/// form. The app must not infer dry amounts from cooked weights.
class RecipeLibrary {
  const RecipeLibrary(this.foods, this.documents);
  final FoodRepository foods;
  final LocalDocumentStore documents;

  static const _key = 'recipe-library';

  Future<List<RecipeVersion>> load() async {
    final local = await documents.read(_key);
    final user = (local?.data['recipes'] as List? ?? const [])
        .map((raw) => decodeRecipe(raw as Map<String, dynamic>));
    final ids = _recipes
        .expand(
            (recipe) => recipe.ingredients.map((ingredient) => ingredient.$1))
        .toSet();
    final entries = <int, Food>{};
    await Future.wait(ids.map((id) async {
      final food = await foods.findById('bundled-fdc-$id');
      if (food != null) entries[id] = food;
    }));
    return [
      for (final recipe in _recipes)
        if (recipe.ingredients
            .every((ingredient) => entries.containsKey(ingredient.$1)))
          RecipeVersion(
              id: recipe.id,
              name: recipe.name,
              prepMinutes: recipe.minutes,
              method: recipe.method,
              allergens: recipe.allergens,
              allergenSource: recipe.allergenSource,
              ingredients: [
                for (final (id, grams, name) in recipe.ingredients)
                  RecipeIngredient(
                      food: entries[id]!,
                      edibleGrams: grams,
                      purchaseName: name,
                      purchaseGrams: grams),
              ]),
      ...user,
    ];
  }

  Future<void> add(RecipeVersion recipe) async {
    final previous = await documents.read(_key);
    final rows = previous?.data['recipes'] as List? ?? const [];
    if (rows.any((row) =>
        row is Map &&
        row['id'] == recipe.id &&
        row['version'] == recipe.version)) {
      throw StateError('This recipe version already exists');
    }
    if (!await documents.put(_key, previous?.revision ?? 0, {
      'recipes': [...rows, encodeRecipe(recipe)]
    })) {
      throw StateError('The recipe library changed. Try again.');
    }
  }

  static Map<String, Object?> encodeRecipe(RecipeVersion recipe) => {
        'id': recipe.id,
        'name': recipe.name,
        'version': recipe.version,
        'prepMinutes': recipe.prepMinutes,
        'servings': recipe.servings,
        'finishedGrams': recipe.finishedGrams,
        'method': recipe.method,
        if (recipe.allergens != null) 'allergens': recipe.allergens!.toList(),
        if (recipe.allergenSource != null)
          'allergenSource': recipe.allergenSource,
        'ingredients': [
          for (final i in recipe.ingredients)
            {
              'id': i.food.id,
              'name': i.food.name,
              'nutrients': i.food.per100g.toJson(),
              'source': i.food.source.dataset,
              'sourceId': i.food.source.datasetId,
              'sourceVersion': i.food.source.datasetVersion,
              'preparation': i.food.preparation.name,
              'edibleGrams': i.edibleGrams,
              'purchaseName': i.purchaseName,
              'purchaseGrams': i.purchaseGrams,
            }
        ],
      };

  static RecipeVersion decodeRecipe(Map<String, dynamic> row) => RecipeVersion(
        id: row['id'] as String,
        name: row['name'] as String,
        version: row['version'] as int,
        prepMinutes: row['prepMinutes'] as int,
        servings: (row['servings'] as num).toDouble(),
        finishedGrams: (row['finishedGrams'] as num?)?.toDouble(),
        method: row['method'] as String,
        allergens: (row['allergens'] as List?)?.cast<String>().toSet(),
        allergenSource: row['allergenSource'] as String?,
        ingredients: [
          for (final raw in row['ingredients'] as List)
            _ingredient(raw as Map<String, dynamic>)
        ],
      );

  static RecipeIngredient _ingredient(Map<String, dynamic> row) =>
      RecipeIngredient(
        food: Food(
            id: row['id'] as String,
            name: row['name'] as String,
            per100g: NutrientProfile.fromJson(
                row['nutrients'] as Map<String, dynamic>),
            preparation:
                Preparation.values.byName(row['preparation'] as String),
            source: FoodSource(
                dataset: row['source'] as String,
                datasetId: row['sourceId'] as String,
                datasetVersion: row['sourceVersion'] as String?)),
        edibleGrams: (row['edibleGrams'] as num).toDouble(),
        purchaseName: row['purchaseName'] as String,
        purchaseGrams: (row['purchaseGrams'] as num?)?.toDouble(),
      );
}

const _starterAllergenProvenance =
    'Salu starter ingredient review (2026-11-21) against USDA FDC SR Legacy 2018-04 listed ingredients; listed ingredients only, not a cross-contamination guarantee.';

typedef _Starter = ({
  String id,
  String name,
  int minutes,
  String method,
  Set<String>? allergens,
  String? allergenSource,
  List<(int, double, String)> ingredients
});
const _recipes = <_Starter>[
  (
    id: 'chickpea-tomato',
    name: 'Chickpea and tomato salad',
    minutes: 10,
    method:
        'Toss chopped tomato and onion with drained chickpeas and olive oil.',
    allergens: <String>{},
    allergenSource: _starterAllergenProvenance,
    ingredients: [
      (173757, 180, 'Cooked chickpeas, drained'),
      (170457, 120, 'Tomatoes'),
      (170000, 25, 'Onions'),
      (171413, 10, 'Olive oil')
    ]
  ),
  (
    id: 'sardine-toast',
    name: 'Sardine and tomato toast',
    minutes: 10,
    method:
        'Toast the bread, then top with drained sardines and sliced tomato.',
    allergens: null,
    allergenSource: null,
    ingredients: [
      (175139, 90, 'Oil-packed sardines, drained'),
      (172688, 90, 'Whole-wheat bread'),
      (170457, 90, 'Tomatoes')
    ]
  ),
  (
    id: 'yogurt-oats',
    name: 'Yogurt, banana and oats',
    minutes: 5,
    method: 'Stir oats into the yogurt and top with sliced banana.',
    allergens: <String>{'milk', 'wheatGluten'},
    allergenSource: _starterAllergenProvenance,
    ingredients: [
      (171304, 200, 'Plain Greek yogurt'),
      (169705, 55, 'Dry oats'),
      (173944, 110, 'Bananas (edible weight)')
    ]
  ),
  (
    id: 'lentil-rice',
    name: 'Lentil and rice bowl',
    minutes: 15,
    method:
        'Warm cooked rice and lentils; serve with sliced tomato and olive oil.',
    allergens: <String>{},
    allergenSource: _starterAllergenProvenance,
    ingredients: [
      (172421, 160, 'Cooked lentils, drained'),
      (169757, 165, 'Cooked white rice'),
      (170457, 95, 'Tomatoes'),
      (171413, 8, 'Olive oil')
    ]
  ),
  (
    id: 'tofu-quinoa',
    name: 'Tofu quinoa bowl',
    minutes: 20,
    method: 'Pan-sear diced tofu and carrot; serve over warm cooked quinoa.',
    allergens: <String>{'soy'},
    allergenSource: _starterAllergenProvenance,
    ingredients: [
      (172475, 150, 'Firm tofu'),
      (168917, 160, 'Cooked quinoa'),
      (170393, 100, 'Carrots'),
      (171413, 8, 'Olive oil')
    ]
  ),
  (
    id: 'tuna-pasta',
    name: 'Tuna and tomato pasta',
    minutes: 15,
    method:
        'Toss warm cooked pasta with drained tuna, sliced tomato and olive oil.',
    allergens: null,
    allergenSource: null,
    ingredients: [
      (168928, 185, 'Cooked pasta'),
      (173709, 110, 'Tuna in water, drained'),
      (170457, 130, 'Tomatoes'),
      (171413, 10, 'Olive oil')
    ]
  ),
  (
    id: 'chicken-couscous',
    name: 'Chicken and couscous bowl',
    minutes: 15,
    method:
        'Warm cooked chicken and couscous, then serve with chopped tomato and olive oil.',
    allergens: <String>{'wheatGluten'},
    allergenSource: _starterAllergenProvenance,
    ingredients: [
      (171477, 130, 'Roasted chicken breast'),
      (169700, 180, 'Cooked couscous'),
      (170457, 115, 'Tomatoes'),
      (171413, 10, 'Olive oil')
    ]
  ),
  (
    id: 'fava-toast',
    name: 'Broad bean and feta toast',
    minutes: 10,
    method:
        'Mash drained cooked beans with olive oil; spread on toast with crumbled feta.',
    allergens: null,
    allergenSource: null,
    ingredients: [
      (170378, 145, 'Cooked broad beans, drained'),
      (173420, 50, 'Feta'),
      (172688, 90, 'Whole-wheat bread'),
      (171413, 8, 'Olive oil')
    ]
  ),
];
