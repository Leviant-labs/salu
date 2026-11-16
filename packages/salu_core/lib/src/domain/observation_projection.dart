import 'nutrients.dart';
import 'nutrition_contract.dart';

/// The declared `1 kcal = 4.184 kJ` conversion recorded on every derived energy
/// observation. It is a unit relation, not a physiological measurement.
final Exact _kjPerKcal = Exact.parse('4.184');

/// A definition that only spells the unit of declared energy is still the same
/// quantity as `declared_energy`. Sharing one slot keeps a supplied pair from
/// being converted again, while a genuinely different definition (for example
/// an Atwater figure) keeps its own slot.
String _energyQuantity(String definition) {
  if (definition == NutrientKey.energyKcal.wire ||
      definition == NutrientKey.energyKj.wire) {
    return NutrientDefinitions.declaredEnergy;
  }
  return definition;
}

/// Converts a supplied interval into the derived observation's unit.
///
/// A unit conversion is a positive linear map, so scaling both bounds by the
/// same exact factor keeps the same claim, ordering, inclusion flags and
/// documented scope/method; nothing is rounded. A non-positive factor cannot
/// preserve an ordered nonnegative interval, so the metadata is omitted instead
/// of being reversed or reinterpreted.
SourceInterval? _convertedInterval(SourceInterval? interval, Exact factor) {
  if (interval == null) return null;
  if (!factor.positive) return null;
  return SourceInterval(
      lower: interval.lower == null ? null : interval.lower! * factor,
      upper: interval.upper == null ? null : interval.upper! * factor,
      lowerInclusive: interval.lowerInclusive,
      upperInclusive: interval.upperInclusive,
      scope: interval.scope,
      method: interval.method);
}

/// Only unit conversion is derived. Supplied kcal and kJ are never reconciled
/// or overwritten, and no amount is invented for trace/unknown observations.
///
/// Derivation is per declared-energy quantity (definition family and scope): a
/// supplied value of the other unit is never replaced, a second candidate would
/// make the result depend on list order and is therefore skipped, and an
/// observation without a numeric amount derives nothing.
List<NutrientObservation> completeEnergyUnits(List<NutrientObservation> input) {
  final result = [...input];
  final kcalByIdentity = <(String, String), List<NutrientObservation>>{};
  final kjByIdentity = <(String, String), List<NutrientObservation>>{};
  for (final o in input) {
    final slot = (_energyQuantity(o.nutrient.definition), o.nutrient.scope);
    if (o.nutrient.id == NutrientKey.energyKcal.wire &&
        o.nutrient.unit == NutrientKey.energyKcal.unit) {
      kcalByIdentity.putIfAbsent(slot, () => <NutrientObservation>[]).add(o);
    } else if (o.nutrient.id == NutrientKey.energyKj.wire &&
        o.nutrient.unit == NutrientKey.energyKj.unit) {
      kjByIdentity.putIfAbsent(slot, () => <NutrientObservation>[]).add(o);
    }
  }
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
          exactAmount: source.amount! * factor,
          suppliedInterval:
              _convertedInterval(source.suppliedInterval, factor),
          evidenceDate: source.evidenceDate);
  for (final entry in kcalByIdentity.entries) {
    if (entry.value.length != 1 ||
        kjByIdentity.containsKey(entry.key) ||
        entry.value.single.amount == null) {
      continue;
    }
    result.add(
        convert(entry.value.single, NutrientKey.energyKj.wire, 'kJ', _kjPerKcal));
  }
  for (final entry in kjByIdentity.entries) {
    if (entry.value.length != 1 ||
        kcalByIdentity.containsKey(entry.key) ||
        entry.value.single.amount == null) {
      continue;
    }
    result.add(convert(entry.value.single, NutrientKey.energyKcal.wire, 'kcal',
        Exact.one / _kjPerKcal));
  }
  return List.unmodifiable(result);
}

/// The legacy projection reads at most one definition per dashboard key, so an
/// unsupported definition leaves that key unknown instead of being coerced.
bool _definitionMatches(NutrientKey key, NutrientObservation observation) {
  final definition = observation.nutrient.definition;
  if (key == NutrientKey.carbohydrateG) {
    return definition == NutrientDefinitions.euAvailableCarbohydrate;
  }
  if (key == NutrientKey.vitaminAUg) {
    // Retinol equivalents include the provitamin A carotenoids, so a source
    // that states that definition is comparable; the key's own wire id stays
    // accepted for records entered without a more specific definition.
    return definition == NutrientDefinitions.retinolEquivalents ||
        definition == key.wire;
  }
  if (key == NutrientKey.energyKcal || key == NutrientKey.energyKj) {
    // Declared energy keeps its source definition; the app spells it with the
    // key's wire id and importers use the shared definition id.
    if (definition == NutrientDefinitions.declaredEnergy ||
        definition == key.wire) {
      return true;
    }
    // A derived unit conversion keeps the source definition, which names the
    // other unit. It is the same declared energy only because its recorded
    // origin says the value was converted.
    if (definition == NutrientKey.energyKcal.wire ||
        definition == NutrientKey.energyKj.wire) {
      return observation.origin.startsWith('unit-conversion:');
    }
    return false;
  }
  return definition == key.wire;
}

/// Legacy dashboard projection is intentionally restrictive. US total or
/// unspecified carbohydrate never becomes EU available carbohydrate. Full
/// observations (including unsupported definitions/forms) stay in the source.
NutrientProfile projectObservations(List<NutrientObservation> input,
    {required FoodAmount basis}) {
  if (!basis.value.positive) {
    throw ArgumentError('Projection basis must be positive');
  }
  final values = <NutrientKey, NutrientValue>{};
  for (final key in NutrientKey.values) {
    final matches = input
        .where((o) =>
            o.nutrient.id == key.wire &&
            o.nutrient.unit == key.unit &&
            o.nutrient.scope == 'food' &&
            o.basis.unit == basis.unit &&
            o.basis.measureId == basis.measureId &&
            _definitionMatches(key, o))
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

/// Components the derived-energy check recognises. Amounts are grams; the
/// factor set supplies each component's kcal/g contribution.
enum EnergyComponent {
  protein,
  fat,
  carbohydrate,
  fibre,
  polyols,
  erythritol,
  alcohol,
  organicAcids,
}

/// A versioned set of energy factors.
///
/// The identifier travels with every derived figure so a validation warning can
/// name the rule that produced it, and callers can distinguish a rule revision
/// from a data change.
final class EnergyFactorSet {
  const EnergyFactorSet._({required this.id, required this.factors});

  /// EU declared-energy factors: protein 4, fat 9, carbohydrate other than
  /// polyols 4, fibre 2, polyols 2.4, erythritol 0, alcohol 7 and organic acids
  /// 3 kcal/g.
  static const EnergyFactorSet euDeclared = EnergyFactorSet._(
      id: 'eu-declared-energy-v1',
      factors: {
        EnergyComponent.protein: '4',
        EnergyComponent.fat: '9',
        EnergyComponent.carbohydrate: '4',
        EnergyComponent.fibre: '2',
        EnergyComponent.polyols: '2.4',
        EnergyComponent.erythritol: '0',
        EnergyComponent.alcohol: '7',
        EnergyComponent.organicAcids: '3',
      });

  /// Components a derived figure needs before an agreement check is meaningful.
  ///
  /// Fibre and polyols are required because both supported carbohydrate
  /// definitions overlap with them; applying a factor without knowing the
  /// overlap would silently miscount. Erythritol, alcohol and organic acids are
  /// applied only when declared and are otherwise disclosed, never assumed zero.
  static const Set<EnergyComponent> requiredComponents = {
    EnergyComponent.protein,
    EnergyComponent.fat,
    EnergyComponent.carbohydrate,
    EnergyComponent.fibre,
    EnergyComponent.polyols,
  };

  final String id;
  final Map<EnergyComponent, String> factors;

  Exact? factorFor(EnergyComponent component) {
    final value = factors[component];
    return value == null ? null : Exact.parse(value);
  }
}

/// Observation ids the derived-energy check reads.
///
/// These are code constants, not a bundled dataset: an import adapter must map a
/// source's own names onto them. An unrecognised spelling is reported as missing
/// rather than guessed, and two spellings for one component are reported as
/// ambiguous rather than summed.
const Map<EnergyComponent, Set<String>> _energyIds = {
  EnergyComponent.protein: {'protein_g', 'protein'},
  EnergyComponent.fat: {'fat_g', 'fat'},
  EnergyComponent.carbohydrate: {'carbohydrate_g', 'carbohydrate'},
  EnergyComponent.fibre: {'fiber_g', 'fibre_g', 'fiber', 'fibre'},
  EnergyComponent.polyols: {'polyols_g', 'polyols'},
  EnergyComponent.erythritol: {'erythritol_g', 'erythritol'},
  EnergyComponent.alcohol: {'alcohol_g', 'alcohol'},
  EnergyComponent.organicAcids: {'organic_acids_g', 'organic_acids'},
};

/// Result of deriving energy from macronutrient observations.
sealed class EnergyDerivation {
  const EnergyDerivation({required this.ruleId});

  /// Identifier of the factor set that produced these numbers.
  final String ruleId;
}

/// A complete derived figure, expressed per [basis].
final class DerivedEnergy extends EnergyDerivation {
  const DerivedEnergy(
      {required super.ruleId,
      required this.kcal,
      required this.basis,
      required this.contributions,
      required this.notDeclared});

  /// Derived energy in kcal for [basis], from declared components only.
  final Exact kcal;

  /// Quantity the derived figure is expressed against.
  final FoodAmount basis;

  /// kcal contributed by each component on [basis], including the overlap
  /// corrections applied to carbohydrate.
  final Map<EnergyComponent, Exact> contributions;

  /// Optional components that were not declared, so their factor was not
  /// applied. They are disclosed rather than assumed to be zero.
  final List<EnergyComponent> notDeclared;
}

/// A derived figure cannot be computed without inventing or guessing data.
final class EnergyNotDerived extends EnergyDerivation {
  const EnergyNotDerived(
      {required super.ruleId, required this.reasons, required this.missing});

  /// Reasons in component order: an undeclared component, an ambiguous
  /// duplicate, an unsupported unit or an unsupported carbohydrate definition.
  final List<String> reasons;

  /// Components without a usable observation.
  final List<EnergyComponent> missing;
}

/// Derives declared energy in kcal per [basis] using definition-specific
/// factors, subtracting the components a carbohydrate definition already
/// includes before applying the 4 kcal/g factor.
///
/// This is a validation aid, not a correction: it never rewrites a supplied
/// energy observation. A caller compares the result with
/// [assessEnergyAgreement] and surfaces a provenance-aware warning on
/// disagreement. Missing or ambiguous inputs produce [EnergyNotDerived] rather
/// than a partial number.
EnergyDerivation deriveEnergyKcal(
    {required List<NutrientObservation> observations,
    required FoodAmount basis,
    EnergyFactorSet factors = EnergyFactorSet.euDeclared,
    String scope = 'food'}) {
  if (!basis.value.positive) {
    throw ArgumentError('Derivation basis must be positive');
  }
  final grams = <EnergyComponent, Exact>{};
  final declared = <EnergyComponent, NutrientObservation>{};
  final missing = <EnergyComponent>[];
  final reasons = <String>[];
  for (final component in EnergyComponent.values) {
    final ids = _energyIds[component]!;
    final candidates = observations
        .where((o) =>
            o.nutrient.scope == scope && ids.contains(o.nutrient.id))
        .toList();
    if (candidates.isEmpty) {
      missing.add(component);
      if (EnergyFactorSet.requiredComponents.contains(component)) {
        reasons.add('${component.name} not declared');
      }
      continue;
    }
    if (candidates.length > 1) {
      missing.add(component);
      reasons.add('${component.name} has ${candidates.length} identities');
      continue;
    }
    final o = candidates.single;
    if (o.amount == null) {
      missing.add(component);
      reasons.add('${component.name} has no numeric amount');
      continue;
    }
    final unitFactor = nutrientUnitFactor(o.nutrient.unit, 'g');
    if (unitFactor == null) {
      missing.add(component);
      reasons.add('${component.name} unit ${o.nutrient.unit} is not a mass');
      continue;
    }
    if (!sameDimension(o.basis, basis)) {
      missing.add(component);
      reasons.add('${component.name} basis is not comparable');
      continue;
    }
    declared[component] = o;
    grams[component] = o.amount! * unitFactor * (basis.value / o.basis.value);
  }
  // Any reason means a factor-bearing component is absent or unusable: a
  // partial number would miscount the declared vector, so nothing is derived.
  if (reasons.isNotEmpty) {
    return EnergyNotDerived(
        ruleId: factors.id,
        reasons: List.unmodifiable(reasons),
        missing: List.unmodifiable(missing));
  }
  final carbohydrate = declared[EnergyComponent.carbohydrate]!;
  final carbGrams = grams[EnergyComponent.carbohydrate]!;
  final fibre = grams[EnergyComponent.fibre]!;
  final polyols = grams[EnergyComponent.polyols]!;
  // The carbohydrate definition decides which components its number already
  // includes, so those overlaps are removed before the 4 kcal/g factor.
  final carbOtherThanPolyols = switch (carbohydrate.nutrient.definition) {
    // EU available carbohydrate includes polyols and excludes fibre.
    NutrientDefinitions.euAvailableCarbohydrate => carbGrams - polyols,
    // US total carbohydrate includes both fibre and polyols.
    NutrientDefinitions.usTotalCarbohydrate => carbGrams - fibre - polyols,
    _ => null,
  };
  if (carbOtherThanPolyols == null) {
    return EnergyNotDerived(
        ruleId: factors.id,
        reasons: List.unmodifiable([
          ...reasons,
          'carbohydrate definition '
              '${carbohydrate.nutrient.definition} is not supported'
        ]),
        missing: List.unmodifiable(missing));
  }
  if (carbOtherThanPolyols.compareTo(Exact.zero) < 0) {
    return EnergyNotDerived(
        ruleId: factors.id,
        reasons: List.unmodifiable([
          ...reasons,
          'carbohydrate is smaller than its declared overlap components'
        ]),
        missing: List.unmodifiable(missing));
  }
  Exact factorOf(EnergyComponent component) {
    final factor = factors.factorFor(component);
    if (factor == null) throw StateError('Missing factor for ${component.name}');
    return factor;
  }

  final contributions = <EnergyComponent, Exact>{
    EnergyComponent.protein:
        grams[EnergyComponent.protein]! * factorOf(EnergyComponent.protein),
    EnergyComponent.fat:
        grams[EnergyComponent.fat]! * factorOf(EnergyComponent.fat),
    EnergyComponent.carbohydrate:
        carbOtherThanPolyols * factorOf(EnergyComponent.carbohydrate),
    EnergyComponent.fibre: fibre * factorOf(EnergyComponent.fibre),
    EnergyComponent.polyols: polyols * factorOf(EnergyComponent.polyols),
  };
  for (final component in const [
    EnergyComponent.erythritol,
    EnergyComponent.alcohol,
    EnergyComponent.organicAcids,
  ]) {
    final amount = grams[component];
    if (amount == null) continue;
    contributions[component] = amount * factorOf(component);
  }
  var kcal = Exact.zero;
  for (final value in contributions.values) {
    kcal = kcal + value;
  }
  return DerivedEnergy(
      ruleId: factors.id,
      kcal: kcal,
      basis: basis,
      contributions: Map.unmodifiable(contributions),
      notDeclared: List.unmodifiable([
        for (final component in EnergyComponent.values)
          if (!declared.containsKey(component)) component
      ]));
}

/// An explicit, versioned import rule for comparing derived energy with a
/// supplied value.
///
/// There is no built-in physiological tolerance: a release supplies its own rule
/// version and relative tolerance, and a disagreement only produces a warning.
final class EnergyAgreementPolicy {
  EnergyAgreementPolicy(
      {required this.ruleVersion, required this.relativeTolerance}) {
    if (ruleVersion.isEmpty) {
      throw ArgumentError('Rule version required');
    }
    if (!relativeTolerance.positive) {
      throw ArgumentError('Tolerance must be positive');
    }
  }

  final String ruleVersion;
  final Exact relativeTolerance;
}

enum EnergyAgreementStatus {
  /// No comparison was attempted; [EnergyAgreement.reasons] says why.
  notAssessed,

  /// Within the supplied policy's relative tolerance.
  agrees,

  /// Outside the supplied policy's relative tolerance. A warning, never a
  /// rewrite of the supplied observation.
  disagrees,
}

final class EnergyAgreement {
  const EnergyAgreement(
      {required this.status,
      required this.reasons,
      required this.factorRuleId,
      required this.policyRuleVersion,
      this.derivedKcal,
      this.suppliedKcal,
      this.relativeDifference});

  final EnergyAgreementStatus status;
  final List<String> reasons;

  /// Factor-set identifier that produced the derived value, if any.
  final String factorRuleId;

  /// Caller-supplied tolerance rule version.
  final String policyRuleVersion;
  final Exact? derivedKcal;
  final Exact? suppliedKcal;

  /// `|derived - supplied| / supplied`, or `null` when the supplied value is not
  /// positive and a relative difference is undefined.
  final Exact? relativeDifference;
}

/// Compares a derived figure with one supplied energy observation.
///
/// The supplied value is converted to kcal on the derived basis using the same
/// declared `1 kcal = 4.184 kJ` relation. Nothing is rewritten: a disagreement
/// is reported so import review can inspect the source definition.
EnergyAgreement assessEnergyAgreement(EnergyDerivation derivation,
        NutrientObservation? supplied, EnergyAgreementPolicy policy) =>
    switch (derivation) {
      EnergyNotDerived(:final reasons) => EnergyAgreement(
          status: EnergyAgreementStatus.notAssessed,
          reasons: reasons,
          factorRuleId: derivation.ruleId,
          policyRuleVersion: policy.ruleVersion),
      DerivedEnergy(:final kcal, :final basis) => _assessDerivedEnergy(
          kcal, basis, derivation.ruleId, supplied, policy),
    };

EnergyAgreement _assessDerivedEnergy(Exact derivedKcal, FoodAmount basis,
    String ruleId, NutrientObservation? supplied, EnergyAgreementPolicy policy) {
  EnergyAgreement notAssessed(String reason) => EnergyAgreement(
      status: EnergyAgreementStatus.notAssessed,
      reasons: [reason],
      factorRuleId: ruleId,
      policyRuleVersion: policy.ruleVersion,
      derivedKcal: derivedKcal);
  if (supplied == null) {
    return notAssessed('no supplied energy observation');
  }
  final amount = supplied.amount;
  if (amount == null) {
    return notAssessed('supplied energy has no numeric amount');
  }
  final unitFactor = nutrientUnitFactor(supplied.nutrient.unit, 'kcal');
  if (unitFactor == null) {
    return notAssessed(
        'supplied energy unit ${supplied.nutrient.unit} is not an energy unit');
  }
  if (!sameDimension(supplied.basis, basis)) {
    return notAssessed('supplied energy basis is not comparable');
  }
  final suppliedKcal =
      amount * unitFactor * (basis.value / supplied.basis.value);
  final delta = derivedKcal - suppliedKcal;
  final magnitude = delta.compareTo(Exact.zero) < 0 ? Exact.zero - delta : delta;
  if (!suppliedKcal.positive) {
    final matches = magnitude.compareTo(Exact.zero) == 0;
    return EnergyAgreement(
        status: matches
            ? EnergyAgreementStatus.agrees
            : EnergyAgreementStatus.disagrees,
        reasons:
            matches ? const [] : const ['supplied energy is zero but derived'],
        factorRuleId: ruleId,
        policyRuleVersion: policy.ruleVersion,
        derivedKcal: derivedKcal,
        suppliedKcal: suppliedKcal);
  }
  final relativeDifference = magnitude / suppliedKcal;
  return EnergyAgreement(
      status: relativeDifference.compareTo(policy.relativeTolerance) <= 0
          ? EnergyAgreementStatus.agrees
          : EnergyAgreementStatus.disagrees,
      reasons: const [],
      factorRuleId: ruleId,
      policyRuleVersion: policy.ruleVersion,
      derivedKcal: derivedKcal,
      suppliedKcal: suppliedKcal,
      relativeDifference: relativeDifference);
}
