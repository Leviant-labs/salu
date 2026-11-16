import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

Food _food({
  String id = 'food',
  FoodUnit basisUnit = FoodUnit.g,
  String basisValue = '100',
  PortionDefinition portions = PortionDefinition.massOnly,
}) =>
    Food(
        id: id,
        name: id,
        per100g:
            NutrientProfile({NutrientKey.energyKcal: NutrientReported(100)}),
        source: FoodSource(dataset: 'test', datasetId: id),
        basisUnit: basisUnit,
        basisValue: basisValue,
        portions: portions);

void main() {
  test('a mass amount resolves against a gram basis', () {
    final resolved =
        resolveFoodAmount(_food(), FoodAmount('150', FoodUnit.g));
    expect(resolved.factor, Exact.parse('1.5'));
    expect(resolved.grams, 150);
  });

  test('a volume amount needs the food to declare a density', () {
    expect(
        () => resolveFoodAmount(_food(), FoodAmount('100', FoodUnit.ml)),
        throwsStateError);
  });

  test('a declared density converts volume to the exact mass', () {
    final resolved = resolveFoodAmount(
        _food(portions: const PortionDefinition(densityGramsPerMillilitre: 1.03)),
        FoodAmount('200', FoodUnit.ml));
    expect(resolved.factor, Exact.parse('2.06'));
    expect(resolved.grams, closeTo(206, 1e-9));
  });

  test('a piece amount without a portion weight stays a native amount', () {
    final resolved = resolveFoodAmount(
        _food(basisUnit: FoodUnit.item, basisValue: '1'),
        FoodAmount('2', FoodUnit.item, measureId: 'piece'));
    // The basis is per piece, so the factor is exact; no mass is invented.
    expect(resolved.factor, Exact.parse('2'));
    expect(resolved.grams, isNull);
  });

  test('a piece amount with a portion weight resolves its mass', () {
    final resolved = resolveFoodAmount(
        _food(portions: const PortionDefinition(portionGrams: 55)),
        FoodAmount('2', FoodUnit.item, measureId: 'piece'));
    expect(resolved.factor, Exact.parse('1.1'));
    expect(resolved.grams, 110);
  });

  test('a substitution command requires a positive amount and item index', () {
    SubstituteEntryItemCommand command({int itemIndex = 0, String amount = '1'}) =>
        SubstituteEntryItemCommand(
            requestId: 'request',
            entryId: 'entry',
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: itemIndex,
            replacement: _food(),
            amount: FoodAmount(amount, FoodUnit.g));
    expect(() => command(), returnsNormally);
    expect(() => command(itemIndex: -1), throwsArgumentError);
    expect(() => command(amount: '0'), throwsArgumentError);
    expect(
        () => SubstituteEntryItemCommand(
            requestId: '',
            entryId: 'entry',
            expectedRevision: 1,
            recordedAt: DateTime.utc(2026),
            itemIndex: 0,
            replacement: _food(),
            amount: FoodAmount('1', FoodUnit.g)),
        throwsArgumentError);
  });
}
