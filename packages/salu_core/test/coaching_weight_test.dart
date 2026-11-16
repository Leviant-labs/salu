import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

CoachingWeight reading(String id, String instant, int offset, String value) =>
    CoachingWeight(
        id: id,
        revision: 1,
        stamp:
            EventStamp(instant: DateTime.parse(instant), offsetMinutes: offset),
        kilograms: Exact.parse(value));

CoachingFinding findingFor(CheckInResult result, String ruleId) =>
    result.findings.singleWhere((finding) => finding.ruleId == ruleId);

void main() {
  final window = CoachingWindow(DiaryDate(2026, 1, 1), DiaryDate(2026, 1, 7));
  test(
      'uses timestamps and recorded offsets, independent of intake declarations',
      () {
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window,
        weights: [
          reading('later', '2026-01-06T10:00:00Z', 0, '70.25'),
          reading('outside', '2026-01-08T00:00:00Z', 0, '10'),
          reading('first', '2025-12-31T23:30:00Z', 60, '71.5'),
        ]);
    expect(result.weightObservation!.changeKg, Exact.parse('-1.25'));
    expect(result.weightObservation!.count, 2);
    expect(result.weightObservation!.firstDate, '2026-01-01');
    expect(result.weightObservation!.lastDate, '2026-01-06');
    expect(result.weightInputRevisions, {'later': 1, 'first': 1});

    final finding = findingFor(result, 'weight-readings');
    expect(finding.action, CoachingAction.hold);
    expect(finding.window.bounded, isTrue);
    expect(finding.window.dates, window.dates);
    expect(finding.window.start, window.start);
    expect(finding.window.end, window.end);
    expect(finding.evaluatedDates, ['2026-01-01', '2026-01-06']);
    expect(finding.inputRevisions,
        {'weight:first': 1, 'weight:later': 1});
    expect(finding.caveats, contains(CoachingCaveat.spotWeightsNotTrend));
    expect(finding.caveats, contains(CoachingCaveat.backdatedPreserved));
    expect(finding.message, contains('71.5 kg'));
    expect(finding.message, contains('-1.25 kg'));
    expect(finding.message, contains('No trend or plateau is computed'));
    expect(finding.message, isNot(contains('{')));
  });
  test('single reading and ambiguous endpoint cannot establish a comparison',
      () {
    const service = CoachingService();
    final item = reading('a', '2026-01-01T09:00:00Z', 0, '70');
    final single = service.checkIn(const SafetyProfile(), [],
        window: window, weights: [item]);
    expect(single.weightObservation, isNull);
    expect(single.findings.any((f) => f.ruleId == 'weight-readings'), isFalse);

    final ambiguous = service.checkIn(const SafetyProfile(), [], window: window,
        weights: [
          item,
          reading('b', '2026-01-01T09:00:00Z', 0, '71'),
          reading('c', '2026-01-03T09:00:00Z', 0, '72'),
        ]);
    expect(ambiguous.weightObservation, isNull);
    expect(
        ambiguous.findings.any((f) => f.ruleId == 'weight-readings'), isFalse);

    expect(
        () => service.checkIn(const SafetyProfile(), [],
            window: window, weights: [item, item]),
        throwsArgumentError);
  });

  test('equal endpoints stay observations rather than a claimed trend', () {
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window,
        weights: [
          reading('a', '2026-01-01T09:00:00Z', 0, '70'),
          reading('b', '2026-01-05T09:00:00Z', 0, '70'),
        ]);
    expect(result.weightObservation!.changeKg, Exact.zero);
    final finding = findingFor(result, 'weight-readings');
    expect(finding.action, CoachingAction.hold);
    expect(finding.message, contains('0.0 kg endpoint difference'));
  });

  test('offset diary dates are reported as recorded, without a span claim', () {
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window,
        weights: [
          reading('east', '2026-01-06T23:30:00Z', 120, '70'),
          reading('west', '2026-01-07T00:30:00Z', -600, '71'),
        ]);
    expect(result.weightObservation!.firstDate, '2026-01-07');
    expect(result.weightObservation!.lastDate, '2026-01-06');
    final finding = findingFor(result, 'weight-readings');
    expect(finding.message, contains('first on 2026-01-07'));
    expect(finding.message, contains('last on 2026-01-06'));
    expect(finding.message, isNot(contains('day(s)')));
  });
}
