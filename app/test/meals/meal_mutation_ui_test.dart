import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/assistant.dart';
import 'package:salu/src/features/meals/meal_editor.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

void main() {
  final today = DiaryDate.parse('2026-11-19');

  Future<void> pumpEditor(
    WidgetTester tester, {
    required AppDatabase db,
    required PhotoMeal meal,
    required MealMutationRepository mutations,
    void Function(DiaryDate oldDate, DiaryDate newDate)? onMutated,
  }) async {
    var seq = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => MealEditor(
                meal: meal,
                repository: DriftPhotoMealRepository(db),
                mutations: mutations,
                assistant: SaluAssistant(),
                foods: DriftFoodRepository(db),
                date: meal.date,
                today: today,
                newId: () => 'req-${++seq}',
                onMutated: onMutated,
              ),
            )),
            child: const Text('Open editor'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
  }

  testWidgets('removing photo keeps label evidence and saves revision',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    final meal = PhotoMeal(
      id: 'meal-ui-photo',
      date: today,
      slot: MealSlot.lunch,
      caption: 'Yogurt bowl',
      createdAt: DateTime.utc(2026, 11, 19, 12),
      photoPath: 'media:meal-photo',
      items: [
        PhotoMealItem(
          id: 'item-1',
          name: 'Greek yogurt',
          labelPath: 'media:label-1',
        ),
      ],
    );
    await meals.saveNew(meal);

    await pumpEditor(tester, db: db, meal: meal, mutations: mutations);

    final removePhotoButton = find.text('Remove photo');
    await tester.scrollUntilVisible(
      removePhotoButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.drag(find.byType(ListView).first, const Offset(0, -150));
    await tester.pumpAndSettle();
    await tester.tap(removePhotoButton);
    await tester.pumpAndSettle();

    final saveButton = find.text('Save changes');
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    final saved = (await meals.listFor(today)).single;
    expect(saved.photoPath, isNull);
    expect(saved.items.single.labelPaths, ['media:label-1']);
    expect(saved.revision, 2);
  });

  testWidgets(
      'delete discloses batch stock non-replenishment and 10s Undo restores meal',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    final meal = PhotoMeal(
      id: 'meal-ui-del',
      date: today,
      slot: MealSlot.dinner,
      caption: 'Chili',
      createdAt: DateTime.utc(2026, 11, 19, 18),
      photoPath: 'media:chili',
    );
    await meals.saveNew(meal);

    await pumpEditor(tester, db: db, meal: meal, mutations: mutations);

    final deleteButton = find.text('Delete meal');
    await tester.scrollUntilVisible(
      deleteButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    expect(find.text('Delete this meal?'), findsOneWidget);
    expect(
      find.textContaining('does not replenish remaining batch stock'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Delete meal'));
    await tester.pumpAndSettle();

    expect(await meals.listFor(today), isEmpty);
    expect(find.text('Meal deleted.'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    final restored = (await meals.listFor(today)).single;
    expect(restored.id, 'meal-ui-del');
    expect(restored.revision, greaterThan(1));
    expect(restored.photoPath, 'media:chili');
    expect(find.text('Meal restored.'), findsOneWidget);
  });

  testWidgets('stale revision shows conflict error instead of overwriting',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final meals = DriftPhotoMealRepository(db);
    final mutations = MealMutationRepository(db, clock: const SystemClock());
    final meal = PhotoMeal(
      id: 'meal-ui-stale',
      date: today,
      slot: MealSlot.breakfast,
      caption: 'Toast',
      createdAt: DateTime.utc(2026, 11, 19, 8),
    );
    await meals.saveNew(meal);

    await pumpEditor(tester, db: db, meal: meal, mutations: mutations);

    // Concurrently advance revision behind the editor's back.
    await mutations.apply(ReviseMeal(
      requestId: 'bg-edit',
      meal: meal.copyWith(caption: 'Updated elsewhere'),
      expectedRevision: 1,
    ));

    final saveButton = find.text('Save changes');
    await tester.scrollUntilVisible(
      saveButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
          'This meal changed or was removed while you were editing'),
      findsOneWidget,
    );
    expect((await meals.listFor(today)).single.caption, 'Updated elsewhere');
  });
}
