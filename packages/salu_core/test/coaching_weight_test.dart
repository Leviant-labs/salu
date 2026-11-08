import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

CoachingWeight reading(String id, String instant, int offset, String value) =>
    CoachingWeight(
        id: id,
        revision: 1,
        stamp:
            EventStamp(instant: DateTime.parse(instant), offsetMinutes: offset),
        kilograms: Exact.parse(value));

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
    expect(result.weightInputRevisions, {'later': 1, 'first': 1});
    expect(result.findings.single.action, CoachingAction.improveData);
    expect(result.adaptationStatus, 'disabled');
  });
  test('single reading and ambiguous endpoint cannot establish a comparison',
      () {
    final item = reading('a', '2026-01-01T09:00:00Z', 0, '70');
    expect(
        const CoachingService()
            .checkIn(const SafetyProfile(), [], window: window, weights: [item])
            .weightObservation,
        isNull);
    final result = const CoachingService().checkIn(const SafetyProfile(), [],
        window: window,
        weights: [
          item,
          reading('b', '2026-01-01T09:00:00Z', 0, '71'),
          reading('c', '2026-01-03T09:00:00Z', 0, '72'),
        ]);
    expect(result.weightObservation, isNull);
    expect(
        () => const CoachingService().checkIn(const SafetyProfile(), [],
            window: window, weights: [item, item]),
        throwsArgumentError);
  });
}
