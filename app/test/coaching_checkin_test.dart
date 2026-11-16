import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/today/diary_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as helpers;
import 'plan_test_support.dart';

Map<String, Object?> _metadata(DiaryDate start, int days) => {
      'schedule': {
        'startDate': start.toIso(),
        'days': days,
        'label': 'dinner',
        'portions': [Exact.one.toJson()]
      },
      'constraints': {
        'maximumMinutes': null,
        'maximumRepeats': null,
        'energyMinimum': null,
        'energyMaximum': null
      },
      'constraintRevision': 1,
      'relaxations': <Object?>[],
      'acceptedRelaxations': <Object?>[]
    };

void main() {
  testWidgets(
      'plan evidence is bounded to the check-in window and uses the stored revision',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final now = DateTime.now();
    final today = DiaryDate.assign(
        EventStamp(instant: now, offsetMinutes: now.timeZoneOffset.inMinutes));
    final start = today.addDays(-7);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    final meals = [
      for (var i = 0; i < 8; i++)
        PlannedMeal(
            MealSlot('dinner:$i', start.addDays(i).toIso(), 'dinner'),
            recipe,
            Exact.one)
    ];
    final seeded = await seedPlan(db,
        meals: meals, startDate: start.toIso(), days: 8);
    // A later revision must be surfaced as the actual stored evidence, not a
    // cached or invented number.
    await PlanService(db, const SystemClock(), RandomIdGenerator()).save(
        requestId: 'test:plan-revision-2',
        expectedPlanRevision: seeded.revision,
        meals: seeded.meals,
        metadata: _metadata(start, 8));

    await helpers.pump(tester, db, const DiaryScreen());
    await tester.ensureVisible(find.text('Weekly check-in'));
    await tester.tap(find.text('Weekly check-in'));
    await tester.pumpAndSettle();

    await helpers.scrollCheckInTo(
        tester, find.textContaining('The plan schedules 7 meal slot(s)'));
    expect(find.textContaining('The plan schedules 7 meal slot(s)'),
        findsOneWidget);
    await helpers.scrollCheckInTo(
        tester, find.textContaining('Plan evidence: 7 scheduled slot(s)'));
    // The first slot is the day before the bounded window and must not count.
    expect(find.textContaining('Plan evidence: 7 scheduled slot(s)'),
        findsOneWidget);
    expect(find.textContaining('revision(s) 2'), findsOneWidget);
    expect(find.textContaining('A plan is never treated as intake'),
        findsOneWidget);
    await helpers.scrollCheckInTo(tester, find.textContaining('Plan adherence'));
    expect(find.textContaining('Plan adherence'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plan slots outside the check-in window are not invented',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = planRecipe(id: 'soup', name: 'Soup');
    await seedRecipe(db, recipe);
    final start = DiaryDate(2020, 1, 1);
    await seedPlan(db, meals: [
      PlannedMeal(
          MealSlot('dinner:0', start.toIso(), 'dinner'), recipe, Exact.one),
      PlannedMeal(MealSlot('dinner:1', start.addDays(1).toIso(), 'dinner'),
          recipe, Exact.one)
    ], startDate: start.toIso(), days: 2);

    await helpers.pump(tester, db, const DiaryScreen());
    await tester.ensureVisible(find.text('Weekly check-in'));
    await tester.tap(find.text('Weekly check-in'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Plan evidence:'), findsNothing);
    expect(find.textContaining('The plan schedules'), findsNothing);
    await helpers.scrollCheckInTo(
        tester, find.textContaining('Not computed in this release'));
    expect(find.textContaining('Not computed in this release'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'support mode never exposes weight findings, values or endpoint differences',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final now = DateTime.now();
    final workspace = LocalWorkspace(db);
    for (final item in [
      (
        id: 'early-weight',
        at: now.subtract(const Duration(days: 1)),
        kg: '123.4'
      ),
      (id: 'late-weight', at: now, kg: '121.2')
    ]) {
      await workspace.put(
          requestId: item.id,
          collection: 'weight',
          id: item.id,
          expectedRevision: 0,
          data: {
            'value': Exact.parse(item.kg).toJson(),
            'unit': 'kg',
            'time': item.at.toUtc().toIso8601String(),
            'offsetMinutes': item.at.timeZoneOffset.inMinutes
          });
    }
    await helpers.pump(tester, db, const DiaryScreen(), support: true);
    await tester.ensureVisible(find.text('Weekly check-in'));
    await tester.tap(find.text('Weekly check-in'));
    await tester.pumpAndSettle();

    expect(find.textContaining('123.4'), findsNothing);
    expect(find.textContaining('121.2'), findsNothing);
    expect(find.textContaining('endpoint difference'), findsNothing);
    expect(find.textContaining('No trend or plateau'), findsNothing);
    expect(find.textContaining('weight-readings'), findsNothing);
    expect(find.text('Weekly check-in'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pt-PT check-in localizes findings, evidence, caveats and gaps',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await helpers.pump(tester, db, const DiaryScreen(), pt: true);
    await tester.ensureVisible(find.text('Balanço semanal'));
    await tester.tap(find.text('Balanço semanal'));
    await tester.pumpAndSettle();

    expect(find.textContaining('O registo está incompleto'), findsOneWidget);
    expect(find.textContaining('Dias em falta nunca contam como zero.'),
        findsOneWidget);
    expect(find.textContaining('Evidência:'), findsWidgets);
    expect(find.text('Ressalvas'), findsWidgets);
    expect(find.textContaining('Plan adherence'), findsNothing);
    expect(find.textContaining('Not computed in this release'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
