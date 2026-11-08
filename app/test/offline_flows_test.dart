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
