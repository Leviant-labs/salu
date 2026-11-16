import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/search/search_screen.dart';
import 'package:salu/src/features/search/saved_meals_screen.dart';
import 'package:salu/src/features/today/diary_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as harness;

Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);

/// The single stored entry for its assigned diary date, hydrated from SQLite.
Future<LoggedEntry> readEntry(AppDatabase db) async {
  final row = (await db.select(db.logEntries).get()).single;
  return (await DriftEntryRepository(db)
          .entriesFor(DiaryDate.parse(row.diaryDate)))
      .single;
}

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
    await harness.pump(t, db, const DiaryScreen());
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
  testWidgets('a barcode match records barcode provenance', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: 'yogurt',
          name: 'Plain yogurt',
          per100g:
              NutrientProfile({NutrientKey.energyKcal: NutrientReported(60)}),
          source: const FoodSource(dataset: 'custom', datasetId: 'yogurt'),
          barcodes: const ['4006381333931'])
    ]);
    await harness.pump(t, db, const SearchScreen());
    await t.tap(find.text('Enter barcode'));
    await t.pumpAndSettle();
    await t.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '4006381333931');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Choose quantity and log'));
    await t.pumpAndSettle();
    await t.tap(find.text('Confirm intake'));
    await t.pumpAndSettle();
    expect((await readEntry(db)).channel, EntryChannel.barcode);
    expect(t.takeException(), isNull);
  });
  testWidgets('search names a short query, a local miss and empty lists apart',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await harness.pump(t, db, const SearchScreen());
    expect(
        find.text('Type at least two characters to search.'), findsOneWidget);
    await t.enterText(field('Search local foods'), 'zzz');
    await t.pumpAndSettle();
    expect(
        find.text(
            'No local match. Create a food from its label or check the barcode; no network lookup is made.'),
        findsOneWidget);
    await t.tap(find.text('Favourites'));
    await t.pumpAndSettle();
    expect(
        find.text(
            'No favourite foods yet. Tap the star on a result to keep it here.'),
        findsOneWidget);
    await t.tap(find.text('Recently recorded'));
    await t.pumpAndSettle();
    expect(
        find.text(
            'Nothing recorded recently yet. Foods you record appear here.'),
        findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'quantity input ignores surrounding spaces and keeps exact decimals',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: 'bread',
          name: 'Rye bread',
          per100g:
              NutrientProfile({NutrientKey.energyKcal: NutrientReported(250)}),
          source: const FoodSource(dataset: 'custom', datasetId: 'bread'))
    ]);
    await harness.pump(t, db, const SearchScreen());
    await t.enterText(field('Search local foods'), 'Rye');
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Choose quantity and log'));
    await t.pumpAndSettle();
    await t.enterText(field('Consumed amount'), ' 33.5 ');
    await t.tap(find.text('Confirm intake'));
    await t.pumpAndSettle();
    final entry = await readEntry(db);
    expect(entry.channel, EntryChannel.search);
    expect(entry.items.single.quantity!.value, Exact.parse('33.5'));
    expect(entry.items.single.nutrients[NutrientKey.energyKcal].exactValue,
        Exact.parse('83.75'));
    expect(t.takeException(), isNull);
  });
  testWidgets('a custom food stores a trimmed basis and stays loggable',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    // Use a large surface for the main label fields; the remaining fields scroll.
    t.view.physicalSize = const Size(900, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await harness.pump(t, db, const SearchScreen());
    await t.tap(find.text('Create a custom food'));
    await t.pumpAndSettle();
    await t.enterText(field('Food name'), 'Label oats');
    await t.enterText(field('Label basis amount'), ' 80 ');
    await t.scrollUntilVisible(find.text('Save custom food'), 500,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Save custom food'));
    await t.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);
    final food = (await DriftFoodRepository(db).search('Label oats')).single;
    expect(food.basisValue, '80');
    await t.enterText(field('Search local foods'), 'Label oats');
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Choose quantity and log'));
    await t.pumpAndSettle();
    await t.tap(find.text('Confirm intake'));
    await t.pumpAndSettle();
    expect(
        (await readEntry(db)).items.single.quantity!.value, Exact.parse('80'));
    expect(t.takeException(), isNull);
  });
  testWidgets('changing an amount corrects a single food entry exactly',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'oats-entry',
        requestId: 'oats-request',
        diaryDate: DiaryDate.assign(stamp),
        stamp: stamp,
        channel: EntryChannel.search,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Oats',
              grams: 100,
              quantity: FoodAmount.exact(Exact.parse('100'), FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(200)}))
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Change quantity'));
    await t.pumpAndSettle();
    final prompt = t.widget<TextField>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField)));
    expect(Exact.parse(prompt.controller!.text), Exact.parse('100'));
    await t.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '250');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    final row = (await db.select(db.logEntries).get()).single;
    expect(row.revision, 2);
    final corrected = await readEntry(db);
    expect(corrected.items.single.quantity!.value, Exact.parse('250'));
    expect(corrected.items.single.grams, 250);
    expect(corrected.items.single.nutrients[NutrientKey.energyKcal].exactValue,
        Exact.parse('500'));
    expect(t.takeException(), isNull);
  });
  testWidgets('a legacy entry without a unit amount is corrected by grams',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'legacy-entry',
        requestId: 'legacy-request',
        diaryDate: DiaryDate.assign(stamp),
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Legacy food',
              grams: 100,
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(150)}))
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Change quantity'));
    await t.pumpAndSettle();
    final prompt = t.widget<TextField>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField)));
    expect(Exact.parse(prompt.controller!.text), Exact.parse('100'));
    await t.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '250');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    final corrected = await readEntry(db);
    expect(corrected.items.single.grams, 250);
    expect(corrected.items.single.quantity, isNull);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'repeating a cooked-batch entry explains the conflict and writes nothing',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'stew-entry',
        requestId: 'stew-request',
        diaryDate: DiaryDate.assign(stamp),
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Stew',
              grams: null,
              quantity: FoodAmount.exact(Exact.parse('200'), FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(300)}),
              sourceSnapshot: {
                'batchId': 'batch-1',
                'consumedBatchGrams': Exact.parse('200').toJson()
              })
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Repeat now'));
    await t.pumpAndSettle();
    expect(find.textContaining('finite cooked-batch stock'), findsOneWidget);
    expect(find.text('Repeat meal now?'), findsNothing);
    expect(await db.select(db.logEntries).get(), hasLength(1));
    expect(t.takeException(), isNull);
  });
  testWidgets('deleting a cooked-batch portion states that stock stays used',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'soup-entry',
        requestId: 'soup-request',
        diaryDate: DiaryDate.assign(stamp),
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Soup',
              grams: null,
              quantity: FoodAmount.exact(Exact.parse('250'), FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(120)}),
              sourceSnapshot: {
                'batchId': 'batch-2',
                'consumedBatchGrams': Exact.parse('250').toJson()
              })
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete entry'));
    await t.pumpAndSettle();
    expect(
        find.textContaining('keeps this amount recorded as consumed'),
        findsOneWidget);
    await t.tap(find.text('Confirm'));
    await t.pumpAndSettle();
    expect(await db.select(db.logEntries).get(), isEmpty);
    expect(t.takeException(), isNull);
  });
  testWidgets('declaring no intake is refused while the day has records',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    final day = DiaryDate.assign(stamp);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'breakfast-entry',
        requestId: 'breakfast-request',
        diaryDate: day,
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Toast',
              grams: 40,
              nutrients: NutrientProfile(
                  {NutrientKey.proteinG: NutrientReported(3)}))
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.ensureVisible(find.text('Declare day completeness'));
    await t.tap(find.text('Declare day completeness'));
    await t.pumpAndSettle();
    await t.tap(find.text('I confirm no intake'));
    await t.pumpAndSettle();
    expect(find.textContaining('already has recorded intake'), findsOneWidget);
    final stored = await LocalWorkspace(db).read('day', day.toIso());
    expect(stored!.data['completeness'], 'partial');
    expect(await LocalWorkspace(db).read('reward', 'day-review:${day.toIso()}'),
        isNull);
    expect(t.takeException(), isNull);
  });
  testWidgets('an unknown stored day declaration keeps the check-in usable',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    final day = DiaryDate.assign(stamp);
    // A newer app version could write a declaration this build does not know.
    // Reading it as unknown preserves it instead of failing the whole check-in.
    await db.into(db.userDocuments).insert(UserDocumentsCompanion.insert(
        collection: 'day',
        id: day.toIso(),
        revision: 1,
        payload: jsonEncode({'completeness': 'fromAFutureVersion'})));
    await harness.pump(t, db, const DiaryScreen());
    await t.ensureVisible(find.text('Weekly check-in'));
    await t.tap(find.text('Weekly check-in'));
    await t.pumpAndSettle();
    expect(find.textContaining('Missing days are never counted as zero.'),
        findsOneWidget);
    await harness.scrollCheckInTo(
        t, find.textContaining('incomplete or not declared'));
    expect(find.textContaining('incomplete or not declared'), findsOneWidget);
    expect((await LocalWorkspace(db).read('day', day.toIso()))!
        .data['completeness'], 'fromAFutureVersion');
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'a multi-item entry corrects one item without changing the others',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    final day = DiaryDate.assign(stamp);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'entry',
        requestId: 'original',
        diaryDate: day,
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Rice',
              grams: 100,
              quantity: FoodAmount('100', FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(130)})),
          LoggedItem(
              name: 'Chicken',
              grams: 50,
              quantity: FoodAmount('50', FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(82.5)})),
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.ensureVisible(find.byTooltip('Edit entry'));
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Change quantity'));
    await t.pumpAndSettle();
    expect(find.text('Which item?'), findsOneWidget);
    await t.tap(find.widgetWithText(SimpleDialogOption, 'Rice'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('New amount (g)'), findsWidgets);
    await t.enterText(find.byType(TextField), '150');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();

    final corrected =
        (await DriftEntryRepository(db).entriesFor(day)).single;
    expect(corrected.revision, 2);
    expect(corrected.items[0].name, 'Rice');
    expect(corrected.items[0].quantity!.value, Exact.parse('150'));
    expect(corrected.items[0].grams, 150);
    expect(corrected.items[1].name, 'Chicken');
    expect(corrected.items[1].quantity!.value, Exact.parse('50'));
    expect(corrected.items[1].grams, 50);
    expect(
        corrected.items[1].nutrients.toJson(),
        NutrientProfile({NutrientKey.energyKcal: NutrientReported(82.5)})
            .toJson());
    expect(t.takeException(), isNull);
  });
  testWidgets('substituting a food writes only the reviewed item', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: 'lentils',
          name: 'Lentils',
          per100g:
              NutrientProfile({NutrientKey.energyKcal: NutrientReported(120)}),
          source: const FoodSource(dataset: 'custom', datasetId: 'lentils'))
    ]);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    final day = DiaryDate.assign(stamp);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'entry',
        requestId: 'original',
        diaryDate: day,
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Rice',
              grams: 100,
              quantity: FoodAmount('100', FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(130)})),
          LoggedItem(
              name: 'Chicken',
              grams: 50,
              quantity: FoodAmount('50', FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(82.5)})),
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.ensureVisible(find.byTooltip('Edit entry'));
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Substitute food'));
    await t.pumpAndSettle();
    expect(find.text('Which item to replace?'), findsOneWidget);
    await t.tap(find.widgetWithText(SimpleDialogOption, 'Rice'));
    await t.pumpAndSettle();
    await t.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'Lentils');
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(ListTile, 'Lentils'));
    await t.pumpAndSettle();
    final amount = t.widget<TextField>(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField)));
    expect(Exact.parse(amount.controller!.text), Exact.parse('100'));
    await t.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        '150');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(find.text('Substitute food?'), findsOneWidget);
    expect(find.textContaining('Only this item changes'), findsOneWidget);
    await t.tap(find.text('Confirm'));
    await t.pumpAndSettle();

    final replaced = (await DriftEntryRepository(db).entriesFor(day)).single;
    expect(replaced.revision, 2);
    expect(replaced.items[0].name, 'Lentils');
    expect(replaced.items[0].grams, 150);
    expect(replaced.items[0].quantity!.value, Exact.parse('150'));
    expect(replaced.items[0].nutrients[NutrientKey.energyKcal].exactValue,
        Exact.parse('180'));
    expect(replaced.items[1].name, 'Chicken');
    expect(replaced.items[1].quantity!.value, Exact.parse('50'));
    expect(replaced.items[1].grams, 50);
    expect(
        replaced.items[1].nutrients.toJson(),
        NutrientProfile({NutrientKey.energyKcal: NutrientReported(82.5)})
            .toJson());
    expect(await LocalWorkspace(db).list('entry-revision'), hasLength(1));
    expect(t.takeException(), isNull);
  });
  testWidgets('cancelling the substitution review writes nothing', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(
          id: 'lentils',
          name: 'Lentils',
          per100g:
              NutrientProfile({NutrientKey.energyKcal: NutrientReported(120)}),
          source: const FoodSource(dataset: 'custom', datasetId: 'lentils'))
    ]);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    final day = DiaryDate.assign(stamp);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'entry',
        requestId: 'original',
        diaryDate: day,
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Rice',
              grams: 100,
              quantity: FoodAmount('100', FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(130)}))
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.ensureVisible(find.byTooltip('Edit entry'));
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Substitute food'));
    await t.pumpAndSettle();
    await t.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'Lentils');
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(ListTile, 'Lentils'));
    await t.pumpAndSettle();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(find.text('Substitute food?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();

    final unchanged = (await DriftEntryRepository(db).entriesFor(day)).single;
    expect(unchanged.revision, 1);
    expect(unchanged.items.single.name, 'Rice');
    expect(unchanged.items.single.quantity!.value, Exact.parse('100'));
    expect(await LocalWorkspace(db).list('entry-revision'), isEmpty);
    expect(t.takeException(), isNull);
  });
  testWidgets('substituting a cooked-batch portion is refused', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp = EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes);
    await DriftEntryRepository(db).append(LoggedEntry(
        id: 'stew-entry',
        requestId: 'stew-request',
        diaryDate: DiaryDate.assign(stamp),
        stamp: stamp,
        channel: EntryChannel.manual,
        recordedAt: stamp.instantUtc,
        items: [
          LoggedItem(
              name: 'Stew',
              grams: null,
              quantity: FoodAmount.exact(Exact.parse('200'), FoodUnit.g),
              nutrients: NutrientProfile(
                  {NutrientKey.energyKcal: NutrientReported(300)}),
              sourceSnapshot: {
                'batchId': 'batch-1',
                'consumedBatchGrams': Exact.parse('200').toJson()
              })
        ]));
    await harness.pump(t, db, const DiaryScreen());
    await t.tap(find.byTooltip('Edit entry'));
    await t.pumpAndSettle();
    await t.tap(find.text('Substitute food'));
    await t.pumpAndSettle();
    expect(find.textContaining('finite cooked batch'), findsOneWidget);
    expect(find.text('Which item to replace?'), findsNothing);
    expect(await db.select(db.logEntries).get(), hasLength(1));
    expect((await db.select(db.logEntries).get()).single.revision, 1);
    expect(await LocalWorkspace(db).list('entry-revision'), isEmpty);
    expect(t.takeException(), isNull);
  });
}
