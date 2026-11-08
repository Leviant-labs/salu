import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

NutrientObservation observation(
        String id, String unit, String definition, String amount,
        {String basis = '100'}) =>
    NutrientObservation(
        nutrient: NutrientIdentity(id, unit, definition),
        basis: FoodAmount(basis, FoodUnit.g),
        qualifier: ObservationQualifier.reported,
        sourceId: 'label',
        sourceVersion: '1',
        origin: 'label',
        amount: amount);
void main() {
  test('GTIN check digits validate without claiming product registration', () {
    for (final value in [
      '96385074',
      '036000291452',
      '4006381333931',
      '10012345000017'
    ]) {
      expect(ProductBarcode(value).value, value);
    }
    expect(() => ProductBarcode('4006381333932'), throwsFormatException);
    expect(() => ProductBarcode('123'), throwsFormatException);
  });
  test('supplied energy values stay independent; only absent units derive', () {
    final kcal = observation('energy_kcal', 'kcal', 'declared_energy', '100');
    final kj = observation('energy_kj', 'kJ', 'declared_energy', '420');
    final supplied = completeEnergyUnits([kcal, kj]);
    expect(supplied[1].amount, Exact.parse('420'));
    final derived = completeEnergyUnits([kcal]);
    expect(derived.last.amount, Exact.parse('418.4'));
    expect(derived.last.origin, contains('unit-conversion'));
  });
  test(
      'US and unspecified carbohydrate never become EU available; basis scales exactly',
      () {
    for (final definition in [
      'us_total_including_fibre',
      'unspecified',
      'carbohydrate_g'
    ]) {
      final profile = projectObservations(
          [observation('carbohydrate_g', 'g', definition, '10')],
          basis: FoodAmount('100', FoodUnit.g));
      expect(profile[NutrientKey.carbohydrateG], isA<NutrientUnknown>());
    }
    final profile = projectObservations([
      observation('carbohydrate_g', 'g', 'eu_available_including_polyols', '10',
          basis: '50')
    ], basis: FoodAmount('100', FoodUnit.g));
    expect(profile[NutrientKey.carbohydrateG].numericValue, 20);
  });
}
