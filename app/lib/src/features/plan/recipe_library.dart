import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:salu_data/salu_data.dart' as salu_data
    show decodeRecipe, encodeRecipe;

/// App-authored recipes on top of versioned edible-food reference records.
/// Where an ingredient is cooked, the shopping amount is for the ready-cooked
/// form. The app must not infer dry amounts from cooked weights.
class RecipeLibrary {
  const RecipeLibrary(this.foods, this.documents);
  final FoodRepository foods;
  final LocalDocumentStore documents;

  static const _key = 'recipe-library';
  static const int currentVersion = 1;

  Future<List<RecipeVersion>> load() async {
    final local = await documents.read(_key);
    final user =
        local == null ? const <RecipeVersion>[] : await _readAndMigrate(local);
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

  Future<List<RecipeVersion>> _readAndMigrate(LocalRecord local) async {
    final decoded = _decodeUserRecipes(local.data);
    final rawRows = local.data['recipes'] as List? ?? const [];
    final isCurrent = isCurrentDocumentVersion(
      local.data,
      currentVersion,
      documentName: _key,
    );
    final needsItemMigration = rawRows.any(
      (raw) => raw is Map && raw['versionFormat'] != recipeFormatVersion,
    );
    if (!isCurrent || needsItemMigration) {
      final migrated = <String, Object?>{
        ...local.data,
        'version': currentVersion,
        'recipes': [
          for (final recipe in decoded) encodeRecipe(recipe),
        ],
      };
      if (!await documents.put(_key, local.revision, migrated)) {
        final latest = await documents.read(_key);
        if (latest != null) return _decodeUserRecipes(latest.data);
      }
    }
    return decoded;
  }

  List<RecipeVersion> _decodeUserRecipes(Map<String, dynamic> data) {
    isCurrentDocumentVersion(data, currentVersion, documentName: _key);
    final rawRecipes = data['recipes'];
    if (rawRecipes == null) return const [];
    if (rawRecipes is! List) {
      throw FormatException('Invalid recipes list in $_key', rawRecipes);
    }
    return [
      for (final raw in rawRecipes)
        if (raw is Map)
          decodeRecipe(Map<String, dynamic>.from(raw))
        else
          throw FormatException('Invalid recipe entry in $_key', raw),
    ];
  }

  Future<void> add(RecipeVersion recipe) async {
    final previous = await documents.read(_key);
    final existing = previous == null
        ? const <RecipeVersion>[]
        : _decodeUserRecipes(previous.data);
    if (existing
        .any((row) => row.id == recipe.id && row.version == recipe.version)) {
      throw StateError('This recipe version already exists');
    }
    if (!await documents.put(_key, previous?.revision ?? 0, {
      ...?previous?.data,
      'version': currentVersion,
      'recipes': [
        for (final row in existing) encodeRecipe(row),
        encodeRecipe(recipe),
      ],
    })) {
      throw StateError('The recipe library changed. Try again.');
    }
  }

  static Map<String, Object?> encodeRecipe(RecipeVersion recipe) =>
      salu_data.encodeRecipe(recipe);

  static RecipeVersion decodeRecipe(Map<String, dynamic> row) =>
      salu_data.decodeRecipe(row);
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
