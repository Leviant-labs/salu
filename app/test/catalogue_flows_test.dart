import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/search/search_screen.dart';
import 'package:salu/src/features/search/saved_meals_screen.dart';
import 'package:salu/src/features/today/today_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as harness;

Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);
void main() {
  testWidgets('favourites and barcode lookup are usable offline at large text',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: 'apple',
          name: 'Maçã',
          per100g: NutrientProfile({}),
          source: const FoodSource(dataset: 'custom', datasetId: 'apple'),
          barcodes: const ['4006381333931'])
    ]);
    await harness.pump(t, db, const SearchScreen(), scale: 1.5);
    await t.enterText(field('Search local foods'), 'Maçã');
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Toggle favourite'));
    await t.pumpAndSettle();
    await t.tap(find.text('Favourites'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Maçã'), findsOneWidget);
    await t.tap(find.text('Enter barcode'));
    await t.pumpAndSettle();
    await t.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '4006381333931');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Maçã'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'recording preserves exact input, consumed offset and assigned past diary day',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: 'apple',
          name: 'Apple',
          per100g:
              NutrientProfile({NutrientKey.energyKcal: NutrientReported(52)}),
          source: const FoodSource(dataset: 'custom', datasetId: 'apple'))
    ]);
    await harness.pump(t, db, const SearchScreen());
    await t.enterText(field('Search local foods'), 'Apple');
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Choose quantity and log'));
    await t.pumpAndSettle();
    await t.enterText(field('Consumed amount'), '33.333');
    await t.enterText(field('Consumed date (YYYY-MM-DD)'), '2025-03-30');
    await t.enterText(field('Local time (HH:mm)'), '00:15');
    await t.ensureVisible(field('UTC offset in minutes'));
    await t.enterText(field('UTC offset in minutes'), '60');
    await t.ensureVisible(field('Diary day (YYYY-MM-DD)'));
    await t.enterText(field('Diary day (YYYY-MM-DD)'), '2025-03-29');
    await t.tap(find.text('Confirm intake'));
    await t.pumpAndSettle();
    final entry =
        (await DriftEntryRepository(db).entriesFor(DiaryDate(2025, 3, 29)))
            .single;
    expect(entry.stamp.instantUtc, DateTime.utc(2025, 3, 29, 23, 15));
    expect(entry.stamp.offsetMinutes, 60);
    expect(entry.items.single.quantity!.value, Exact.parse('33.333'));
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'diary meal saves and requires a separate consumption confirmation',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'entry',
        requestId: 'original',
        diaryDate: DiaryDate.assign(stamp),
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Breakfast', grams: 100, nutrients: NutrientProfile({}))
        ]));
    await harness.pump(t, db, const TodayScreen());
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save meal'));
    await t.pumpAndSettle();
    await t.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'My breakfast');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), hasLength(1));
    await harness.pump(t, db, const SavedMealsScreen());
    await t.tap(find.byTooltip('Record consumed meal'));
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), hasLength(1));
    await t.tap(find.byTooltip('Record consumed meal'));
    await t.pumpAndSettle();
    await t.tap(find.text('Confirm intake'));
    await t.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), hasLength(2));
    expect(t.takeException(), isNull);
  });
}
