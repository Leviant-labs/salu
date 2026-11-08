import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

void main() {
  const sodium = NutrientIdentity('sodium', 'mg', 'sodium');
  const freeSugars = NutrientIdentity('sugar', 'g', 'free_sugars');

  RecordedSummary summary(
          {String? amount = '2200',
          int known = 1,
          int estimated = 0,
          List<String> missing = const ['unknown'],
          DiaryCompleteness diary = DiaryCompleteness.partial,
          NutrientIdentity nutrient = sodium}) =>
      RecordedSummary(
        nutrient: nutrient,
        recordedSum: amount == null ? null : Exact.parse(amount),
        known: known,
        missing: missing,
        estimated: estimated,
        diaryCompleteness: diary,
      );
  ReferencePolicy policy(
          {ReferenceKind kind = ReferenceKind.maximumGuidance,
          String? lower,
          String? upper = '2000',
          bool approved = true,
          bool populationMatches = true}) =>
      ReferencePolicy(
        id: 'test',
        nutrient: sodium,
        kind: kind,
        source: 'test',
        edition: '1',
        temporalBasis: 'day',
        approved: approved,
        populationMatches: populationMatches,
        lower: lower == null ? null : Exact.parse(lower),
        upper: upper == null ? null : Exact.parse(upper),
      );
  const service = ReferenceComparisonService();

  test('partial reported items can exceed maximum without claiming a total',
      () {
    expect(service.compare(summary(), policy()),
        ComparisonStatus.recordedItemsAlreadyExceedGuidance);
    expect(service.compare(summary(amount: '2000'), policy()),
        ComparisonStatus.insufficientData);
    expect(service.compare(summary(estimated: 1), policy()),
        ComparisonStatus.insufficientData);
    expect(service.compare(summary(amount: null, known: 0), policy()),
        ComparisonStatus.insufficientData);
  });
  test('partial excess never bypasses reference applicability', () {
    expect(service.compare(summary(), policy(approved: false)),
        ComparisonStatus.referenceNotApplicable);
    expect(service.compare(summary(), policy(populationMatches: false)),
        ComparisonStatus.referenceNotApplicable);
    expect(service.compare(summary(nutrient: freeSugars), policy()),
        ComparisonStatus.referenceNotApplicable);
    expect(service.compare(summary(), policy(), temporalBasis: 'week'),
        ComparisonStatus.referenceNotApplicable);
  });
  test('malformed ranges are not recorded as out of range', () {
    final complete =
        summary(missing: [], diary: DiaryCompleteness.userDeclaredComplete);
    expect(service.compare(complete, policy(kind: ReferenceKind.riRange)),
        ComparisonStatus.referenceNotApplicable);
    expect(
        service.compare(complete,
            policy(kind: ReferenceKind.riRange, lower: '3000', upper: '2000')),
        ComparisonStatus.referenceNotApplicable);
    expect(
        service.compare(complete,
            policy(kind: ReferenceKind.riRange, lower: '-1', upper: '2000')),
        ComparisonStatus.referenceNotApplicable);
    expect(
        service.compare(complete,
            policy(kind: ReferenceKind.riRange, lower: '2000', upper: '3000')),
        ComparisonStatus.recordedWithinRange);
  });
  test('safe intake is not treated as a maximum', () {
    expect(
        service.compare(summary(), policy(kind: ReferenceKind.safeIntakeLevel)),
        ComparisonStatus.referenceNotApplicable);
  });
}
