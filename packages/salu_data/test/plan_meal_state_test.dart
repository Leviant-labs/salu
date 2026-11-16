import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

final class FixedClock implements Clock {
  FixedClock(this.instant);
  final DateTime instant;
  @override
  DateTime nowUtc() => instant.toUtc();
}

RecipeVersion _recipe(String id) {
  final food = Food(
    id: 'custom:$id',
    name: 'Ingredient $id',
    per100g: NutrientProfile({NutrientKey.proteinG: NutrientReported(10)}),
    source: const FoodSource(dataset: 'custom-user-entry', datasetId: '1'),
    quality: DataQuality.userEntered,
  );
  return RecipeVersion(
    id: id,
    revision: 1,
    name: 'Recipe $id',
    ingredients: [RecipeIngredient(food, Exact.parse('100'))],
    servings: Exact.one,
    minutes: 10,
  );
}

PlannedMeal _meal(String slotId, String date, RecipeVersion recipe) => PlannedMeal(
    MealSlot(slotId, date, 'Dinner'), recipe, Exact.one);

Future<void> _seedRecipe(AppDatabase db, RecipeVersion recipe) async {
  for (final ingredient in recipe.ingredients) {
    await DriftFoodRepository(db).replaceCatalogueBatch([ingredient.food]);
  }
  final id = '${recipe.id}:${recipe.revision}';
  final workspace = LocalWorkspace(db);
  if ((await workspace.read('recipe', id)) != null) return;
  await workspace.put(
    requestId: 'seed-recipe-$id',
    collection: 'recipe',
    id: id,
    expectedRevision: 0,
    data: recipeSnapshot(recipe),
  );
}

Map<String, Object?> _meta(String start, int days, String label) => {
      'schedule': <String, Object?>{
        'startDate': start,
        'days': days,
        'label': label,
        'portions': [Exact.one.toJson()],
      },
      'constraints': <String, Object?>{},
      'constraintRevision': 1,
      'acceptedRelaxations': <Object?>[],
    };

Future<void> _savePlan(AppDatabase db, String docId, List<PlannedMeal> meals) async {
  await _seedRecipe(db, meals.first.recipe);
  final service = PlanService(db, const SystemClock(), SequentialIdGenerator(),
      documentId: docId);
  await service.save(
    requestId: 'save-$docId',
    expectedPlanRevision: 0,
    meals: meals,
    metadata: _meta(meals.first.slot.date, meals.length, meals.first.slot.label),
  );
}

void main() {
  // Slot ids must match the generated '<label>:<index>' schedule.
  test('consume retry is idempotent and skip writes no intake', () async {
    final db = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(db, 'current', [meal]);
      final clock = FixedClock(DateTime.utc(2026, 11, 10, 12));
      final ids = SequentialIdGenerator(prefix: 'entry');
      final state = PlanMealStateService(db);
      final stamp = EventStamp(instant: DateTime.utc(2026, 11, 10, 12), offsetMinutes: 0);
      final first = await state.consumePlannedMeal(
        requestId: 'consume-1',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: ids,
      );
      // Retry with the same request replays the original entry — even after
      // the plan revision moves — because replay precedes stale checks.
      final retry = await state.consumePlannedMeal(
        requestId: 'consume-1',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'entry-retry'),
      );
      expect(retry.id, first.id);
      expect((await DriftEntryRepository(db).entriesFor(DiaryDate(2026, 11, 10))).length, 1);
      final prior = await DriftEntryRepository(db).findByRequestId('consume-1');
      expect(prior!.id, first.id);
      expect(prior.channel, EntryChannel.plan);
      // Required diaryDate is honored without assignedDiaryDate.
      expect(prior.diaryDate, DiaryDate(2026, 11, 10));
      expect(prior.stamp.instantUtc, DateTime.utc(2026, 11, 10, 12));
      final linked = await state.readForEntry(first.id);
      expect(linked, isNotNull);
      expect(linked!.state, PlanMealState.consumed);
      expect(linked.portions, Exact.one);

      // Skipping a consumed slot is rejected; the link stays consumed.
      await expectLater(
        () => state.skip(
          requestId: 'skip-consumed',
          planDocumentId: 'current',
          slotId: 'Dinner:0',
          date: DiaryDate(2026, 11, 10),
          recipe: recipe,
          plannedPortions: Exact.one,
          expectedRevision: 1,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'PLAN_MEAL_ALREADY_CONSUMED')),
      );
      expect((await state.readForEntry(first.id))!.state, PlanMealState.consumed);

    } finally {
      await db.close();
    }
  });

  test('skip on an unconsumed slot writes no intake', () async {
    final db = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(db, 'current', [meal]);
      final skipped = await PlanMealStateService(db).skip(
        requestId: 'skip-1',
        planDocumentId: 'current',
        slotId: 'Dinner:0',
        date: DiaryDate(2026, 11, 10),
        recipe: recipe,
        plannedPortions: Exact.one,
        expectedRevision: 0,
        expectedPlanRevision: 1,
      );
      expect(skipped.state, PlanMealState.skipped);
      expect(await DriftEntryRepository(db).findByRequestId('skip-1'), isNull);
      expect(await DriftEntryRepository(db).entriesFor(DiaryDate(2026, 11, 10)), isEmpty);
    } finally {
      await db.close();
    }
  });

  test('explicit occurredAt is honored and offset mismatch rejected', () async {
    final db = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(db, 'current', [meal]);
      final clock = FixedClock(DateTime.utc(2026, 11, 10, 12));
      final stamp = EventStamp(
          instant: DateTime.utc(2026, 11, 9, 23, 30), offsetMinutes: 60);
      final entry = await PlanMealStateService(db).consumePlannedMeal(
        requestId: 'consume-time',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 60,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'entry'),
        occurredAt: stamp,
        assignedDiaryDate: DiaryDate(2026, 11, 10),
      );
      expect(entry.stamp.instantUtc, DateTime.utc(2026, 11, 9, 23, 30));
      expect(entry.diaryDate, DiaryDate(2026, 11, 10));
      expect(entry.recordedAt, DateTime.utc(2026, 11, 10, 12));

      await expectLater(
        () => LogRecipeHandler(
            DriftEntryRepository(db), clock, SequentialIdGenerator())
          .handle(LogRecipeCommand(
            requestId: 'bad-offset',
            recipe: recipe,
            portions: Exact.one,
            offsetMinutes: 0,
            confirmed: true,
            occurredAt: EventStamp(
                instant: DateTime.utc(2026), offsetMinutes: 60),
          )),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'INVALID_TIME_OFFSET')),
      );
    } finally {
      await db.close();
    }
  });

  test('date move clears link and scaling updates portions', () async {
    final db = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(db, 'current', [meal]);
      final clock = FixedClock(DateTime.utc(2026, 11, 10, 12));
      final stamp = EventStamp(instant: DateTime.utc(2026, 11, 10, 12), offsetMinutes: 0);
      final entry = await PlanMealStateService(db).consumePlannedMeal(
        requestId: 'consume-2',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'entry'),
      );
      final repo = DriftEntryRepository(db);
      await repo.revise(ReviseEntryCommand(
        requestId: 'scale-1',
        entryId: entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026, 11, 10, 13),
        multiplier: Exact.parse('2'),
      ));
      final scaled = await PlanMealStateService(db).readForEntry(entry.id);
      expect(scaled!.portions, Exact.parse('2'));

      await repo.revise(ReviseEntryCommand(
        requestId: 'move-1',
        entryId: entry.id,
        expectedRevision: 2,
        recordedAt: DateTime.utc(2026, 11, 10, 14),
        diaryDate: DiaryDate(2026, 11, 11),
      ));
      expect(await PlanMealStateService(db).readForEntry(entry.id), isNull);
    } finally {
      await db.close();
    }
  });

  test('deletion clears link and substitution keeps it', () async {
    final db = AppDatabase.memory();
    try {
      final entries = DriftEntryRepository(db);
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(db, 'current', [meal]);
      final clock = FixedClock(DateTime.utc(2026, 11, 10, 12));
      final stamp = EventStamp(instant: DateTime.utc(2026, 11, 10, 12), offsetMinutes: 0);
      final entry = await PlanMealStateService(db).consumePlannedMeal(
        requestId: 'consume-3',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'entry'),
      );
      // Substitution keeps the consumed link.
      final replacement = Food(
        id: 'food-repl',
        name: 'Replacement',
        per100g: NutrientProfile({NutrientKey.proteinG: NutrientReported(10)}),
        source: const FoodSource(dataset: 'fixture', datasetId: '1'),
      );
      await entries.substituteItem(SubstituteEntryItemCommand(
        requestId: 'subst-1',
        entryId: entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026, 11, 10, 13),
        itemIndex: 0,
        replacement: replacement,
        amount: FoodAmount.exact(Exact.parse('100'), FoodUnit.g),
      ));
      expect(await PlanMealStateService(db).readForEntry(entry.id), isNotNull);

      await entries.deleteEntry(entry.id);
      expect(await PlanMealStateService(db).readForEntry(entry.id), isNull);
    } finally {
      await db.close();
    }
  });

  test('restore rejects dangling meal links and duplicate allocations', () async {
    final source = AppDatabase.memory();
    final restored = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(source, 'current', [meal]);
      final clock = FixedClock(DateTime.utc(2026, 11, 10, 12));
      final stamp = EventStamp(instant: DateTime.utc(2026, 11, 10, 12), offsetMinutes: 0);
      final entry = await PlanMealStateService(source).consumePlannedMeal(
        requestId: 'consume-4',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'entry'),
      );
      final archive = await ArchiveService(source).exportJson();
      await ArchiveService(restored).restoreJson(archive, confirmed: true);
      expect(await PlanMealStateService(restored).readForEntry(entry.id), isNotNull);

      final bad = Map<String, Object?>.from(jsonDecode(archive) as Map);
      final tables = bad['tables']! as Map;
      for (final row in tables['user_documents']! as List) {
        if (row['collection'] == 'plan-meal-state-v1') {
          final payload = Map<String, Object?>.from(jsonDecode(row['payload']! as String) as Map)
            ..['entryId'] = 'nope';
          row['payload'] = jsonEncode(payload);
        }
      }
      await expectLater(
        () => ArchiveService(restored).restoreJson(jsonEncode(bad), confirmed: true),
        throwsFormatException,
      );
      // Original intact.
      expect(await PlanMealStateService(restored).readForEntry(entry.id), isNotNull);
    } finally {
      await source.close();
      await restored.close();
    }
  });

  test('retry after plan edit replays; different portions conflict', () async {
    final db = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(db, 'current', [meal]);
      final clock = FixedClock(DateTime.utc(2026, 11, 10, 12));
      final stamp = EventStamp(instant: DateTime.utc(2026, 11, 10, 12), offsetMinutes: 0);
      final state = PlanMealStateService(db);
      final first = await state.consumePlannedMeal(
        requestId: 'consume-replay',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'entry'),
      );
      // Edit the plan (revision 2) — a retry must still replay, not STALE_PLAN.
      final service = PlanService(db, const SystemClock(), SequentialIdGenerator(), documentId: 'current');
      await service.save(
        requestId: 'edit-plan',
        expectedPlanRevision: 1,
        meals: [meal],
        metadata: _meta(meal.slot.date, 1, meal.slot.label),
      );
      final replay = await state.consumePlannedMeal(
        requestId: 'consume-replay',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'entry-retry'),
      );
      expect(replay.id, first.id);
      await expectLater(
        () => state.consumePlannedMeal(
          requestId: 'consume-replay',
          meal: meal,
          planDocumentId: 'current',
          expectedPlanRevision: 1,
          expectedStateRevision: 0,
          portions: Exact.parse('2'),
          stamp: stamp,
          offsetMinutes: 0,
          diaryDate: DiaryDate(2026, 11, 10),
          clock: clock,
          ids: SequentialIdGenerator(prefix: 'entry-retry2'),
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'REQUEST_ID_REUSED')),
      );
    } finally {
      await db.close();
    }
  });

  test('batch-backed consumption rejects differing portions exactly', () async {
    final db = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      await _seedRecipe(db, recipe);
      // Seed a gram batch with 600g finished weight for a 1-serving recipe.
      await LocalWorkspace(db).put(
        requestId: 'seed-batch-b',
        collection: 'batch',
        id: 'b',
        expectedRevision: 0,
        data: {
          'recipe': recipeSnapshot(recipe),
          'available': Exact.parse('600').toJson(),
          'finishedWeightG': Exact.parse('600').toJson(),
          'unit': 'g',
          'allocations': <Object?>[],
        },
      );
      final meal = PlannedMeal(
        const MealSlot('Dinner:0', '2026-11-10', 'Dinner'),
        recipe,
        Exact.one,
        batchUse: PlannedBatchUse('b', 1, 'alloc-1'),
      );
      // Reserve exact stock through the plan save path.
      final service = PlanService(db, const SystemClock(), SequentialIdGenerator(), documentId: 'current');
      await service.save(
        requestId: 'save-batch',
        expectedPlanRevision: 0,
        meals: [meal],
        metadata: _meta('2026-11-10', 1, 'Dinner'),
      );
      final clock = FixedClock(DateTime.utc(2026, 11, 10, 12));
      final stamp = EventStamp(instant: DateTime.utc(2026, 11, 10, 12), offsetMinutes: 0);
      final state = PlanMealStateService(db);
      await expectLater(
        () => state.consumePlannedMeal(
          requestId: 'consume-batch-2x',
          meal: meal,
          planDocumentId: 'current',
          expectedPlanRevision: 1,
          expectedStateRevision: 0,
          portions: Exact.parse('2'),
          stamp: stamp,
          offsetMinutes: 0,
          diaryDate: DiaryDate(2026, 11, 10),
          clock: clock,
          ids: SequentialIdGenerator(prefix: 'entry'),
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'BATCH_ALLOCATION_CONFLICT')),
      );
      expect(await DriftEntryRepository(db).findByRequestId('consume-batch-2x'), isNull);
      final batchAfter = await LocalWorkspace(db).read('batch', 'b');
      expect(batchAfter!.revision, 2);
      // Exact portions succeed and spend the reserved grams.
      final entry = await state.consumePlannedMeal(
        requestId: 'consume-batch-1x',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: stamp,
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 10),
        clock: clock,
        ids: SequentialIdGenerator(prefix: 'entry'),
      );
      expect(entry.channel, EntryChannel.plan);
      expect(entry.items.first.sourceSnapshot!['recipeName'], 'Recipe r1');
    } finally {
      await db.close();
    }
  });

  test('undo retry does not delete new feedback; reuse conflicts', () async {
    final db = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(db, 'current', [meal]);
      final state = PlanMealStateService(db);
      await state.skip(
        requestId: 'skip-a',
        planDocumentId: 'current',
        slotId: 'Dinner:0',
        date: DiaryDate(2026, 11, 10),
        recipe: recipe,
        plannedPortions: Exact.one,
        expectedRevision: 0,
      );
      await state.undo(
        requestId: 'undo-a',
        planDocumentId: 'current',
        slotId: 'Dinner:0',
        expectedRevision: 1,
      );
      expect(await state.read('current', 'Dinner:0'), isNull);
      // New feedback on the same slot under a different request.
      await state.skip(
        requestId: 'skip-b',
        planDocumentId: 'current',
        slotId: 'Dinner:0',
        date: DiaryDate(2026, 11, 10),
        recipe: recipe,
        plannedPortions: Exact.one,
        expectedRevision: 0,
      );
      // Retrying the old undo request is a no-op and keeps the new feedback.
      await state.undo(
        requestId: 'undo-a',
        planDocumentId: 'current',
        slotId: 'Dinner:0',
        expectedRevision: 1,
      );
      expect((await state.read('current', 'Dinner:0'))!.state, PlanMealState.skipped);
      // Reusing the undo id for another slot or revision conflicts.
      await expectLater(
        () => state.undo(
          requestId: 'undo-a',
          planDocumentId: 'current',
          slotId: 'Dinner:0',
          expectedRevision: 9,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'REQUEST_ID_REUSED')),
      );
    } finally {
      await db.close();
    }
  });

  test('required diaryDate is honored without assignedDiaryDate', () async {
    final db = AppDatabase.memory();
    try {
      final recipe = _recipe('r1');
      final meal = _meal('Dinner:0', '2026-11-10', recipe);
      await _savePlan(db, 'current', [meal]);
      final entry = await PlanMealStateService(db).consumePlannedMeal(
        requestId: 'consume-day',
        meal: meal,
        planDocumentId: 'current',
        expectedPlanRevision: 1,
        expectedStateRevision: 0,
        portions: Exact.one,
        stamp: EventStamp(instant: DateTime.utc(2026, 11, 10, 12), offsetMinutes: 0),
        offsetMinutes: 0,
        diaryDate: DiaryDate(2026, 11, 12),
        clock: FixedClock(DateTime.utc(2026, 11, 10, 12)),
        ids: SequentialIdGenerator(prefix: 'entry'),
      );
      expect(entry.diaryDate, DiaryDate(2026, 11, 12));
      expect(await DriftEntryRepository(db).entriesFor(DiaryDate(2026, 11, 12)), hasLength(1));
    } finally {
      await db.close();
    }
  });
}
