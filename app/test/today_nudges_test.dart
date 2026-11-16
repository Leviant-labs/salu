import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/today/diary_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/ui_support.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

DiaryDate _today() {
  final now = DateTime.now();
  return DiaryDate.assign(EventStamp(
      instant: now, offsetMinutes: now.timeZoneOffset.inMinutes));
}

Future<void> _pump(
  WidgetTester tester,
  AppDatabase db,
  DiaryDate date, {
  Map<String, Object?> settings = const {},
}) async {
  await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        todayDiaryDateProvider.overrideWithValue(date),
        initialSettingsProvider.overrideWithValue({
          'language': 'en',
          'onboarded': true,
          ...settings,
        })
      ],
      child: const MaterialApp(home: Scaffold(body: DiaryScreen()))));
  await tester.pumpAndSettle();
}

Future<void> _seedEntry(AppDatabase db, DiaryDate date) async {
  final now = DateTime.now();
  await DriftEntryRepository(db).append(LoggedEntry(
      id: 'nudge-entry',
      requestId: 'nudge-request',
      diaryDate: date,
      stamp: EventStamp(
          instant: now.toUtc(), offsetMinutes: now.timeZoneOffset.inMinutes),
      channel: EntryChannel.manual,
      recordedAt: now.toUtc(),
      items: [
        LoggedItem(
            name: 'Test meal',
            grams: 100,
            nutrients: NutrientProfile({
              NutrientKey.energyKcal: NutrientMeasured(321),
              NutrientKey.proteinG: NutrientMeasured(12),
              NutrientKey.carbohydrateG: NutrientMeasured(45),
              NutrientKey.fatG: NutrientMeasured(8),
              NutrientKey.fiberG: NutrientMeasured(3),
            }))
      ]));
}

Future<void> _seedWeights(AppDatabase db) async {
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
}

Future<void> _openCheckIn(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Weekly check-in'));
  await tester.tap(find.text('Weekly check-in'));
  await tester.pumpAndSettle();
}

Future<void> _closeCheckIn(WidgetTester tester) async {
  await tester.tap(find.text('Close'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('default preferences keep calorie and weight surfaces visible',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final date = _today();
    await _seedEntry(db, date);
    await _seedWeights(db);

    await _pump(tester, db, date);

    expect(find.text('Energy'), findsOneWidget);
    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Carbohydrate'), findsOneWidget);
    expect(find.text('Fat'), findsOneWidget);
    expect(find.text('Fibre'), findsOneWidget);
    expect(find.text('Test meal'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Record weight'), 200);
    expect(find.text('Record weight'), findsOneWidget);

    await _openCheckIn(tester);
    await tester.scrollUntilVisible(find.textContaining('123.4'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('123.4'), findsOneWidget);
    expect(find.textContaining('121.2'), findsOneWidget);
    expect(find.textContaining('endpoint difference'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('Weight trend'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Weight trend'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calorie preference hides only the energy row', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final date = _today();
    await _seedEntry(db, date);
    await _seedWeights(db);

    await _pump(tester, db, date,
        settings: const {'hideCalorieNudges': true});

    expect(find.text('Energy'), findsNothing);
    expect(find.text('Recorded nutrition'), findsOneWidget);
    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Carbohydrate'), findsOneWidget);
    expect(find.text('Fat'), findsOneWidget);
    expect(find.text('Fibre'), findsOneWidget);
    expect(find.text('Record weight'), findsOneWidget);
    expect(find.text('Test meal'), findsOneWidget);

    // Calorie visibility never suppresses weight or rewrites the diary.
    await _openCheckIn(tester);
    await tester.scrollUntilVisible(find.textContaining('123.4'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('123.4'), findsOneWidget);
    expect(find.textContaining('121.2'), findsOneWidget);
    await _closeCheckIn(tester);
    expect(await DriftEntryRepository(db).entriesFor(date), hasLength(1));
    expect(await LocalWorkspace(db).list('weight'), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('weight preference hides weight surfaces and coaching leaks',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final date = _today();
    await _seedEntry(db, date);
    await _seedWeights(db);

    await _pump(tester, db, date,
        settings: const {'hideWeightNudges': true});

    expect(find.text('Energy'), findsOneWidget);
    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Record weight'), findsNothing);
    expect(find.text('Record water'), findsOneWidget);

    await _openCheckIn(tester);
    expect(find.textContaining('123.4'), findsNothing);
    expect(find.textContaining('121.2'), findsNothing);
    expect(find.textContaining('endpoint difference'), findsNothing);
    expect(find.textContaining('No trend or plateau'), findsNothing);
    expect(find.textContaining('weight reading'), findsNothing);
    expect(find.textContaining('weight-readings'), findsNothing);
    expect(find.textContaining('Scale readings'), findsNothing);
    expect(find.textContaining('Weight trend'), findsNothing);
    expect(find.textContaining('Possible plateau'), findsNothing);
    expect(find.textContaining('Recording is incomplete'), findsOneWidget);
    expect(find.text('Weekly check-in'), findsWidgets);
    await _closeCheckIn(tester);

    // Hiding is display-only: weight observations and diary records remain.
    expect(await LocalWorkspace(db).list('weight'), hasLength(2));
    expect(await DriftEntryRepository(db).entriesFor(date), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('both preferences hide independently without cross-suppression',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final date = _today();
    await _seedEntry(db, date);
    await _seedWeights(db);

    await _pump(tester, db, date,
        settings: const {
          'hideCalorieNudges': true,
          'hideWeightNudges': true
        });

    expect(find.text('Energy'), findsNothing);
    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('Carbohydrate'), findsOneWidget);
    expect(find.text('Fat'), findsOneWidget);
    expect(find.text('Fibre'), findsOneWidget);
    expect(find.text('Record weight'), findsNothing);

    await _openCheckIn(tester);
    expect(find.textContaining('123.4'), findsNothing);
    expect(find.textContaining('endpoint difference'), findsNothing);
    expect(find.textContaining('Weight trend'), findsNothing);
    await _closeCheckIn(tester);
    expect(await DriftEntryRepository(db).entriesFor(date), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('master support overrides individual preferences', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final date = _today();
    await _seedEntry(db, date);
    await _seedWeights(db);

    await _pump(tester, db, date,
        settings: const {
          'support': true,
          'hideCalorieNudges': false,
          'hideWeightNudges': false
        });

    expect(find.text('Recorded nutrition'), findsNothing);
    expect(find.text('Energy'), findsNothing);
    expect(find.text('Protein'), findsNothing);
    expect(find.text('Record weight'), findsNothing);

    await _openCheckIn(tester);
    expect(find.textContaining('123.4'), findsNothing);
    expect(find.textContaining('121.2'), findsNothing);
    expect(find.textContaining('Weight trend'), findsNothing);
    expect(find.text('Weekly check-in'), findsWidgets);
    await _closeCheckIn(tester);
    expect(await LocalWorkspace(db).list('weight'), hasLength(2));
    expect(tester.takeException(), isNull);
  });

}
