import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:salu/src/features/meals/meal_editor.dart';
import 'package:salu/src/features/meals/meal_editor_ai.dart';
import 'package:salu/src/features/meals/meal_editor_data.dart';
import 'package:salu/src/features/meals/meal_editor_images.dart';
import 'package:salu/src/media/managed_media_store.dart';
import 'package:salu_core/salu_core.dart';

import 'meal_editor_fakes.dart';

// 1x1 transparent PNG.
final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

Future<void> _flushIo(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

final class _ThrowingPhotoMeals implements PhotoMealRepository {
  @override
  Future<List<PhotoMeal>> listFor(DiaryDate date) async => const [];

  @override
  Future<bool> saveNew(PhotoMeal meal) async {
    throw StateError('ambiguous write failure');
  }

  @override
  Future<bool> replace(PhotoMeal meal, int expectedRevision) async {
    throw StateError('ambiguous write failure');
  }
}

void main() {
  final date = DiaryDate.parse('2026-11-18');

  testWidgets('a new Lunch request saves estimates without a review step',
      (tester) async {
    final store = MemoryPhotoMeals();
    final api = FakeOpenAi(reply: {
      'items': [
        {
          'name': 'Bean stew',
          'portion': {'amount': 150, 'unit': 'grams'},
          'nutrients': {'energy_kcal': 190}
        },
        {
          'name': 'Unidentified side',
          'portion': null,
          'nutrients': {'energy_kcal': 5}
        },
      ],
    });
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => MealEditor(
                                repository: store,
                                assistant: api.assistant,
                                foods: const EmptyCatalogue(),
                                date: date,
                                newId: () => 'meal-1'),
                          )),
                      child: const Text('Open editor')),
                ))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byType(TextField), 'This was my lunch today: bean stew');
    await tester.pumpAndSettle();
    final save = find.text('Save with AI estimate');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final meal = store.meals.values.single;
    expect(find.text('Open editor'), findsOneWidget);
    expect(meal.date, date);
    expect(meal.slot, MealSlot.lunch);
    expect(meal.items.first.nutrients[NutrientKey.energyKcal],
        isA<NutrientEstimated>());
    expect(meal.items.last.nutrients[NutrientKey.energyKcal],
        NutrientValue.unknown);
    expect(api.requests, hasLength(1));
  });

  testWidgets('saves before the provider returns and keeps a newer correction',
      (tester) async {
    final store = MemoryPhotoMeals();
    final wait = Completer<void>();
    final api = FakeOpenAi(waitForReply: wait.future, reply: {
      'items': [
        {
          'name': 'Soup',
          'portion': {'amount': 150, 'unit': 'millilitres'},
          'nutrients': {'energy_kcal': 120}
        },
      ]
    });
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                              builder: (_) => MealEditor(
                                    repository: store,
                                    assistant: api.assistant,
                                    foods: const EmptyCatalogue(),
                                    date: date,
                                    newId: () => 'meal-2',
                                    initialDescription:
                                        'This was yesterday’s lunch',
                                    today: date,
                                  ))),
                      child: const Text('Open editor')),
                ))));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    final save = find.text('Save with AI estimate');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Open editor'), findsOneWidget);
    final saved = store.meals.values.single;
    expect(saved.date, date.addDays(-1));
    expect(saved.slot, MealSlot.lunch);
    expect(saved.items, isEmpty);
    expect(saved.estimateStatus, MealEstimateStatus.pending);
    expect(api.requests, hasLength(1));
    await store.replace(
        saved.copyWith(items: [PhotoMealItem(name: 'Half a roll')]),
        saved.revision);
    wait.complete();
    await tester.pumpAndSettle();
    expect(store.meals.values.single.items.single.name, 'Half a roll');
    expect(store.meals.values.single.revision, 2);
  });

  test('corrections scale only the same item and compatible unit', () {
    final rice = PhotoMealItem(
        name: 'Rice',
        portion: MealPortion(160, MealUnit.grams),
        nutrients: NutrientProfile(
            {NutrientKey.energyKcal: NutrientEstimated(200, basis: 'photo')}));
    final proposed = parseMealCorrection(
        {
          'edits': [
            {
              'op': 'update',
              'index': 0,
              'portion': {'amount': 80, 'unit': 'grams'}
            },
          ]
        },
        MealSlot.lunch,
        [rice])!;
    expect(proposed.items.single.nutrients[NutrientKey.energyKcal],
        NutrientEstimated(100, basis: 'photo'));
    expect(rice.nutrients[NutrientKey.energyKcal].numericValue, 200);
    expect(
        reviseMealItem(rice, 'Beans', rice.portion).nutrients.hasAnyKnownValue,
        isFalse);
  });

  test(
      'a label per 100 ml scales in ml without a density and preserves printed zero',
      () {
    final label = parseMealLabel({
      'basis': {'amount': 100, 'unit': 'millilitres'},
      'nutrients': {'energy_kcal': 40, 'fat_g': 0, 'unknown_field': 1}
    })!;
    final values = NutrientProfile(label.values
        .map((key, value) => MapEntry(key, NutrientReported(value))));
    final drink = scaleMealLabel(
        values, label.basis, MealPortion(250, MealUnit.millilitres))!;
    expect(drink[NutrientKey.energyKcal], NutrientReported(100));
    expect(drink[NutrientKey.fatG], NutrientReported(0));
    expect(drink[NutrientKey.proteinG], NutrientValue.unknown);
    expect(
        scaleMealLabel(values, label.basis, MealPortion(250, MealUnit.grams)),
        isNull);
  });

  testWidgets(
      'recovered picker photo offers attach/discard without auto-inference or save',
      (tester) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('salu-recover-'),
    );
    addTearDown(() async {
      PaintingBinding.instance.imageCache.clear();
      try {
        await root?.delete(recursive: true);
      } on FileSystemException {
        // Windows may hold decoded image handles briefly after test teardown.
      }
    });
    final recoveredFile = File('${root!.path}/recovered.png');
    await tester.runAsync(() => recoveredFile.writeAsBytes(_tinyPngBytes));

    final store = MemoryPhotoMeals();
    final api = FakeOpenAi();
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'recovered-1',
      lostDataRetriever: () async => [XFile(recoveredFile.path)],
    );

    await tester.pumpWidget(MaterialApp(
      home: MealEditor(
        repository: store,
        assistant: api.assistant,
        media: media,
        foods: const EmptyCatalogue(),
        date: date,
        newId: () => 'meal-recover',
      ),
    ));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();

    expect(
        find.text('Recovered photo from interrupted picker'), findsOneWidget);
    expect(find.text('Attach to meal'), findsOneWidget);
    expect(find.text('Discard'), findsOneWidget);
    // Zero automatic inference or automatic intake save.
    expect(api.requests, isEmpty);
    expect(store.meals, isEmpty);

    await tester.tap(find.text('Attach to meal'));
    await tester.pump();
    await _flushIo(tester);

    expect(find.text('Recovered photo from interrupted picker'), findsNothing);
    expect(api.requests, isEmpty);
    expect(store.meals, isEmpty);
    final resolved = await tester.runAsync(
      () => media.resolve('media:recovered-1'),
    );
    expect(resolved, isNotNull);
  });

  testWidgets('disposal protects ambiguous-write images from deletion',
      (tester) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('salu-ambiguous-'),
    );
    addTearDown(() async {
      PaintingBinding.instance.imageCache.clear();
      try {
        await root?.delete(recursive: true);
      } on FileSystemException {
        // Windows may hold decoded image handles briefly after test teardown.
      }
    });
    final sourceFile = File('${root!.path}/camera.png');
    await tester.runAsync(() => sourceFile.writeAsBytes(_tinyPngBytes));

    final previousPicker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = FixturePicker(sourceFile.path);
    addTearDown(() => ImagePickerPlatform.instance = previousPicker);

    final store = _ThrowingPhotoMeals();
    final api = FakeOpenAi();
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'ambiguous-photo',
      lostDataRetriever: () async => const [],
    );

    await tester.pumpWidget(MaterialApp(
      home: MealEditor(
        repository: store,
        assistant: api.assistant,
        media: media,
        foods: const EmptyCatalogue(),
        date: date,
        newId: () => 'meal-ambiguous',
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Camera'));
    await tester.pump();
    await _flushIo(tester);

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    final save = find.text('Save without AI');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump();
    await _flushIo(tester);

    // Dispose the editor after an ambiguous write failure.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    // The managed file must still exist because the write outcome was ambiguous.
    final resolved = await tester.runAsync(
      () => media.resolve('media:ambiguous-photo'),
    );
    expect(resolved, isNotNull);
  });

  test('encodeMealUpload resolves managed ref and rejects missing ref',
      () async {
    final root = await Directory.systemTemp.createTemp('salu-encode-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/input.png');
    await source.writeAsBytes(_tinyPngBytes);
    final media = ManagedMediaStore(
      directory: () async => Directory('${root.path}/owned'),
      newId: () => 'upload-1',
    );
    final ref = await media.importImage(XFile(source.path));

    final encoded = await encodeMealUpload(ref, media: media);
    expect(encoded, isNotEmpty);
    // PNG magic header.
    expect(encoded.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);

    await expectLater(
      () => encodeMealUpload('media:missing-ref', media: media),
      throwsA(isA<FileSystemException>()),
    );
  });
}
