import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

Food _food(String id, {Set<String>? allergens}) => Food(
      id: id,
      name: id,
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientReported.exact(Exact.parse('100')),
      }),
      source: FoodSource(dataset: 'test', datasetId: id),
      allergens: allergens,
      basisUnit: FoodUnit.g,
      basisValue: '100',
    );

void main() {
  group('RecipeIngredient declared allergens', () {
    test('unknown status without declaration still fails exclusions', () {
      final ingredient = RecipeIngredient(
        _food('insa-bdca:11', allergens: null),
        Exact.parse('100'),
      );
      expect(ingredient.effectiveAllergens, isNull);
      final recipe = RecipeVersion(
        id: 'r1',
        revision: 1,
        name: 'R1',
        servings: Exact.one,
        minutes: 10,
        allergens: null,
        ingredients: [ingredient],
      );
      expect(recipe.eligible({'fish'}, {}), isFalse);
      expect(recipe.ineligibilityReasons({'fish'}, {}),
          contains('ALLERGEN_STATUS_UNKNOWN'));
    });

    test('declared allergens allow exclusion-aware planning', () {
      final ingredient = RecipeIngredient(
        _food('insa-bdca:11', allergens: null),
        Exact.parse('100'),
        declaredAllergens: const {},
        allergenDeclarationSource: 'salu-starter-v1',
      );
      expect(ingredient.effectiveAllergens, isEmpty);
      final recipe = RecipeVersion(
        id: 'r2',
        revision: 1,
        name: 'R2',
        servings: Exact.one,
        minutes: 10,
        allergens: const {},
        ingredients: [ingredient],
      );
      expect(recipe.eligible({'fish'}, {}), isTrue);
      expect(recipe.eligible({'milk'}, {}), isTrue);
    });

    test('declared egg ingredient cannot pass an egg exclusion', () {
      final ingredient = RecipeIngredient(
        _food('insa-bdca:83', allergens: null),
        Exact.parse('100'),
        declaredAllergens: const {'egg'},
        allergenDeclarationSource: 'salu-starter-v1',
      );
      final recipe = RecipeVersion(
        id: 'r3',
        revision: 1,
        name: 'R3',
        servings: Exact.one,
        minutes: 10,
        allergens: const {'egg'},
        ingredients: [ingredient],
      );
      expect(recipe.eligible({'egg'}, {}), isFalse);
      expect(recipe.ineligibilityReasons({'egg'}, {}),
          contains('EXCLUSION_CONFLICT'));
    });

    test('known source allergens are unioned, never erased', () {
      final ingredient = RecipeIngredient(
        _food('insa-bdca:76', allergens: {'milk'}),
        Exact.parse('100'),
        declaredAllergens: const {},
        allergenDeclarationSource: 'salu-starter-v1',
      );
      expect(ingredient.effectiveAllergens, {'milk'});
      final recipe = RecipeVersion(
        id: 'r4',
        revision: 1,
        name: 'R4',
        servings: Exact.one,
        minutes: 10,
        allergens: const {'milk'},
        ingredients: [ingredient],
      );
      expect(recipe.eligible({'milk'}, {}), isFalse);
    });

    test('both declaration fields must be provided together', () {
      expect(
        () => RecipeIngredient(
          _food('f1'),
          Exact.parse('100'),
          declaredAllergens: const {},
        ),
        throwsArgumentError,
      );
      expect(
        () => RecipeIngredient(
          _food('f1'),
          Exact.parse('100'),
          allergenDeclarationSource: 'salu-starter-v1',
        ),
        throwsArgumentError,
      );
      expect(
        () => RecipeIngredient(
          _food('f1'),
          Exact.parse('100'),
          declaredAllergens: const {},
          allergenDeclarationSource: '  ',
        ),
        throwsArgumentError,
      );
    });

    test('legacy ingredients have no declaration and stable signatures', () {
      final plain = RecipeIngredient(_food('f1'), Exact.parse('100'));
      expect(plain.declaredAllergens, isNull);
      expect(plain.allergenDeclarationSource, isNull);
      expect(plain.effectiveAllergens, isNull);
      final recipe = RecipeVersion(
        id: 'legacy',
        revision: 1,
        name: 'Legacy',
        servings: Exact.one,
        minutes: 10,
        allergens: const {},
        ingredients: [plain],
      );
      expect(recipe.definitionSignature, isNot(contains('declaredAllergens')));
    });

    test('declared ingredients change the definition signature', () {
      final plain = RecipeVersion(
        id: 'sig',
        revision: 1,
        name: 'Sig',
        servings: Exact.one,
        minutes: 10,
        allergens: const {},
        ingredients: [RecipeIngredient(_food('f1'), Exact.parse('100'))],
      );
      final declared = RecipeVersion(
        id: 'sig',
        revision: 1,
        name: 'Sig',
        servings: Exact.one,
        minutes: 10,
        allergens: const {},
        ingredients: [
          RecipeIngredient(
            _food('f1'),
            Exact.parse('100'),
            declaredAllergens: const {},
            allergenDeclarationSource: 'salu-starter-v1',
          )
        ],
      );
      expect(declared.definitionSignature, contains('declaredAllergens'));
      expect(plain.definitionSignature, isNot(declared.definitionSignature));
    });

    test('recipe aggregate never establishes ingredient status', () {
      // Aggregate says safe, ingredient itself is unknown with no declaration.
      final ingredient =
          RecipeIngredient(_food('f1', allergens: null), Exact.parse('100'));
      final recipe = RecipeVersion(
        id: 'agg',
        revision: 1,
        name: 'Agg',
        servings: Exact.one,
        minutes: 10,
        allergens: const {},
        ingredients: [ingredient],
      );
      expect(recipe.eligible({'milk'}, {}), isFalse);
    });
  });
}
