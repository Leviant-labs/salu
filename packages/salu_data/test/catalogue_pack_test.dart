import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

List<int> _pack(String edition, List<Map<String, Object?>> rows) =>
    utf8.encode(jsonEncode({
      'format': 1,
      'dataset': 'test-region',
      'edition': edition,
      'attribution': 'Example fixture',
      'licence': 'CC0',
      'foods': rows,
    }));

void main() {
  test('activate a validated edition and its barcodes atomically', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final foods = DriftFoodRepository(db);
    final first = {
      'name': 'Packaged food',
      'sourceId': 'first',
      'barcode': '0001234567890',
      'per100g': {'energy_kcal': 20}
    };
    final row = {
      'name': 'Second food',
      'sourceId': 'second',
      'barcode': '0001234567891',
      'per100g': {'energy_kcal': 80, 'protein_g': null}
    };
    await CataloguePack.parse(_pack('1', [first])).install(foods);
    expect((await foods.findByBarcode('0001234567890')).single.name,
        'Packaged food');
    expect(() => CataloguePack.parse(_pack('bad', [first, first])),
        throwsFormatException);
    expect(
        (await foods.findByBarcode('0001234567890'))
            .single
            .source
            .datasetVersion,
        '1');
    await CataloguePack.parse(_pack('2', [row])).install(foods);
    expect(await foods.findByBarcode('0001234567890'), isEmpty);
    final current = (await foods.findByBarcode('0001234567891')).single;
    expect(current.per100g[NutrientKey.energyKcal], NutrientReported(80));
    expect(current.per100g[NutrientKey.proteinG], NutrientValue.unknown);
    expect((await foods.search('Second')).single.id, current.id);
  });
}
