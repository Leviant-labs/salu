import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  group('NutrientValue states', () {
    test('unknown carries no number', () {
      const value = NutrientUnknown();
      expect(value.isKnown, isFalse);
      expect(value.numericValue, isNull);
    });

    test('measured zero is known and different from unknown', () {
      final zero = NutrientMeasured(0);
      expect(zero.isKnown, isTrue);
      expect(zero.numericValue, 0);
      expect(zero, isNot(const NutrientUnknown()));
    });

    test('measured values reject negative and non-finite input', () {
      expect(() => NutrientMeasured(-1), throwsArgumentError);
      expect(() => NutrientMeasured(double.nan), throwsArgumentError);
      expect(
        () => NutrientEstimated(double.infinity, basis: 'photo'),
        throwsArgumentError,
      );
    });

    test('trace has no exact numeric value and is flagged', () {
      final sum = NutrientSum.zero.adding(const NutrientTrace());
      expect(sum.value, 0);
      expect(sum.isComplete, isFalse);
      expect(sum.includesTrace, isTrue);
    });

    test('JSON round-trips every state', () {
      final values = <NutrientValue>[
        const NutrientUnknown(),
        NutrientMeasured(12.5),
        const NutrientTrace(),
        NutrientEstimated(9, basis: 'photo-inference'),
      ];
      for (final value in values) {
        expect(NutrientValue.fromJson(value.toJson()), value);
      }
    });

    test('unknown JSON shapes degrade to unknown instead of throwing', () {
      expect(NutrientValue.fromJson(null), const NutrientUnknown());
      expect(NutrientValue.fromJson(const {'state': 'junk'}),
          const NutrientUnknown());
      expect(
        NutrientValue.fromJson(const {'state': 'measured'}),
        const NutrientUnknown(),
      );
    });
  });

  group('NutrientProfile', () {
    test('missing keys read as unknown, not zero', () {
      const profile = NutrientProfile.empty();
      expect(profile[NutrientKey.proteinG], const NutrientUnknown());
      expect(profile.hasAnyKnownValue, isFalse);
    });

    test('scaling keeps unknown and trace states intact', () {
      final profile = NutrientProfile({
        NutrientKey.proteinG: NutrientMeasured(10),
        NutrientKey.fiberG: const NutrientUnknown(),
        NutrientKey.sodiumMg: const NutrientTrace(),
        NutrientKey.energyKcal: NutrientEstimated(100, basis: 'recipe'),
      });

      final doubled = profile.scaled(2);

      expect(doubled[NutrientKey.proteinG], NutrientMeasured(20));
      expect(doubled[NutrientKey.fiberG], const NutrientUnknown());
      expect(doubled[NutrientKey.sodiumMg], const NutrientTrace());
      expect(
        doubled[NutrientKey.energyKcal],
        NutrientEstimated(200, basis: 'recipe'),
      );
    });

    test('combining reports partial totals as incomplete', () {
      final a = NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(100),
        NutrientKey.proteinG: NutrientMeasured(5),
      });
      final b = NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(250),
        NutrientKey.proteinG: const NutrientUnknown(),
      });

      final sums = NutrientProfile.combine([a, b]);

      expect(sums[NutrientKey.energyKcal]!.value, 350);
      expect(sums[NutrientKey.energyKcal]!.isComplete, isTrue);
      expect(sums[NutrientKey.proteinG]!.value, 5);
      expect(sums[NutrientKey.proteinG]!.isComplete, isFalse);
      expect(sums.containsKey(NutrientKey.fiberG), isFalse);
    });

    test('noData and zero are distinct: absent is not a verified zero', () {
      expect(NutrientSum.zero.isComplete, isTrue);
      expect(NutrientSum.noData.isComplete, isFalse);
      expect(NutrientSum.noData.value, 0);
      expect(
          const NutrientSum(
              value: 1,
              isComplete: true,
              includesTrace: false,
              includesEstimate: false),
          isNot(NutrientSum.zero));
    });

    test('JSON round-trip preserves values and provenance basis', () {
      final profile = NutrientProfile({
        NutrientKey.energyKcal: NutrientEstimated(120, basis: 'photo'),
        NutrientKey.fatG: NutrientMeasured(4),
        NutrientKey.sugarsG: const NutrientUnknown(),
      });

      final restored = NutrientProfile.fromJson(profile.toJson());

      expect(restored[NutrientKey.energyKcal], profile[NutrientKey.energyKcal]);
      expect(restored[NutrientKey.fatG], profile[NutrientKey.fatG]);
      expect(restored[NutrientKey.sugarsG], const NutrientUnknown());
    });

    test('unknown nutrient wires are dropped, not guessed', () {
      final restored = NutrientProfile.fromJson(const {
        'energy_kcal': {'state': 'measured', 'value': 10},
        'unobtainium_mg': {'state': 'measured', 'value': 1},
      });
      expect(restored.values.keys, [NutrientKey.energyKcal]);
    });
  });
}
