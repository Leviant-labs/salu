import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/search/search_screen.dart';
import 'package:salu/src/features/today/today_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/ui_support.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

Future<void> pump(WidgetTester t, AppDatabase db, Widget child,
    {bool pt = false, bool support = false, double scale = 1}) async {
  await t.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        initialSettingsProvider.overrideWithValue({
          'language': pt ? 'pt' : 'en',
          'support': support,
          'onboarded': true
        })
      ],
      child: MaterialApp(
          locale: pt ? const Locale('pt', 'PT') : const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (c, child) => MediaQuery(
              data: MediaQuery.of(c)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(body: child))));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('check-in shows recorded fibre coverage without adequacy claims',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final now = DateTime.now();
    final stamp =
        EventStamp(instant: now, offsetMinutes: now.timeZoneOffset.inMinutes);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'coverage-entry',
        requestId: 'coverage-request',
        diaryDate: DiaryDate.assign(stamp),
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: now,
        items: [
          LoggedItem(
              name: 'Known',
              grams: 10,
              nutrients:
                  NutrientProfile({NutrientKey.fiberG: NutrientReported(0)})),
          LoggedItem(
              name: 'Unknown',
              grams: 10,
              nutrients: const NutrientProfile.empty()),
        ]));
    await pump(t, db, const TodayScreen());
    await t.ensureVisible(find.text('Weekly check-in'));
    await t.tap(find.text('Weekly check-in'));
    await t.pumpAndSettle();
    expect(find.textContaining('1 reported, 0 estimated, 0 trace, 1 unknown'),
        findsOneWidget);
    expect(find.textContaining('does not assess adequacy'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('weekly check-in reports an empty week as missing data',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await pump(t, db, const TodayScreen());
    await t.ensureVisible(find.text('Weekly check-in'));
    await t.tap(find.text('Weekly check-in'));
    await t.pumpAndSettle();
    expect(
        find.textContaining('7 incomplete or not declared.'), findsOneWidget);
    expect(find.textContaining('Missing days are never counted as zero.'),
        findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('check-in describes observed weight without attributing a cause',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final now = DateTime.now();
    final workspace = LocalWorkspace(db);
    for (final item in [
      (id: 'early', at: now.subtract(const Duration(days: 1)), kg: '71'),
      (id: 'late', at: now, kg: '70')
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
    await pump(t, db, const TodayScreen());
    await t.ensureVisible(find.text('Weekly check-in'));
    await t.tap(find.text('Weekly check-in'));
    await t.pumpAndSettle();
    expect(find.textContaining('last recorded weight in this window is lower'),
        findsOneWidget);
    expect(find.textContaining('does not measure fat change'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('offline catalogue selection logs chosen volume with no density',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: 'drink',
          name: 'Test drink',
          per100g:
              NutrientProfile({NutrientKey.energyKcal: NutrientReported(40)}),
          source: const FoodSource(dataset: 'custom', datasetId: 'd'),
          basisUnit: FoodUnit.ml)
    ]);
    await pump(t, db, const SearchScreen());
    await t.enterText(find.byType(TextField).first, 'Test');
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Choose quantity and log'));
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '100'), '250');
    await t.tap(find.text('Confirm intake'));
    await t.pumpAndSettle();
    final records = await db.select(db.logEntries).get();
    expect(records, hasLength(1));
    final item = (await db.select(db.logEntryItems).get()).single;
    expect(item.grams, isNull);
    expect(item.nutrientsJson, contains('100.0'));
  });
  testWidgets(
      'pt-PT diary remains usable at large text and supportive mode hides budgets',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await pump(t, db, const TodayScreen(), pt: true, support: true, scale: 2);
    expect(find.text('Ainda não há registos'), findsOneWidget);
    expect(find.text('Nutrição registada'), findsNothing);
    expect(find.text('Registar peso'), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets('an entirely unknown diary never renders measured zero energy',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await pump(t, db, const TodayScreen());
    expect(find.text('-- kcal'), findsOneWidget);
    expect(find.text('0 kcal'), findsNothing);
  });
}
