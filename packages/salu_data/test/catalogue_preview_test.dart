import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

Food sourceFood(String id, String version, {String dataset = 'test'}) => Food(
    id: id,
    name: id,
    per100g: const NutrientProfile.empty(),
    source: FoodSource(
        dataset: dataset,
        datasetId: id,
        datasetVersion: version,
        licence: 'fixture-only'));

CataloguePack pack(String version, List<Food> foods) => CataloguePack(
    dataset: 'test',
    version: version,
    licence: 'fixture-only',
    attribution: 'Fixture only',
    foods: foods);

void main() {
  test(
      'preview describes additions, replacements, retirements and conflicts without mutation',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final repository = DriftFoodRepository(db);
    final installer = CatalogueInstallService(db, approvedReviews: [
      const DatasetReview(
          dataset: 'test',
          version: '1',
          licence: 'fixture-only',
          reviewId: 'review-1'),
    ]);
    await installer.activate(
        pack('1',
            [sourceFood('test:keep', '1'), sourceFood('test:retired', '1')]),
        confirmed: true);
    await repository.replaceCatalogueBatch(
        [sourceFood('test:conflict', '1', dataset: 'another-source')]);
    final proposed = pack('2', [
      sourceFood('test:keep', '2'),
      sourceFood('test:new', '2'),
      sourceFood('test:conflict', '2')
    ]);
    final before = await ArchiveService(db).exportJson();
    final preview = await installer.preview(proposed);
    expect(preview.installedVersion, '1');
    expect(preview.addedIds, ['test:new']);
    expect(preview.replacedIds, ['test:keep']);
    expect(preview.retiredIds, ['test:retired']);
    expect(preview.conflictingIds, ['test:conflict']);
    expect(await ArchiveService(db).exportJson(), before);
    expect(() => preview.retiredIds.add('test:other'), throwsUnsupportedError);
    // A preview does not grant the source or licence review required to install.
    await expectLater(
        installer.activate(proposed, confirmed: true), throwsStateError);
    expect(await ArchiveService(db).exportJson(), before);
  });

  test('preview checks identifiers beyond the first database lookup', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch(
        [sourceFood('test:0500', '1', dataset: 'another-source')]);
    final preview = await CatalogueInstallService(db).preview(pack('1', [
      for (var i = 0; i <= 500; i++)
        sourceFood('test:${i.toString().padLeft(4, '0')}', '1')
    ]));
    expect(preview.installedVersion, isNull);
    expect(preview.addedIds, hasLength(500));
    expect(preview.conflictingIds, ['test:0500']);
    expect(preview.replacedIds, isEmpty);
  });
}
