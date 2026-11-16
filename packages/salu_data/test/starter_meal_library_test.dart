import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

const _chickenDefJson = '''
{
  "assetVersion": "v1",
  "meals": [
    {
      "id": "starter:chicken-broccoli-rice",
      "revision": 1,
      "titles": {"en": "Chicken and broccoli rice", "pt-PT": "Frango e brócolos com arroz"},
      "descriptions": {"en": "Chicken with broccoli and rice.", "pt-PT": "Frango com brócolos e arroz."},
      "instructions": {"en": ["Cook rice."], "pt-PT": ["Cozer o arroz."]},
      "mealLabels": ["lunch", "dinner"],
      "minutes": 25,
      "servings": "1",
      "ingredients": [
        {"sourceFoodId": "insa-bdca:11", "grams": "160", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:402", "grams": "90", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:550", "grams": "200", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:395", "grams": "10", "allergens": [], "declarationSource": "salu-starter-v1"}
      ],
      "dietaryTags": [],
      "coldSuitable": true,
      "costTier": "standard"
    }
  ]
}
''';

const _v2DefJson = '''
{
  "assetVersion": "v2",
  "meals": [
    {
      "id": "starter:chicken-broccoli-rice",
      "revision": 1,
      "titles": {"en": "Chicken and broccoli rice", "pt-PT": "Frango e brócolos com arroz"},
      "descriptions": {"en": "Chicken with broccoli and rice.", "pt-PT": "Frango com brócolos e arroz."},
      "instructions": {"en": ["Cook rice."], "pt-PT": ["Cozer o arroz."]},
      "mealLabels": ["lunch", "dinner"],
      "minutes": 25,
      "servings": "1",
      "ingredients": [
        {"sourceFoodId": "insa-bdca:11", "grams": "160", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:402", "grams": "90", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:550", "grams": "200", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:395", "grams": "10", "allergens": [], "declarationSource": "salu-starter-v1"}
      ],
      "dietaryTags": [],
      "coldSuitable": true,
      "costTier": "standard"
    },
    {
      "id": "starter:chicken-broccoli-brown-rice",
      "revision": 1,
      "titles": {"en": "Chicken and broccoli brown rice", "pt-PT": "Arroz integral com frango e brócolos"},
      "descriptions": {"en": "Brown rice with chicken and broccoli.", "pt-PT": "Arroz integral com frango e brócolos."},
      "instructions": {"en": ["Cook the raw brown rice."], "pt-PT": ["Cozer o arroz integral cru."]},
      "mealLabels": ["lunch", "dinner"],
      "minutes": 45,
      "servings": "1",
      "ingredients": [
        {"sourceFoodId": "insa-bdca:401", "grams": "90", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:11", "grams": "160", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:550", "grams": "200", "allergens": [], "declarationSource": "salu-starter-v1"},
        {"sourceFoodId": "insa-bdca:395", "grams": "10", "allergens": [], "declarationSource": "salu-starter-v1"}
      ],
      "dietaryTags": [],
      "coldSuitable": true,
      "costTier": "standard",
      "grainComposition": "wholeGrain"
    }
  ]
}
''';

Food _food(String id, String name, Map<NutrientKey, String> per100g) => Food(
      id: id,
      name: name,
      per100g: NutrientProfile({
        for (final entry in per100g.entries)
          entry.key: NutrientReported.exact(Exact.parse(entry.value)),
      }),
      source: FoodSource(
          dataset: 'insa-bdca', datasetId: id.split(':').last),
      allergens: null,
      basisUnit: FoodUnit.g,
      basisValue: '100',
      preparation: Preparation.raw,
    );

/// Synthetic INSA-like rows used only to exercise installer logic.
/// No real catalogue bytes and no fabricated production nutrition.
Map<String, Food> _syntheticFoods() => {
      'insa-bdca:11': _food('insa-bdca:11', 'Chicken', {
        NutrientKey.energyKcal: '110',
        NutrientKey.proteinG: '23',
        NutrientKey.fatG: '1.2',
      }),
      'insa-bdca:402': _food('insa-bdca:402', 'Rice', {
        NutrientKey.energyKcal: '360',
        NutrientKey.proteinG: '7',
        NutrientKey.fatG: '0.6',
      }),
      'insa-bdca:401': _food('insa-bdca:401', 'Brown rice', {
        NutrientKey.energyKcal: '350',
        NutrientKey.proteinG: '7',
        NutrientKey.fatG: '0.6',
      }),
      'insa-bdca:550': _food('insa-bdca:550', 'Broccoli', {
        NutrientKey.energyKcal: '34',
        NutrientKey.proteinG: '2.8',
        NutrientKey.fatG: '0.4',
      }),
      'insa-bdca:395': _food('insa-bdca:395', 'Oil', {
        NutrientKey.energyKcal: '884',
        NutrientKey.proteinG: '0',
        NutrientKey.fatG: '100',
      }),
    };

void main() {
  group('decodeStarterMealAsset', () {
    test('decodes a valid asset and requires bilingual content', () {
      final asset = decodeStarterMealAsset(utf8.encode(_chickenDefJson));
      expect(asset.meals, hasLength(1));
      expect(asset.meals.single.id, 'starter:chicken-broccoli-rice');
      expect(asset.meals.single.titlePtPT, 'Frango e brócolos com arroz');
      expect(asset.meals.single.instructionsPtPT, ['Cozer o arroz.']);
    });

    test('rejects invalid meal labels and cost tiers', () {
      final bad = jsonDecode(_chickenDefJson) as Map<String, Object?>;
      ((bad['meals'] as List).single as Map<String, Object?>)['mealLabels'] =
          ['brunch'];
      expect(() => decodeStarterMealAsset(utf8.encode(jsonEncode(bad))),
          throwsFormatException);
    });

    test('rejects duplicate ids', () {
      final bad = jsonDecode(_chickenDefJson) as Map<String, Object?>;
      (bad['meals'] as List).add(((bad['meals'] as List).single));
      expect(() => decodeStarterMealAsset(utf8.encode(jsonEncode(bad))),
          throwsFormatException);
    });

    test('rejects invalid grain composition metadata', () {
      final bad = jsonDecode(_chickenDefJson) as Map<String, Object?>;
      ((bad['meals'] as List).single as Map<String, Object?>)[
          'grainComposition'] = 'notAGrain';
      expect(() => decodeStarterMealAsset(utf8.encode(jsonEncode(bad))),
          throwsFormatException);
    });
  });

  group('StarterMealLibrary', () {
    late AppDatabase db;
    setUp(() {
      db = AppDatabase.memory();
    });
    tearDown(() => db.close());

    test('installs recipe + content + receipt atomically and is idempotent',
        () async {
      final asset = decodeStarterMealAsset(utf8.encode(_chickenDefJson));
      final library = StarterMealLibrary(db);
      final first = await library.ensureInstalled(
        asset: asset,
        resolveFoods: () async => _syntheticFoods(),
      );
      expect(first.status, StarterMealLibraryStatus.installed);
      expect(first.recipeCount, 1);

      final recipeDoc = await LocalWorkspace(db)
          .read('recipe', 'starter:chicken-broccoli-rice');
      expect(recipeDoc, isNotNull);
      final recipe =
          recipeFromSnapshot(recipeDoc!.data);
      expect(recipe.ingredients, hasLength(4));
      expect(recipe.ingredients.first.food.id, 'insa-bdca:11');
      expect(recipe.ingredients.first.declaredAllergens, isEmpty);
      expect(recipe.ingredients.first.allergenDeclarationSource,
          'salu-starter-v1');
      // Imported Food allergens stay unknown/null.
      expect(recipe.ingredients.first.food.allergens, isNull);

      final content = await library.readContent('starter:chicken-broccoli-rice');
      expect(content, isNotNull);
      expect(content!['schemaVersion'], 1);
      expect(content['coldSuitable'], isTrue);
      expect(content['costTier'], 'standard');
      expect(content['mealLabels'], ['lunch', 'dinner']);
      final titles = content['titles'] as Map;
      expect(titles['pt-PT'], 'Frango e brócolos com arroz');

      final receipt = await LocalWorkspace(db)
          .read('preferences', 'starter-meals-v1');
      expect(receipt, isNotNull);
      expect(receipt!.data['assetVersion'], 'v1');
      expect(receipt.data['digest'], first.digest);
      expect(receipt.data['recipeCount'], 1);
      expect((receipt.data['signatures'] as Map).containsKey(
              'starter:chicken-broccoli-rice'),
          isTrue);

      // Second launch is a no-op.
      final second = await library.ensureInstalled(
        asset: asset,
        resolveFoods: () async => _syntheticFoods(),
      );
      expect(second.status, StarterMealLibraryStatus.alreadyInstalled);
    });

    test('a new asset version adds whole-grain variants without rewriting history',
        () async {
      final library = StarterMealLibrary(db);
      final v1 = decodeStarterMealAsset(utf8.encode(_chickenDefJson));
      await library.ensureInstalled(
          asset: v1, resolveFoods: () async => _syntheticFoods());
      final workspace = LocalWorkspace(db);
      final before =
          (await workspace.read('recipe', 'starter:chicken-broccoli-rice'))!;
      final beforeSignature =
          recipeFromSnapshot(before.data).definitionSignature;

      final v2 = decodeStarterMealAsset(utf8.encode(_v2DefJson));
      final provision = await library.ensureInstalled(
          asset: v2, resolveFoods: () async => _syntheticFoods());
      expect(provision.status, StarterMealLibraryStatus.repaired);
      expect(provision.recipeCount, 2);

      final after =
          (await workspace.read('recipe', 'starter:chicken-broccoli-rice'))!;
      expect(after.revision, before.revision);
      expect(after.data, before.data);
      expect(recipeFromSnapshot(after.data).definitionSignature,
          beforeSignature);

      final brown = (await workspace.read(
          'recipe', 'starter:chicken-broccoli-brown-rice'))!;
      final brownRecipe = recipeFromSnapshot(brown.data);
      expect(brownRecipe.ingredients.first.food.id, 'insa-bdca:401');
      expect(brownRecipe.minutes, 45);
      final brownContent = await library.readContent(
          'starter:chicken-broccoli-brown-rice');
      expect(brownContent!['grainComposition'], 'wholeGrain');

      final receipt =
          (await workspace.read('preferences', 'starter-meals-v1'))!;
      expect(receipt.data['assetVersion'], 'v2');
      expect(receipt.data['recipeCount'], 2);
      expect((receipt.data['signatures'] as Map)[
          'starter:chicken-broccoli-rice'], beforeSignature);
    });

    test('missing source id aborts without partial writes', () async {
      final asset = decodeStarterMealAsset(utf8.encode(_chickenDefJson));
      final library = StarterMealLibrary(db);
      await expectLater(
        library.ensureInstalled(
          asset: asset,
          resolveFoods: () async => {'insa-bdca:11': _syntheticFoods()['insa-bdca:11']!},
        ),
        throwsA(isA<StarterMealLibraryException>().having(
            (e) => e.code, 'code', 'STARTER_MEAL_SOURCE_MISSING')),
      );
      expect(
          await LocalWorkspace(db)
              .read('recipe', 'starter:chicken-broccoli-rice'),
          isNull);
      expect(await LocalWorkspace(db)
          .read('meal-content-v1', 'starter:chicken-broccoli-rice'), isNull);
      expect(await LocalWorkspace(db)
          .read('preferences', 'starter-meals-v1'), isNull);
    });

    test('recipe allergens are union only when every ingredient is known',
        () async {
      final asset = decodeStarterMealAsset(utf8.encode(_chickenDefJson));
      final installations =
          buildStarterMealInstallations(asset.meals, _syntheticFoods());
      expect(installations.single.recipe.allergens, isEmpty);
      expect(installations.single.recipe.eligible({'milk'}, {}), isTrue);
    });

    test('snapshot round-trip preserves declarations; legacy stays clean',
        () async {
      final asset = decodeStarterMealAsset(utf8.encode(_chickenDefJson));
      final installation =
          buildStarterMealInstallations(asset.meals, _syntheticFoods())
              .single;
      final snapshot = recipeSnapshot(installation.recipe);
      final restored = recipeFromSnapshot(snapshot);
      expect(restored.definitionSignature,
          installation.recipe.definitionSignature);
      expect(restored.ingredients.first.declaredAllergens, isEmpty);

      final legacy = RecipeVersion(
        id: 'legacy',
        revision: 1,
        name: 'Legacy',
        servings: Exact.one,
        minutes: 10,
        allergens: const {},
        ingredients: [
          RecipeIngredient(_food('f1', 'F1', {NutrientKey.energyKcal: '100'}),
              Exact.parse('100'))
        ],
      );
      final legacySnapshot = recipeSnapshot(legacy);
      final legacyIng = (legacySnapshot['ingredients'] as List).single as Map;
      expect(legacyIng.containsKey('declaredAllergens'), isFalse);
      expect(
          legacyIng.containsKey('allergenDeclarationSource'), isFalse);
      expect(recipeFromSnapshot(legacySnapshot).definitionSignature,
          legacy.definitionSignature);
    });

    test('vegetarian/vegan/fish exclusion paths over declarations', () async {
      // Egg/dairy style: a declared-egg ingredient must fail an egg exclusion.
      final eggFood = _food('insa-bdca:83', 'Egg', {NutrientKey.energyKcal: '155'});
      final recipe = RecipeVersion(
        id: 'starter:test-egg',
        revision: 1,
        name: 'Egg test',
        servings: Exact.one,
        minutes: 10,
        allergens: const {'egg'},
        dietaryTags: const {'vegetarian', 'pescatarian'},
        ingredients: [
          RecipeIngredient(
            eggFood,
            Exact.parse('100'),
            declaredAllergens: const {'egg'},
            allergenDeclarationSource: 'salu-starter-v1',
          )
        ],
      );
      expect(recipe.eligible({'egg'}, {'vegetarian'}), isFalse);
      expect(recipe.eligible({'fish'}, {'vegetarian'}), isTrue);
      expect(recipe.eligible({'fish'}, {'vegan'}), isFalse);
    });
  });
}
