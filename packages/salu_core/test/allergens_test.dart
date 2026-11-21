import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

Food _food(String id, String name) => Food(
      id: id,
      name: name,
      source: FoodSource(dataset: 'fixture', datasetId: id),
      per100g: NutrientProfile({NutrientKey.energyKcal: NutrientMeasured(100)}),
    );

RecipeVersion _recipe({
  String id = 'sample',
  String name = 'Sample dish',
  int prepMinutes = 10,
  List<RecipeIngredient>? ingredients,
  Set<String>? allergens,
  String? allergenSource,
}) =>
    RecipeVersion(
      id: id,
      name: name,
      prepMinutes: prepMinutes,
      ingredients: ingredients ??
          [
            RecipeIngredient(
              food: _food('rice', 'Cooked white rice'),
              edibleGrams: 150,
              purchaseName: 'White rice',
              purchaseGrams: 150,
            ),
          ],
      allergens: allergens,
      allergenSource: allergenSource,
    );

void main() {
  test('English and Portuguese milk declarations share one identity', () {
    expect(resolveAllergen('leite'), AllergenId.milk);
    expect(resolveAllergen('dairy'), AllergenId.milk);
    final parsed = resolveStrictAllergens(['leite', 'unsupported ingredient']);
    expect(parsed.known, {AllergenId.milk});
    expect(parsed.unresolved, ['unsupported ingredient']);
  });

  test('resolves all 14 canonical EU allergens across EN and PT aliases', () {
    final cases = <AllergenId, List<String>>{
      AllergenId.milk: [
        'milk',
        'dairy',
        'leite',
        'lacticínios',
        'laticinios',
        'iogurte',
        'yogurt',
        'queijo',
        'cheese',
      ],
      AllergenId.egg: ['egg', 'eggs', 'ovo', 'ovos'],
      AllergenId.fish: ['fish', 'peixe', 'sardinha', 'atum', 'bacalhau'],
      AllergenId.crustacean: [
        'crustacean',
        'crustaceans',
        'crustáceo',
        'crustáceos',
        'camarão',
        'camaroes',
        'shrimp',
        'prawns',
      ],
      AllergenId.mollusc: [
        'mollusc',
        'molluscs',
        'mollusk',
        'molusco',
        'moluscos',
        'amêijoas',
        'mexilhão',
        'polvo',
        'lula',
      ],
      AllergenId.peanut: ['peanut', 'peanuts', 'amendoim', 'amendoins'],
      AllergenId.treeNut: [
        'treeNut',
        'tree nut',
        'tree nuts',
        'frutos de casca rija',
        'nozes',
        'amêndoa',
        'avelã',
        'caju',
        'pistácio',
        'walnut',
        'almond',
        'hazelnut',
        'cashew',
        'pecan',
        'pistachio',
        'macadamia',
      ],
      AllergenId.soy: ['soy', 'soya', 'soybean', 'soja', 'tofu', 'edamame'],
      AllergenId.wheatGluten: [
        'wheatGluten',
        'wheat',
        'gluten',
        'trigo',
        'cevada',
        'centeio',
        'aveia',
        'oats',
        'barley',
        'rye',
      ],
      AllergenId.sesame: ['sesame', 'sésamo', 'gergelim'],
      AllergenId.celery: ['celery', 'aipo'],
      AllergenId.mustard: ['mustard', 'mostarda'],
      AllergenId.lupin: ['lupin', 'tremoço', 'tremoços'],
      AllergenId.sulphite: [
        'sulphite',
        'sulfite',
        'sulphites',
        'sulfites',
        'sulfitos',
        'dióxido de enxofre',
      ],
    };

    expect(AllergenId.values, hasLength(14));
    for (final id in AllergenId.values) {
      expect(resolveAllergen(id.name), id);
      expect(resolveAllergen(id.label), id);
      for (final alias in cases[id]!) {
        expect(
          resolveAllergen(alias),
          id,
          reason: 'Expected "$alias" to resolve to $id',
        );
      }
    }
  });

  test('normalizes accents, case, punctuation and whitespace', () {
    expect(resolveAllergen('  FRUTOS-DE-CASCA   RIJA! '), AllergenId.treeNut);
    expect(resolveAllergen('DIÓXIDO DE ENXOFRE'), AllergenId.sulphite);
    expect(resolveAllergen('Amêijoas'), AllergenId.mollusc);
    expect(resolveAllergen('   '), isNull);
    expect(resolveAllergen('---'), isNull);
  });

  test('ambiguous terms stay unresolved instead of guessing a category', () {
    expect(resolveAllergen('nuts'), isNull);
    expect(resolveAllergen('nut'), isNull);
    expect(resolveAllergen('marisco'), isNull);
    expect(resolveAllergen('shellfish'), isNull);

    final parsed = resolveStrictAllergens(['nuts', 'amêndoa', 'marisco']);
    expect(parsed.known, {AllergenId.treeNut});
    expect(parsed.unresolved, ['nuts', 'marisco']);
  });

  test(
      'milk, leite, and yogurt declared recipes are excluded for dairy allergy',
      () {
    final milkDeclared = _recipe(
      id: 'milk-dish',
      allergens: const {'milk'},
      allergenSource: 'fixture-review',
    );
    final yogurtLegacy = _recipe(
      id: 'yogurt-dish',
      allergens: const {'yogurt'},
      allergenSource: 'legacy-fixture',
    );

    for (final term in ['milk', 'leite', 'dairy', 'iogurte']) {
      expect(
        recipeIneligibilityReasons(milkDeclared, strictAllergens: [term]),
        ['containsAllergen:milk'],
      );
      expect(
        recipeIneligibilityReasons(yogurtLegacy, strictAllergens: [term]),
        ['containsAllergen:milk'],
      );
      expect(
        recipeEligible(milkDeclared, strictAllergens: [term]),
        isFalse,
      );
    }
  });

  test('nuts fails closed while named tree nuts map to treeNut only', () {
    final almondDish = _recipe(
      id: 'almond-dish',
      allergens: const {'treeNut'},
      allergenSource: 'fixture-review',
    );
    final peanutFreeOnly = _recipe(
      id: 'safe-dish',
      allergens: const {},
      allergenSource: 'fixture-review',
    );

    expect(
      recipeIneligibilityReasons(almondDish, strictAllergens: ['amêndoa']),
      ['containsAllergen:treeNut'],
    );
    expect(
      recipeEligible(almondDish, strictAllergens: ['peanut']),
      isTrue,
    );
    expect(
      recipeIneligibilityReasons(peanutFreeOnly, strictAllergens: ['nuts']),
      ['unresolvedStrictAllergen:nuts'],
    );
    expect(
      recipeEligible(peanutFreeOnly, strictAllergens: ['nuts']),
      isFalse,
    );
  });

  test('unknown declarations are rejected while explicit empty set is eligible',
      () {
    final unknownRecipe = _recipe(id: 'unknown', allergens: null);
    final declaredNone = _recipe(
      id: 'declared-none',
      allergens: const {},
      allergenSource: 'USDA FDC SR Legacy listed-ingredient review',
    );

    expect(declaredNone.allergens, isEmpty);
    expect(
      declaredNone.allergenSource,
      'USDA FDC SR Legacy listed-ingredient review',
    );

    expect(
      recipeIneligibilityReasons(unknownRecipe, strictAllergens: ['milk']),
      ['unknownAllergenStatus'],
    );
    expect(recipeEligible(unknownRecipe, strictAllergens: ['milk']), isFalse);
    expect(recipeEligible(unknownRecipe), isTrue);

    expect(
      recipeIneligibilityReasons(declaredNone, strictAllergens: ['milk']),
      isEmpty,
    );
    expect(recipeEligible(declaredNone, strictAllergens: ['milk']), isTrue);
  });

  test('unresolved strict terms fail closed even on declared-empty recipes',
      () {
    final declaredNone = _recipe(
      id: 'declared-none',
      allergens: const {},
      allergenSource: 'fixture-review',
    );
    final unknownRecipe = _recipe(id: 'unknown', allergens: null);

    expect(
      recipeIneligibilityReasons(
        declaredNone,
        strictAllergens: ['unsupported ingredient'],
      ),
      ['unresolvedStrictAllergen:unsupported ingredient'],
    );
    expect(
      recipeEligible(
        declaredNone,
        strictAllergens: ['unsupported ingredient'],
      ),
      isFalse,
    );

    expect(
      recipeIneligibilityReasons(
        unknownRecipe,
        strictAllergens: ['unsupported ingredient'],
      ),
      unorderedEquals([
        'unresolvedStrictAllergen:unsupported ingredient',
        'unknownAllergenStatus',
      ]),
    );
  });

  test('ingredient exclusions reject candidates whereas dislikes only penalize',
      () {
    final riceBowl = _recipe(
      id: 'rice-bowl',
      name: 'Rice bowl',
      prepMinutes: 25,
      allergens: const {},
      allergenSource: 'fixture-review',
    );

    expect(
      recipeIneligibilityReasons(
        riceBowl,
        exclusions: ['rice'],
        cookingLimit: 15,
      ),
      unorderedEquals(['excludedIngredient:rice', 'cookingLimit']),
    );
    expect(
      rankRecipePortions(
        recipes: [riceBowl],
        exclusions: ['rice'],
      ),
      isEmpty,
    );
    expect(
      rankRecipePortions(
        recipes: [riceBowl],
        dislikes: ['rice'],
      ),
      isNotEmpty,
    );
  });
}
