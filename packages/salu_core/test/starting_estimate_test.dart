import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  NutritionProfile profile({AdultGoal goal = AdultGoal.loseWeight, Exact? pal}) =>
      NutritionProfile(goal: goal, ageYears: 30, heightCm: Exact.parse('180'),
          weightKg: Exact.parse('80'), equationConstant: 5, activityPal: pal);
  test('starting estimate uses explicit inputs and exact macro arithmetic', () {
    final target = const TargetService().generateAutomaticTarget(
      profile: profile(pal: Exact.parse('1.6')), id: 'current', revision: 1,
      effectiveDate: '2026-11-13');
    expect(target.origin, TargetOrigin.calculatedEstimate);
    expect(target.energyKcal, Exact.parse('2563.2'));
    expect(target.proteinG, Exact.parse('96.12'));
    expect(target.fatG, Exact.parse('85.44'));
    expect(target.carbohydrateG, Exact.parse('339.94'));
    expect(target.formulaVersion, 'mifflin-st-jeor-v1');
    final maintain = const TargetService().generateAutomaticTarget(
      profile: profile(goal: AdultGoal.maintainWeight, pal: Exact.parse('1.6')),
      id: 'current', revision: 2, effectiveDate: '2026-11-13');
    expect(maintain.energyKcal, Exact.parse('2848'));
    expect(DeclaredTarget.fromJson(target.toJson()).energyKcal, target.energyKcal);
  });
  test('missing activity is identified rather than guessed', () {
    expect(() => const TargetService().generateAutomaticTarget(
      profile: profile(), id: 'current', revision: 1, effectiveDate: '2026-11-13'),
      throwsA(isA<TargetEstimateException>()
          .having((e) => e.code, 'code', 'TARGET_INPUT_REQUIRED')
          .having((e) => e.missingInputs, 'fields', ['activityPal'])));
  });
  test('impossible equations do not create a target', () {
    final invalid = NutritionProfile(goal: AdultGoal.loseWeight, ageYears: 200,
      heightCm: Exact.parse('50'), weightKg: Exact.parse('1'),
      equationConstant: -161, activityPal: Exact.parse('1.4'));
    expect(() => const TargetService().generateAutomaticTarget(
      profile: invalid, id: 'current', revision: 1, effectiveDate: '2026-11-13'),
      throwsA(isA<TargetEstimateException>().having((e) => e.code, 'code', 'TARGET_CONFLICT')));
  });
}
