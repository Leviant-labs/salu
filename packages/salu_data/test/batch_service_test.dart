import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('stock allocation and intake are atomic and idempotent', () async {
    final db = AppDatabase.memory();
    try {
      final r = RecipeVersion(
          id: 'r',
          revision: 1,
          name: 'Protein recipe',
          ingredients: [
            RecipeIngredient(
                Food(
                    id: 'f',
                    name: 'Ingredient',
                    per100g: NutrientProfile(
                        {NutrientKey.proteinG: NutrientReported(60)}),
                    source:
                        const FoodSource(dataset: 'fixture', datasetId: '1')),
                Exact.parse('100'))
          ],
          servings: Exact.parse('3'),
          minutes: 10);
      final w = LocalWorkspace(db);
      await w.put(
          requestId: 'create-batch',
          collection: 'batch',
          id: 'b',
          expectedRevision: 0,
          data: {
            'recipe': recipeSnapshot(r),
            'available': Exact.parse('600').toJson(),
            'finishedWeightG': Exact.parse('600').toJson(),
            'unit': 'g',
            'allocations': <Object?>[]
          });
      final service =
          BatchService(db, const SystemClock(), SequentialIdGenerator());
      final first = await service.consume(
          requestId: 'consume',
          batchId: 'b',
          expectedRevision: 1,
          grams: Exact.parse('200'),
          offsetMinutes: 0,
          confirmed: true);
      final retry = await service.consume(
          requestId: 'consume',
          batchId: 'b',
          expectedRevision: 1,
          grams: Exact.parse('200'),
          offsetMinutes: 0,
          confirmed: true);
      expect(retry.id, first.id);
      expect(first.nutrientSum(NutrientKey.proteinG).value, 20);
      expect((await w.read('batch', 'b'))!.data['allocations'] as List,
          hasLength(1));
      await expectLater(
          service.consume(
              requestId: 'too-much',
              batchId: 'b',
              expectedRevision: 2,
              grams: Exact.parse('500'),
              offsetMinutes: 0,
              confirmed: true),
          throwsStateError);
      expect(
          await DriftEntryRepository(db).findByRequestId('too-much'), isNull);
      expect((await w.read('batch', 'b'))!.revision, 2);

      final entries = DriftEntryRepository(db);
      await entries.revise(ReviseEntryCommand(
          requestId: 'correct',
          entryId: first.id,
          expectedRevision: 1,
          recordedAt: DateTime.utc(2026),
          multiplier: Exact.parse('2')));
      expect(
          (await entries.findByRequestId('consume'))!
              .nutrientSum(NutrientKey.proteinG)
              .value,
          40);
      expect((await w.read('batch', 'b'))!.revision, 3);
      await expectLater(
          entries.revise(ReviseEntryCommand(
              requestId: 'over-correct',
              entryId: first.id,
              expectedRevision: 2,
              recordedAt: DateTime.utc(2026),
              multiplier: Exact.parse('2'))),
          throwsStateError);
      expect((await entries.findByRequestId('consume'))!.revision, 2);
      expect((await w.read('batch', 'b'))!.revision, 3);
    } finally {
      await db.close();
    }
  });
  test('reserved stock is counted once when confirmed and remains correctable',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final recipe = RecipeVersion(
        id: 'r',
        revision: 1,
        name: 'Soup',
        servings: Exact.parse('3'),
        minutes: 10,
        ingredients: [
          RecipeIngredient(
              Food(
                  id: 'f',
                  name: 'Ingredient',
                  per100g: NutrientProfile(
                      {NutrientKey.proteinG: NutrientReported(60)}),
                  source: const FoodSource(dataset: 'fixture', datasetId: '1')),
              Exact.parse('100'))
        ]);
    final workspace = LocalWorkspace(db);
    await workspace.put(
        requestId: 'create',
        collection: 'batch',
        id: 'b',
        expectedRevision: 0,
        data: {
          'recipe': recipeSnapshot(recipe),
          'available': Exact.parse('600').toJson(),
          'finishedWeightG': Exact.parse('600').toJson(),
          'unit': 'g',
          'allocations': <Object?>[]
        });
    final service =
        BatchService(db, const SystemClock(), SequentialIdGenerator());
    expect(
        await service.reserve(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 1,
            grams: Exact.parse('400')),
        2);
    expect(
        await service.reserve(
            requestId: 'reserve-1',
            batchId: 'b',
            allocationId: 'plan-1',
            expectedRevision: 1,
            grams: Exact.parse('400')),
        2);
    expect(await db.select(db.logEntries).get(), isEmpty);
    await expectLater(
        service.reserve(
            requestId: 'reserve-2',
            batchId: 'b',
            allocationId: 'plan-2',
            expectedRevision: 2,
            grams: Exact.parse('300')),
        throwsStateError);
    await expectLater(
        service.consume(
            requestId: 'bad',
            batchId: 'b',
            expectedRevision: 2,
            grams: Exact.parse('300'),
            offsetMinutes: 0,
            confirmed: true,
            reservedAllocationId: 'plan-1'),
        throwsStateError);
    expect((await workspace.read('batch', 'b'))!.revision, 2);
    final entry = await service.consume(
        requestId: 'meal',
        batchId: 'b',
        expectedRevision: 2,
        grams: Exact.parse('400'),
        offsetMinutes: 0,
        confirmed: true,
        reservedAllocationId: 'plan-1');
    expect(entry.nutrientSum(NutrientKey.proteinG).value, 40);
    final allocations =
        (await workspace.read('batch', 'b'))!.data['allocations']! as List;
    expect(allocations, hasLength(1));
    expect((allocations.single as Map)['id'], 'meal');
    expect((allocations.single as Map)['status'], 'consumed');
    await DriftEntryRepository(db).revise(ReviseEntryCommand(
        requestId: 'reduce',
        entryId: entry.id,
        expectedRevision: 1,
        recordedAt: DateTime.utc(2026),
        multiplier: Exact.parse('0.5')));
    expect((await workspace.read('batch', 'b'))!.revision, 4);
    await expectLater(
        service.releaseReservation(
            requestId: 'release-consumed',
            batchId: 'b',
            allocationId: 'meal',
            expectedRevision: 4),
        throwsStateError);
    expect(
        await service.reserve(
            requestId: 'reserve-3',
            batchId: 'b',
            allocationId: 'plan-3',
            expectedRevision: 4,
            grams: Exact.parse('100')),
        5);
    expect(
        await service.releaseReservation(
            requestId: 'release-3',
            batchId: 'b',
            allocationId: 'plan-3',
            expectedRevision: 5),
        6);
    expect(
        await service.releaseReservation(
            requestId: 'release-3',
            batchId: 'b',
            allocationId: 'plan-3',
            expectedRevision: 5),
        6);
    expect(((await workspace.read('batch', 'b'))!.data['allocations'] as List),
        hasLength(1));
  });
}
