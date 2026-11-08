import 'nutrients.dart';
import 'nutrition_contract.dart';

/// Only unit conversion is derived. Supplied kcal and kJ are never reconciled
/// or overwritten, and no amount is invented for trace/unknown observations.
List<NutrientObservation> completeEnergyUnits(List<NutrientObservation> input) {
  final result = [...input];
  final kcal = input
      .where((o) => o.nutrient.id == 'energy_kcal' && o.nutrient.unit == 'kcal')
      .toList();
  final kj = input
      .where((o) => o.nutrient.id == 'energy_kj' && o.nutrient.unit == 'kJ')
      .toList();
  NutrientObservation convert(
          NutrientObservation source, String id, String unit, Exact factor) =>
      NutrientObservation(
          nutrient: NutrientIdentity(id, unit, source.nutrient.definition,
              scope: source.nutrient.scope),
          basis: source.basis,
          qualifier: source.qualifier,
          sourceId: source.sourceId,
          sourceVersion: source.sourceVersion,
          origin: 'unit-conversion:kJ=4.184*kcal:v1;${source.origin}',
          exactAmount: source.amount! * factor);
  if (kcal.length == 1 && kj.isEmpty && kcal.single.amount != null) {
    result.add(convert(kcal.single, 'energy_kj', 'kJ', Exact.parse('4.184')));
  }
  if (kj.length == 1 && kcal.isEmpty && kj.single.amount != null) {
    result.add(convert(
        kj.single, 'energy_kcal', 'kcal', Exact.one / Exact.parse('4.184')));
  }
  return List.unmodifiable(result);
}

/// Legacy dashboard projection is intentionally restrictive. US total or
/// unspecified carbohydrate never becomes EU available carbohydrate. Full
/// observations (including unsupported definitions/forms) stay in the source.
NutrientProfile projectObservations(List<NutrientObservation> input,
    {required FoodAmount basis}) {
  final values = <NutrientKey, NutrientValue>{};
  for (final key in NutrientKey.values) {
    final matches = input
        .where((o) =>
            o.nutrient.id == key.wire &&
            o.nutrient.unit == key.unit &&
            o.nutrient.scope == 'food' &&
            o.basis.unit == basis.unit &&
            o.basis.measureId == basis.measureId &&
            ((key != NutrientKey.carbohydrateG &&
                    o.nutrient.definition == key.wire) ||
                (key == NutrientKey.carbohydrateG &&
                    o.nutrient.definition ==
                        'eu_available_including_polyols') ||
                ((key == NutrientKey.energyKcal ||
                        key == NutrientKey.energyKj) &&
                    o.nutrient.definition == 'declared_energy')))
        .toList();
    if (matches.length != 1) continue;
    final o = matches.single;
    final ratio = basis.value / o.basis.value;
    values[key] = switch (o.qualifier) {
      ObservationQualifier.reported ||
      ObservationQualifier.reportedZero =>
        NutrientReported.exact(o.amount! * ratio),
      ObservationQualifier.estimated =>
        NutrientEstimated.exact(o.amount! * ratio, basis: o.origin),
      ObservationQualifier.trace => const NutrientTrace(),
      _ => const NutrientUnknown(),
    };
  }
  return NutrientProfile(values);
}
