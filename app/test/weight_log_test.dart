import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/today/diary_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/ui_support.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

Future<void> _pump(WidgetTester tester, AppDatabase db) async {
  final now = DateTime.now();
  await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        todayDiaryDateProvider.overrideWithValue(DiaryDate.assign(
            EventStamp(
                instant: now,
                offsetMinutes: now.timeZoneOffset.inMinutes))),
        initialSettingsProvider.overrideWithValue(
            const {'language': 'en', 'onboarded': true}),
      ],
      child: const MaterialApp(home: Scaffold(body: DiaryScreen()))));
  await tester.pumpAndSettle();
}

Future<void> _seedReading(AppDatabase db,
    {required String id, required DateTime at, required String kg}) async {
  await LocalWorkspace(db).put(
      requestId: id,
      collection: 'weight',
      id: id,
      expectedRevision: 0,
      data: {
        'value': Exact.parse(kg).toJson(),
        'unit': 'kg',
        'time': at.toUtc().toIso8601String(),
        'offsetMinutes': at.timeZoneOffset.inMinutes,
      });
}

Future<void> _openWeightLog(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.text('Record weight'), 200);
  await tester.tap(find.text('Record weight'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'weight log reports endpoint evidence with explicit limits, not a trend',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final now = DateTime.now();
    await _seedReading(db,
        id: 'earliest', at: now.subtract(const Duration(days: 2)), kg: '71.5');
    await _seedReading(db, id: 'latest', at: now, kg: '70.2');

    await _pump(tester, db);
    await _openWeightLog(tester);

    expect(find.text('Weight readings'), findsOneWidget);
    expect(find.textContaining('Endpoint difference: -1.3 kg'), findsOneWidget);
    expect(find.textContaining('71.5 kg'), findsWidgets);
    expect(find.textContaining('70.2 kg'), findsWidgets);
    expect(find.textContaining('it is not a trend'), findsOneWidget);
    expect(find.textContaining('never changes calorie targets'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining('No platform health data'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('No platform health data'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'readings sharing an endpoint time never become an ordered comparison',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final now = DateTime.now();
    await _seedReading(db,
        id: 'first-a',
        at: now.subtract(const Duration(days: 1)),
        kg: '70');
    await _seedReading(db,
        id: 'first-b',
        at: now.subtract(const Duration(days: 1)),
        kg: '71');
    await _seedReading(db, id: 'latest', at: now, kg: '72');

    await _pump(tester, db);
    await _openWeightLog(tester);

    expect(find.textContaining('not a trend'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining(
            'More than one reading shares the earliest or latest recorded time'),
        100,
        scrollable: find.byType(Scrollable).first);
    expect(
        find.textContaining(
            'More than one reading shares the earliest or latest recorded time'),
        findsOneWidget);
    expect(find.textContaining('Endpoint difference'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('readings without two distinct times are not compared',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final now = DateTime.now();
    await _seedReading(db, id: 'a', at: now, kg: '70');
    await _seedReading(db, id: 'b', at: now, kg: '71');

    await _pump(tester, db);
    await _openWeightLog(tester);

    await tester.scrollUntilVisible(
        find.textContaining('do not have two distinct, unambiguous times'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(
        find.textContaining('do not have two distinct, unambiguous times'),
        findsOneWidget);
    expect(find.textContaining('Endpoint difference'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recording a reading keeps the evidence limits visible',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);

    await _pump(tester, db);
    await _openWeightLog(tester);

    await tester.enterText(find.byType(TextField), '72,4');
    await tester.tap(find.text('Record reading'));
    await tester.pumpAndSettle();

    final stored = await LocalWorkspace(db).list('weight');
    expect(stored, hasLength(1));
    expect(find.textContaining('One reading is recorded'), findsOneWidget);
    expect(find.textContaining('never changes calorie targets'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('72.4 kg'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('72.4 kg'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
