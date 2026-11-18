import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late DriftFoodRepository foods;

  setUp(() {
    db = AppDatabase.memory();
    foods = DriftFoodRepository(db);
  });
  tearDown(() => db.close());

  test('installation adds missing rows once, even alongside the dev seed',
      () async {
    expect(await seedDevelopmentCatalogue(db), developmentCatalogue().length);
    expect(await seedDevelopmentCatalogue(db), 0);
    await foods.replaceCatalogueBatch([
      _food('bundled-fdc-171688', 'Retained apple record'),
    ]);

    expect(await installBundledCatalogue(db), 77);
    expect(await installBundledCatalogue(db), 0);
    expect((await foods.findById('dev-apple'))?.source.dataset, 'dev-fixture');
    expect((await foods.findById('bundled-fdc-171688'))?.name,
        'Retained apple record');
    expect(await foods.search('maçã'), isEmpty);
    expect(await foods.search(' ', limit: 1), hasLength(1));
  });

  test('source, derivation, preparation and unknowns survive SQLite', () async {
    expect(await installBundledCatalogue(db), 78);
    final apple = (await foods.findById('bundled-fdc-171688'))!;
    expect(
      apple.source,
      const FoodSource(
        dataset: 'usda-fdc-sr-legacy',
        datasetId: '171688',
        datasetVersion: '2018-04',
        licence: 'CC0-1.0',
      ),
    );
    expect(apple.quality, DataQuality.imported);
    expect(apple.preparation, Preparation.raw);
    expect(apple.allergens, isNull);
    expect(apple.dietaryTags, isEmpty);
    expect(apple.portions.portionGrams, isNull);
    expect(apple.portions.densityGramsPerMillilitre, isNull);
    expect(apple.per100g[NutrientKey.proteinG], NutrientMeasured(0.26));
    expect(
      apple.per100g[NutrientKey.energyKcal],
      NutrientEstimated(52, basis: 'usda-fdc-sr-legacy:NC'),
    );

    final falafel = (await foods.search('faláfel')).single;
    expect(falafel.isComposite, isTrue);
    expect(falafel.preparation, Preparation.cooked);
    expect(falafel.per100g[NutrientKey.fiberG], isA<NutrientUnknown>());
    expect(falafel.per100g[NutrientKey.carbohydrateG].numericValue, 31.84);

    final saltCod = (await foods.search('bacalhau', limit: 1)).single;
    expect(saltCod.source.datasetId, '174190');
    expect(saltCod.per100g[NutrientKey.sodiumMg].numericValue, 7027);
    expect(
      saltCod.per100g[NutrientKey.fiberG],
      NutrientEstimated(0, basis: 'usda-fdc-sr-legacy:Z'),
    );
  });

  test('aliases are offline, accent-insensitive and tied to installed rows',
      () async {
    expect(await foods.search('grão-de-bico'), isEmpty);
    await installBundledCatalogue(db);

    for (final query in [
      'grão-de-bico',
      ' GRAO   DE BICO ',
      'bico gra\u0303o'
    ]) {
      expect((await foods.search(query, limit: 1)).single.source.datasetId,
          '173757');
    }
    expect(
        (await foods.search('PAO INTEGRAL')).single.source.datasetId, '172688');
    expect((await foods.search('omelette')), isEmpty);
    expect(await foods.search('%_'), isEmpty);
    expect(await foods.search('rice', limit: 0), isEmpty);
  });

  test('ranks before limiting and breaks equal matches by stable ID', () async {
    await installBundledCatalogue(db);
    await foods.replaceCatalogueBatch([
      _food('a-first', 'Mixed grains with rice'),
      _food('b-name', 'Rice bowl'),
      _food('c-name', 'Rice bowl'),
      _food('z-exact', 'Ríce'),
      _food('z-prefix', 'Grão de bico, raw'),
    ]);

    final ranked = await foods.search('rice', limit: 3);
    expect(ranked.map((food) => food.id), ['z-exact', 'b-name', 'c-name']);
    expect((await foods.search('grao de bico', limit: 1)).single.id,
        'bundled-fdc-173757');
  });

  test('indexed search can find imported matches beyond the former name window',
      () async {
    await installBundledCatalogue(db);
    await foods.insertMissingCatalogueBatch([
      for (var i = 0; i < 520; i++)
        _food('a-${i.toString().padLeft(3, '0')}', 'Other food'),
      _food('z-import', 'Unique Yuzu'),
    ]);

    expect((await foods.search('ameijoas')).single.id, 'bundled-fdc-171975');
    expect((await foods.search('yuzu')).single.id, 'z-import');
  });
}

Food _food(String id, String name) => Food(
      id: id,
      name: name,
      source: FoodSource(dataset: 'test', datasetId: id),
      per100g: const NutrientProfile.empty(),
    );
