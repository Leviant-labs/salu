import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  test('implausible energy becomes unknown without losing safe protein', () {
    final result = screenNutrition(
      NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(1000000, basis: 'fixture'),
        NutrientKey.proteinG: NutrientEstimated(3, basis: 'fixture'),
      }),
      portion: MealPortion(100, MealUnit.grams),
    );
    expect(result.profile[NutrientKey.energyKcal].isKnown, isFalse);
    expect(result.profile[NutrientKey.proteinG].numericValue, 3);
    expect(result.issues.any((i) => i.code == 'absoluteLimit'), isTrue);
  });

  test('exports screening version 1 and round-trips NutritionIssue JSON', () {
    expect(nutritionScreeningVersion, 1);
    const withNutrient = NutritionIssue(
      code: 'absoluteLimit',
      nutrient: NutrientKey.energyKcal,
      blocksAutomaticUse: true,
    );
    const withoutNutrient = NutritionIssue(
      code: 'macroEnergyMismatch',
      blocksAutomaticUse: false,
    );

    expect(NutritionIssue.fromJson(withNutrient.toJson()), withNutrient);
    expect(NutritionIssue.fromJson(withoutNutrient.toJson()), withoutNutrient);
    expect(withNutrient.hashCode,
        NutritionIssue.fromJson(withNutrient.toJson()).hashCode);
    expect(withNutrient.toString(), contains('absoluteLimit'));
    expect(
      () => NutritionIssue.fromJson({'code': '', 'blocksAutomaticUse': true}),
      throwsFormatException,
    );
  });

  group('absolute per-item thresholds', () {
    test('energy boundary at 10000 vs 10000.1 kcal', () {
      final atLimit = screenNutrition(NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(10000, basis: 'fixture'),
      }));
      expect(atLimit.profile[NutrientKey.energyKcal].numericValue, 10000);
      expect(atLimit.issues, isEmpty);

      final overLimit = screenNutrition(NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(10000.1, basis: 'fixture'),
      }));
      expect(
          overLimit.profile[NutrientKey.energyKcal], const NutrientUnknown());
      expect(overLimit.issues, [
        const NutritionIssue(
          code: 'absoluteLimit',
          nutrient: NutrientKey.energyKcal,
          blocksAutomaticUse: true,
        ),
      ]);
    });

    test('gram nutrient boundaries at 1000 vs 1000.1 g', () {
      const gramKeys = [
        NutrientKey.proteinG,
        NutrientKey.fatG,
        NutrientKey.saturatedFatG,
        NutrientKey.carbohydrateG,
        NutrientKey.fiberG,
        NutrientKey.sugarsG,
      ];
      for (final key in gramKeys) {
        final atLimit = screenNutrition(NutrientProfile({
          key: NutrientEstimated(1000, basis: 'fixture'),
        }));
        expect(atLimit.profile[key].numericValue, 1000, reason: key.wire);
        expect(atLimit.issues, isEmpty, reason: key.wire);

        final overLimit = screenNutrition(NutrientProfile({
          key: NutrientEstimated(1000.1, basis: 'fixture'),
        }));
        expect(overLimit.profile[key], const NutrientUnknown(),
            reason: key.wire);
        expect(
            overLimit.issues,
            [
              NutritionIssue(
                code: 'absoluteLimit',
                nutrient: key,
                blocksAutomaticUse: true,
              ),
            ],
            reason: key.wire);
      }
    });

    test('sodium boundary at 100000 vs 100000.1 mg and finite overflow', () {
      final atLimit = screenNutrition(NutrientProfile({
        NutrientKey.sodiumMg: NutrientEstimated(100000, basis: 'fixture'),
      }));
      expect(atLimit.profile[NutrientKey.sodiumMg].numericValue, 100000);
      expect(atLimit.issues, isEmpty);

      final overLimit = screenNutrition(NutrientProfile({
        NutrientKey.sodiumMg: NutrientEstimated(100000.1, basis: 'fixture'),
      }));
      expect(overLimit.profile[NutrientKey.sodiumMg], const NutrientUnknown());
      expect(overLimit.issues.single.code, 'absoluteLimit');

      final overflow = screenNutrition(NutrientProfile({
        NutrientKey.energyKcal:
            NutrientEstimated(double.maxFinite, basis: 'fixture'),
      }));
      expect(overflow.profile[NutrientKey.energyKcal], const NutrientUnknown());
      expect(overflow.issues.single.code, 'absoluteLimit');
    });
  });

  group('gram-portion mass checks', () {
    test('energy density boundary at 12 kcal/g', () {
      final portion = MealPortion(100, MealUnit.grams);
      final atLimit = screenNutrition(
        NutrientProfile({
          NutrientKey.energyKcal: NutrientEstimated(1200, basis: 'fixture'),
        }),
        portion: portion,
      );
      expect(atLimit.profile[NutrientKey.energyKcal].numericValue, 1200);
      expect(atLimit.issues, isEmpty);

      final overLimit = screenNutrition(
        NutrientProfile({
          NutrientKey.energyKcal: NutrientEstimated(1200.1, basis: 'fixture'),
        }),
        portion: portion,
      );
      expect(
          overLimit.profile[NutrientKey.energyKcal], const NutrientUnknown());
      expect(overLimit.issues, [
        const NutritionIssue(
          code: 'massInconsistent',
          nutrient: NutrientKey.energyKcal,
          blocksAutomaticUse: true,
        ),
      ]);
    });

    test('individual gram nutrient boundary at 1.1x portion mass', () {
      final portion = MealPortion(100, MealUnit.grams);
      final atLimit = screenNutrition(
        NutrientProfile({
          NutrientKey.proteinG: NutrientEstimated(110, basis: 'fixture'),
        }),
        portion: portion,
      );
      expect(atLimit.profile[NutrientKey.proteinG].numericValue, 110);
      expect(atLimit.issues, isEmpty);

      final overLimit = screenNutrition(
        NutrientProfile({
          NutrientKey.proteinG: NutrientEstimated(110.1, basis: 'fixture'),
          NutrientKey.carbohydrateG: NutrientEstimated(50, basis: 'fixture'),
        }),
        portion: portion,
      );
      expect(overLimit.profile[NutrientKey.proteinG], const NutrientUnknown());
      expect(overLimit.profile[NutrientKey.carbohydrateG].numericValue, 50);
      expect(overLimit.issues, [
        const NutritionIssue(
          code: 'massInconsistent',
          nutrient: NutrientKey.proteinG,
          blocksAutomaticUse: true,
        ),
      ]);
    });

    test('skips mass checks for ml, pieces, servings, and null portion', () {
      for (final portion in [
        MealPortion(10, MealUnit.millilitres),
        MealPortion(1, MealUnit.pieces),
        MealPortion(1, MealUnit.servings),
        null,
      ]) {
        final result = screenNutrition(
          NutrientProfile({
            NutrientKey.energyKcal: NutrientEstimated(500, basis: 'fixture'),
            NutrientKey.fatG: NutrientEstimated(50, basis: 'fixture'),
          }),
          portion: portion,
        );
        expect(result.profile[NutrientKey.energyKcal].numericValue, 500,
            reason: portion?.unit.name);
        expect(result.profile[NutrientKey.fatG].numericValue, 50,
            reason: portion?.unit.name);
        expect(
          result.issues.where((i) => i.code == 'massInconsistent'),
          isEmpty,
          reason: portion?.unit.name,
        );
      }
    });
  });

  group('epistemic states and raw input screening', () {
    test('preserves zero, unknown, and trace untouched', () {
      final result = screenNutrition(
        NutrientProfile({
          NutrientKey.energyKcal: NutrientReported(0),
          NutrientKey.proteinG: const NutrientUnknown(),
          NutrientKey.fatG: const NutrientTrace(),
        }),
        portion: MealPortion(100, MealUnit.grams),
      );
      expect(result.profile[NutrientKey.energyKcal], NutrientReported(0));
      expect(result.profile[NutrientKey.proteinG], const NutrientUnknown());
      expect(result.profile[NutrientKey.fatG], const NutrientTrace());
      expect(result.issues, isEmpty);
    });

    test('blocked field becomes unknown and marks combined totals incomplete',
        () {
      final safe = NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(200, basis: 'fixture'),
      });
      final blocked = screenNutrition(
        NutrientProfile({
          NutrientKey.energyKcal: NutrientEstimated(50000, basis: 'fixture'),
        }),
      ).profile;
      expect(blocked[NutrientKey.energyKcal], const NutrientUnknown());

      final sum =
          NutrientProfile.combine([safe, blocked])[NutrientKey.energyKcal]!;
      expect(sum.value, 200);
      expect(sum.isComplete, isFalse);
    });

    test('screenRawNutrition catches negative, NaN, Infinity, and bad types',
        () {
      final result = screenRawNutrition(
        {
          NutrientKey.energyKcal: -50,
          NutrientKey.proteinG: double.nan,
          NutrientKey.fatG: double.infinity,
          NutrientKey.saturatedFatG: double.negativeInfinity,
          NutrientKey.carbohydrateG: '40',
          NutrientKey.fiberG: null,
          NutrientKey.sugarsG: 0,
          NutrientKey.sodiumMg: 120,
        },
        build: (v) => NutrientEstimated(v, basis: 'raw'),
        portion: MealPortion(100, MealUnit.grams),
      );

      expect(result.profile[NutrientKey.energyKcal], const NutrientUnknown());
      expect(result.profile[NutrientKey.proteinG], const NutrientUnknown());
      expect(result.profile[NutrientKey.fatG], const NutrientUnknown());
      expect(
          result.profile[NutrientKey.saturatedFatG], const NutrientUnknown());
      expect(
          result.profile[NutrientKey.carbohydrateG], const NutrientUnknown());
      expect(result.profile[NutrientKey.fiberG], const NutrientUnknown());
      expect(result.profile[NutrientKey.sugarsG],
          NutrientEstimated(0, basis: 'raw'));
      expect(result.profile[NutrientKey.sodiumMg],
          NutrientEstimated(120, basis: 'raw'));
      expect(
        result.issues.map((i) => (i.code, i.nutrient, i.blocksAutomaticUse)),
        [
          ('invalidValue', NutrientKey.energyKcal, true),
          ('invalidValue', NutrientKey.proteinG, true),
          ('invalidValue', NutrientKey.fatG, true),
          ('invalidValue', NutrientKey.saturatedFatG, true),
          ('invalidValue', NutrientKey.carbohydrateG, true),
        ],
      );
    });
  });

  group('macro-energy warning and unit ambiguity', () {
    test('warns on macro-energy mismatch without rewriting energy or macros',
        () {
      // Simulates e.g. kJ entered into kcal field: 800 vs derived 102 kcal.
      final result = screenNutrition(
        NutrientProfile({
          NutrientKey.energyKcal: NutrientEstimated(800, basis: 'fixture'),
          NutrientKey.proteinG: NutrientEstimated(5, basis: 'fixture'),
          NutrientKey.carbohydrateG: NutrientEstimated(10, basis: 'fixture'),
          NutrientKey.fatG: NutrientEstimated(4, basis: 'fixture'),
          NutrientKey.sodiumMg: NutrientEstimated(5000, basis: 'fixture'),
        }),
      );
      expect(result.profile[NutrientKey.energyKcal].numericValue, 800);
      expect(result.profile[NutrientKey.proteinG].numericValue, 5);
      expect(result.profile[NutrientKey.sodiumMg].numericValue, 5000);
      expect(result.issues, [
        const NutritionIssue(
          code: 'macroEnergyMismatch',
          nutrient: NutrientKey.energyKcal,
          blocksAutomaticUse: false,
        ),
      ]);
    });

    test('includes fibre at 2 kcal/g when checking macro-energy agreement', () {
      // 4*0 + 4*0 + 9*0 + 2*60 = 120 kcal -> agrees with 120 kcal!
      final agreesWithFibre = screenNutrition(NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(120, basis: 'fixture'),
        NutrientKey.proteinG: NutrientEstimated(0, basis: 'fixture'),
        NutrientKey.carbohydrateG: NutrientEstimated(0, basis: 'fixture'),
        NutrientKey.fatG: NutrientEstimated(0, basis: 'fixture'),
        NutrientKey.fiberG: NutrientEstimated(60, basis: 'fixture'),
      }));
      expect(agreesWithFibre.issues, isEmpty);

      // Threshold boundary: max(100, 0.30 * 100) = 100 -> 100 does not warn,
      // 101 warns.
      final atBoundary = screenNutrition(NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(100, basis: 'fixture'),
        NutrientKey.proteinG: NutrientEstimated(0, basis: 'fixture'),
        NutrientKey.carbohydrateG: NutrientEstimated(0, basis: 'fixture'),
        NutrientKey.fatG: NutrientEstimated(0, basis: 'fixture'),
      }));
      expect(atBoundary.issues, isEmpty);

      final overBoundary = screenNutrition(NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(101, basis: 'fixture'),
        NutrientKey.proteinG: NutrientEstimated(0, basis: 'fixture'),
        NutrientKey.carbohydrateG: NutrientEstimated(0, basis: 'fixture'),
        NutrientKey.fatG: NutrientEstimated(0, basis: 'fixture'),
      }));
      expect(overBoundary.issues.single.code, 'macroEnergyMismatch');
      expect(overBoundary.issues.single.blocksAutomaticUse, isFalse);
      expect(overBoundary.profile[NutrientKey.energyKcal].numericValue, 101);
    });

    test('skips macro-energy check when energy or any macro is unknown', () {
      final missingCarb = screenNutrition(NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(900, basis: 'fixture'),
        NutrientKey.proteinG: NutrientEstimated(5, basis: 'fixture'),
        NutrientKey.fatG: NutrientEstimated(4, basis: 'fixture'),
      }));
      expect(missingCarb.issues, isEmpty);
    });
  });

  test('PhotoMealItem holds immutable reviewIssues and retains in copyWith',
      () {
    const issue = NutritionIssue(
      code: 'macroEnergyMismatch',
      nutrient: NutrientKey.energyKcal,
      blocksAutomaticUse: false,
    );
    final item = PhotoMealItem(
      name: 'Soup',
      reviewIssues: [issue],
    );
    expect(item.reviewIssues, [issue]);
    expect(() => item.reviewIssues.add(issue), throwsUnsupportedError);
    expect(item.copyWith(name: 'Broth').reviewIssues, [issue]);
    expect(item.copyWith(reviewIssues: const []).reviewIssues, isEmpty);
  });
}
