import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

const protein = NutrientIdentity('protein', 'g', 'protein');
const iodineUg = NutrientIdentity('iodine', 'µg', 'iodine');
const sodium = NutrientIdentity('sodium', 'mg', 'sodium');

NutrientObservation obs(NutrientIdentity nutrient, String? amount,
        {String basis = '100',
        FoodUnit unit = FoodUnit.g,
        String? measureId,
        ObservationQualifier qualifier = ObservationQualifier.reported,
        String origin = 'label',
        SourceInterval? suppliedInterval,
        String? evidenceDate}) =>
    NutrientObservation(
        nutrient: nutrient,
        basis: FoodAmount(basis, unit, measureId: measureId),
        qualifier: qualifier,
        sourceId: 'source',
        sourceVersion: 'v1',
        origin: origin,
        amount: amount,
        suppliedInterval: suppliedInterval,
        evidenceDate: evidenceDate);

ObservedFood food(String id, List<NutrientObservation> observations,
        {String quantity = '100',
        FoodUnit unit = FoodUnit.g,
        String? measureId,
        List<QuantityConversion> conversions = const []}) =>
    ObservedFood(
        id: id,
        quantity: FoodAmount(quantity, unit, measureId: measureId),
        observations: observations,
        conversions: conversions);

ReferencePolicy policy(
        {ReferenceKind kind = ReferenceKind.maximumGuidance,
        String? lower,
        String? upper = '2000',
        NutrientIdentity nutrient = sodium}) =>
    ReferencePolicy(
        id: 'reference',
        nutrient: nutrient,
        kind: kind,
        source: 'test',
        edition: '1',
        temporalBasis: 'day',
        approved: true,
        populationMatches: true,
        lower: lower == null ? null : Exact.parse(lower),
        upper: upper == null ? null : Exact.parse(upper));

NutrientObservation component(String id, String definition, String? amount,
        {String basis = '100',
        String unit = 'g',
        FoodUnit basisUnit = FoodUnit.g,
        String scope = 'food',
        ObservationQualifier qualifier = ObservationQualifier.reported}) =>
    NutrientObservation(
        nutrient: NutrientIdentity(id, unit, definition, scope: scope),
        basis: FoodAmount(basis, basisUnit),
        qualifier: qualifier,
        sourceId: 'label',
        sourceVersion: '1',
        origin: 'label',
        amount: amount);

List<NutrientObservation> euMacros({String alcohol = '0'}) => [
      component('protein_g', 'protein_g', '10'),
      component('fat_g', 'fat_g', '5'),
      component('carbohydrate_g', NutrientDefinitions.euAvailableCarbohydrate,
          '20'),
      component('fiber_g', 'fiber_g', '3'),
      component('polyols_g', 'polyols_g', '2'),
      if (alcohol != '0') component('alcohol_g', 'alcohol_g', alcohol),
    ];

DerivedEnergy derivedEu({String alcohol = '0', String basis = '100'}) =>
    deriveEnergyKcal(
        observations: euMacros(alcohol: alcohol),
        basis: FoodAmount(basis, FoodUnit.g)) as DerivedEnergy;

NutrientObservation suppliedEnergy(String amount,
        {String unit = 'kcal', String basis = '100', FoodUnit basisUnit = FoodUnit.g}) =>
    NutrientObservation(
        nutrient: NutrientIdentity(
            unit == 'kJ' ? 'energy_kj' : 'energy_kcal', unit, 'declared_energy'),
        basis: FoodAmount(basis, basisUnit),
        qualifier: ObservationQualifier.reported,
        sourceId: 'label',
        sourceVersion: '1',
        origin: 'label',
        amount: amount);

final strictRule = EnergyAgreementPolicy(
    ruleVersion: 'import-rule-1', relativeTolerance: Exact.parse('0.01'));

void main() {
  group('basis and unit conversions', () {
    test('conflicting food-specific conversions never depend on list order', () {
      final item = FoodAmount('1', FoodUnit.item, measureId: 'piece');
      final grams = FoodAmount('100', FoodUnit.g);
      final small = QuantityConversion(
          from: FoodAmount('1', FoodUnit.item, measureId: 'piece'),
          to: FoodAmount('120', FoodUnit.g),
          source: 'label-a');
      final large = QuantityConversion(
          from: FoodAmount('1', FoodUnit.item, measureId: 'piece'),
          to: FoodAmount('150', FoodUnit.g),
          source: 'label-b');
      expect(() => quantityRatio(item, grams, [small, large]), throwsStateError);
      expect(() => quantityRatio(item, grams, [large, small]), throwsStateError);
      expect(quantityRatio(item, grams, [small]), Exact.parse('1.2'));
      expect(
          quantityRatio(
              FoodAmount('240', FoodUnit.g),
              FoodAmount('1', FoodUnit.item, measureId: 'piece'),
              [small]),
          Exact.parse('2'));
      // Repeating one recorded conversion is not a conflict.
      expect(quantityRatio(item, grams, [small, small]), Exact.parse('1.2'));
    });

    test('unit factors are exact, directional and dimension-bound', () {
      expect(nutrientUnitFactor('mg', 'g'), Exact.parse('0.001'));
      expect(nutrientUnitFactor('g', 'mg'), Exact.parse('1000'));
      expect(nutrientUnitFactor('mcg', 'µg'), Exact.one);
      expect(nutrientUnitFactor('ug', 'µg'), Exact.one);
      expect(nutrientUnitFactor('μg', 'µg'), Exact.one);
      expect(nutrientUnitFactor('kcal', 'kJ'), Exact.parse('4.184'));
      expect(nutrientUnitFactor('g', 'ml'), isNull);
      expect(nutrientUnitFactor('IU', 'µg'), isNull);
    });

    test('a missing unit is derived per definition, supplied values untouched',
        () {
      final kcal = obs(
          const NutrientIdentity('energy_kcal', 'kcal', 'declared_energy'), '100');
      final derived = completeEnergyUnits([kcal]);
      expect(derived.length, 2);
      expect(derived.last.nutrient.id, 'energy_kj');
      expect(derived.last.nutrient.definition, 'declared_energy');
      expect(derived.last.amount, Exact.parse('418.4'));
      expect(derived.last.origin, contains('unit-conversion'));
      expect(derived.last.sourceId, 'source');

      final kj = obs(
          const NutrientIdentity('energy_kj', 'kJ', 'declared_energy'), '420');
      final supplied = completeEnergyUnits([kcal, kj]);
      expect(supplied.length, 2);
      expect(supplied[1].amount, Exact.parse('420'));

      final fromKj = completeEnergyUnits([
        obs(const NutrientIdentity('energy_kj', 'kJ', 'declared_energy'),
            '418.4')
      ]);
      expect(fromKj.last.nutrient.id, 'energy_kcal');
      expect(fromKj.last.amount, Exact.parse('100'));
    });

    test('derivation does not cross definitions or invent from no amount', () {
      final kcal = obs(
          const NutrientIdentity('energy_kcal', 'kcal', 'declared_energy'), '100');
      final atwater = obs(
          const NutrientIdentity('energy_kj', 'kJ', 'atwater'), '420');
      final mixed = completeEnergyUnits([kcal, atwater]);
      // Each declared-energy identity gets its own missing unit; the two
      // definitions never share a supplied value or each other's conversion.
      expect(mixed.length, 4);
      expect(
          mixed.where((o) =>
              o.nutrient.id == 'energy_kj' &&
              o.nutrient.definition == 'declared_energy' &&
              o.amount == Exact.parse('418.4')),
          hasLength(1));
      expect(
          mixed.where((o) =>
              o.nutrient.id == 'energy_kcal' &&
              o.nutrient.definition == 'atwater' &&
              o.amount == Exact.parse('420') / Exact.parse('4.184')),
          hasLength(1));
      expect(mixed[1].amount, Exact.parse('420'));

      // A supplied pair spelled by unit is one declared quantity: each value
      // stays as provided, nothing extra is derived, and the legacy projection
      // still sees exactly one observation per key.
      final pair = completeEnergyUnits([
        obs(const NutrientIdentity('energy_kcal', 'kcal', 'energy_kcal'), '100'),
        obs(const NutrientIdentity('energy_kj', 'kJ', 'energy_kj'), '420'),
      ]);
      expect(pair.length, 2);
      final pairProfile = projectObservations(pair,
          basis: FoodAmount('100', FoodUnit.g));
      expect(pairProfile[NutrientKey.energyKcal].exactValue, Exact.parse('100'));
      expect(pairProfile[NutrientKey.energyKj].exactValue, Exact.parse('420'));

      final ambiguous =
          completeEnergyUnits([kcal, obs(kcal.nutrient, '90')]);
      expect(ambiguous.length, 2);

      final trace = completeEnergyUnits([
        obs(kcal.nutrient, null, qualifier: ObservationQualifier.trace)
      ]);
      expect(trace.length, 1);
    });

    test('energy spelled with the key wire still projects both units', () {
      final observations = completeEnergyUnits([
        obs(const NutrientIdentity('energy_kcal', 'kcal', 'energy_kcal'), '100')
      ]);
      final profile = projectObservations(observations,
          basis: FoodAmount('100', FoodUnit.g));
      expect(profile[NutrientKey.energyKcal].exactValue, Exact.parse('100'));
      expect(profile[NutrientKey.energyKj].exactValue, Exact.parse('418.4'));
    });
  });

  group('nutrient identity', () {
    test('delimited fields cannot collide', () {
      expect(const NutrientIdentity('a|b', 'g', 'c').key,
          isNot(const NutrientIdentity('a', 'b|g', 'c').key));
      expect(const NutrientIdentity('a', 'g', 'c').key,
          isNot(const NutrientIdentity('a', 'g', 'c', scope: 'supplement').key));
      expect(const NutrientIdentity('a', 'g', 'c', scope: 'food').key,
          const NutrientIdentity('a', 'g', 'c').key);
    });

    test('origin is part of provenance', () {
      expect(
          () => NutrientObservation(
              nutrient: protein,
              basis: FoodAmount('100', FoodUnit.g),
              qualifier: ObservationQualifier.reported,
              sourceId: 'label',
              sourceVersion: '1',
              origin: '',
              amount: '1'),
          throwsArgumentError);
    });
  });

  group('source-supplied intervals and evidence dates', () {
    SourceInterval interval(
            {String? lower,
            String? upper,
            bool lowerInclusive = true,
            bool upperInclusive = true,
            String scope = 'label:per-100-g rounding',
            String method = 'declared value rounded to nearest 0.5'}) =>
        SourceInterval(
            lower: lower == null ? null : Exact.parse(lower),
            upper: upper == null ? null : Exact.parse(upper),
            lowerInclusive: lowerInclusive,
            upperInclusive: upperInclusive,
            scope: scope,
            method: method);

    test('an interval serializes exactly and round-trips', () {
      final supplied =
          interval(lower: '9.5', upper: '10.5', upperInclusive: false);
      expect(supplied.toJson(), {
        'lower': {'n': '19', 'd': '2'},
        'upper': {'n': '21', 'd': '2'},
        'lowerInclusive': true,
        'upperInclusive': false,
        'scope': 'label:per-100-g rounding',
        'method': 'declared value rounded to nearest 0.5'
      });
      expect(SourceInterval.fromJson(supplied.toJson()).toJson(),
          supplied.toJson());

      final recorded = obs(protein, '10',
          suppliedInterval: supplied, evidenceDate: '2024-02-29');
      final decoded = NutrientObservation.fromJson(recorded.toJson());
      expect(decoded.amount, Exact.parse('10'));
      expect(decoded.evidenceDate, '2024-02-29');
      final roundTripped = decoded.suppliedInterval!;
      expect(roundTripped.lower, Exact.parse('9.5'));
      expect(roundTripped.upper, Exact.parse('10.5'));
      expect(roundTripped.lowerInclusive, isTrue);
      expect(roundTripped.upperInclusive, isFalse);
      expect(roundTripped.scope, 'label:per-100-g rounding');
      expect(roundTripped.method, 'declared value rounded to nearest 0.5');
      expect(decoded.toJson(), recorded.toJson());
    });

    test('one bound or one exact value is enough', () {
      final below =
          interval(upper: '5', lowerInclusive: false, upperInclusive: false);
      expect(below.lower, isNull);
      expect(SourceInterval.fromJson(below.toJson()).upper, Exact.parse('5'));
      expect(SourceInterval.fromJson(below.toJson()).upperInclusive, isFalse);

      final atMost = interval(upper: '5', lowerInclusive: false);
      expect(atMost.upperInclusive, isTrue);
      expect(SourceInterval.fromJson(atMost.toJson()).upperInclusive, isTrue);

      final atLeast = interval(lower: '5', upperInclusive: false);
      expect(atLeast.upper, isNull);
      expect(SourceInterval.fromJson(atLeast.toJson()).lower, Exact.parse('5'));

      final single = interval(lower: '5', upper: '5');
      expect(SourceInterval.fromJson(single.toJson()).upper, Exact.parse('5'));
    });

    test('invalid intervals are rejected', () {
      expect(() => interval(lower: '-1', upperInclusive: false),
          throwsArgumentError);
      expect(
          () => interval(upper: '-1', lowerInclusive: false),
          throwsArgumentError);
      expect(() => interval(lower: '6', upper: '5'), throwsArgumentError);
      expect(() => interval(lower: '5', upper: '5', upperInclusive: false),
          throwsArgumentError);
      expect(
          () => SourceInterval(
              lowerInclusive: false,
              upperInclusive: false,
              scope: 'label',
              method: 'none'),
          throwsArgumentError);
      expect(
          () => SourceInterval(
              upper: Exact.parse('5'),
              lowerInclusive: true,
              upperInclusive: false,
              scope: 'label',
              method: 'rounded'),
          throwsArgumentError);
      expect(
          () => SourceInterval(
              lower: Exact.parse('5'),
              lowerInclusive: false,
              upperInclusive: true,
              scope: 'label',
              method: 'rounded'),
          throwsArgumentError);
      expect(() => interval(lower: '1', upperInclusive: false, scope: '  '),
          throwsArgumentError);
      expect(() => interval(lower: '1', upperInclusive: false, method: ''),
          throwsArgumentError);
    });

    test('evidence dates must be real ISO calendar dates', () {
      expect(obs(protein, '10', evidenceDate: '2024-02-29').evidenceDate,
          '2024-02-29');
      for (final invalid in [
        '2023-02-29',
        '2024-02-30',
        '2024-13-01',
        '2024-00-10',
        '2024-01-00',
        '2024-2-3',
        '10/02/2024',
        '2024-02-29T00:00:00Z',
        ''
      ]) {
        expect(() => obs(protein, '10', evidenceDate: invalid),
            throwsArgumentError,
            reason: invalid);
      }
    });

    test('observations recorded before the fields existed still decode', () {
      final legacy = <String, Object?>{
        'nutrient': const NutrientIdentity('protein', 'g', 'protein').toJson(),
        'basis': FoodAmount('100', FoodUnit.g).toJson(),
        'qualifier': 'reported',
        'sourceId': 'source',
        'sourceVersion': 'v1',
        'origin': 'label',
        'amount': Exact.parse('10').toJson()
      };
      final decoded = NutrientObservation.fromJson(legacy);
      expect(decoded.suppliedInterval, isNull);
      expect(decoded.evidenceDate, isNull);
      expect(decoded.toJson(), legacy);
    });

    test('a supplied interval is metadata, not an intake bound', () {
      final wide = interval(
          lower: '1000',
          upper: '2000',
          scope: 'label:range',
          method: 'source printed a wide range');
      final summary = const FoodCalculationService().summarize(
          protein,
          [food('a', [obs(protein, '10', suppliedInterval: wide)])],
          DiaryCompleteness.userDeclaredComplete);
      expect(summary.recordedSum, Exact.parse('10'));
      expect(summary.known, 1);
      expect(summary.permitsComparison, isTrue);
      expect(summary.sourceIntervals.single.foodId, 'a');
      expect(summary.sourceIntervals.single.observation.suppliedInterval, same(wide));
      expect(summary.sourceIntervals.single.observation.basis.value, Exact.parse('100'));

      final detection = interval(
          upper: '0.5',
          lowerInclusive: false,
          upperInclusive: false,
          scope: 'label:detection',
          method: 'reported as below detection');
      final onlyDetection = const FoodCalculationService().summarize(
          protein,
          [
            food('b', [
              obs(protein, null,
                  qualifier: ObservationQualifier.belowDetection,
                  suppliedInterval: detection)
            ])
          ],
          DiaryCompleteness.userDeclaredComplete);
      expect(onlyDetection.recordedSum, isNull);
      expect(onlyDetection.completeness, RecordCompleteness.noData);
      expect(onlyDetection.sourceIntervals.single.foodId, 'b');
      expect(onlyDetection.sourceIntervals.single.observation.suppliedInterval,
          same(detection));
      expect(() => onlyDetection.sourceIntervals.clear(), throwsUnsupportedError);
    });

    test('derived energy scales supplied bounds exactly and keeps evidence', () {
      final labelInterval = interval(
          lower: '99.5',
          upper: '100.5',
          scope: 'label:per-100-kcal rounding',
          method: 'nearest 1 kcal');
      final kcal = obs(
          const NutrientIdentity('energy_kcal', 'kcal', 'declared_energy'), '100',
          suppliedInterval: labelInterval, evidenceDate: '2024-05-01');
      final derived = completeEnergyUnits([kcal]);
      expect(derived.length, 2);
      expect(derived.first, same(kcal));
      expect(kcal.suppliedInterval!.lower, Exact.parse('99.5'));
      expect(kcal.evidenceDate, '2024-05-01');
      final kj = derived.last;
      expect(kj.nutrient.unit, 'kJ');
      expect(kj.amount, Exact.parse('418.4'));
      expect(kj.evidenceDate, '2024-05-01');
      final kjInterval = kj.suppliedInterval!;
      expect(kjInterval.lower, Exact.parse('416.308'));
      expect(kjInterval.upper, Exact.parse('420.492'));
      expect(kjInterval.lowerInclusive, isTrue);
      expect(kjInterval.upperInclusive, isTrue);
      expect(kjInterval.scope, 'label:per-100-kcal rounding');
      expect(kjInterval.method, 'nearest 1 kcal');

      final kilojoules = obs(
          const NutrientIdentity('energy_kj', 'kJ', 'declared_energy'), '418.4',
          suppliedInterval: interval(
              lower: '416.308',
              upper: '420.492',
              scope: 'label:per-100-kj rounding',
              method: 'nearest 1 kJ'),
          evidenceDate: '2024-05-01');
      final kcalDerived = completeEnergyUnits([kilojoules]).last;
      expect(kcalDerived.nutrient.unit, 'kcal');
      expect(kcalDerived.evidenceDate, '2024-05-01');
      expect(kcalDerived.suppliedInterval!.lower, Exact.parse('99.5'));
      expect(kcalDerived.suppliedInterval!.upper, Exact.parse('100.5'));

      final oneSided = obs(
          const NutrientIdentity('energy_kcal', 'kcal', 'declared_energy'), '100',
          suppliedInterval: interval(
              upper: '100.5',
              lowerInclusive: false,
              scope: 'label:upper rounding',
              method: 'printed as at most 100.5'));
      final oneSidedKj =
          completeEnergyUnits([oneSided]).last.suppliedInterval!;
      expect(oneSidedKj.lower, isNull);
      expect(oneSidedKj.upper, Exact.parse('420.492'));
      expect(oneSidedKj.lowerInclusive, isFalse);
      expect(oneSidedKj.upperInclusive, isTrue);
    });
  });

  group('exact value states', () {
    test('a non-zero exact value is never relabelled as a printed zero', () {
      var tiny = Exact.one;
      for (var i = 0; i < 330; i++) {
        tiny = tiny / Exact.parse('10');
      }
      expect(tiny.toDouble(), 0);
      final reported = NutrientReported.exact(tiny);
      expect(reported.toJson()['state'], 'reported');
      expect(NutrientValue.fromJson(reported.toJson()).exactValue, tiny);
      expect(NutrientReported.exact(Exact.zero).toJson()['state'],
          'reported_zero');
    });
  });

  group('recording totals', () {
    test('same nutrient in different mass units sums exactly; unknown units ask',
        () {
      final summary = const FoodCalculationService().summarize(
          iodineUg,
          [
            food('a', [obs(iodineUg, '150')], quantity: '200'),
            food('b',
                [obs(const NutrientIdentity('iodine', 'mg', 'iodine'), '0.1')]),
            food('c',
                [obs(const NutrientIdentity('iodine', 'IU', 'iodine'), '40')]),
          ],
          DiaryCompleteness.userDeclaredComplete);
      expect(summary.recordedSum, Exact.parse('400'));
      expect(summary.known, 2);
      expect(summary.missing, isEmpty);
      expect(summary.needsClarification, ['c']);
      expect(summary.completeness, RecordCompleteness.partial);
      expect(summary.permitsComparison, isFalse);
    });

    test('a recorded food-specific conversion resolves a label basis exactly',
        () {
      const label = NutrientIdentity('protein', 'g', 'protein');
      final servingToGram = QuantityConversion(
          from: FoodAmount('1', FoodUnit.serving, measureId: 'serving'),
          to: FoodAmount('30', FoodUnit.g),
          source: 'label-serving');
      final summary = const FoodCalculationService().summarize(
          label,
          [
            food('bar', [
              obs(label, '10',
                  basis: '1',
                  unit: FoodUnit.serving,
                  measureId: 'serving')
            ], quantity: '60', conversions: [servingToGram])
          ],
          DiaryCompleteness.userDeclaredComplete);
      expect(summary.recordedSum, Exact.parse('20'));
      expect(summary.permitsComparison, isTrue);
    });

    test('a dimensionally unresolved food never aborts the day total', () {
      const energy = NutrientIdentity('energy', 'kcal', 'declared_energy');
      final summary = const FoodCalculationService().summarize(
          energy,
          [
            food('drink', [obs(energy, '40', unit: FoodUnit.ml)],
                quantity: '250', unit: FoodUnit.ml),
            food('ambiguous', [obs(energy, '120')],
                quantity: '1', unit: FoodUnit.item, measureId: 'piece'),
          ],
          DiaryCompleteness.userDeclaredComplete);
      expect(summary.recordedSum, Exact.parse('100'));
      expect(summary.missing, isEmpty);
      expect(summary.needsClarification, ['ambiguous']);
      expect(summary.permitsComparison, isFalse);

      final onlyAmbiguous = const FoodCalculationService().summarize(
          energy,
          [
            food('ambiguous', [obs(energy, '120')],
                quantity: '1', unit: FoodUnit.item, measureId: 'piece')
          ],
          DiaryCompleteness.userDeclaredComplete);
      expect(onlyAmbiguous.recordedSum, isNull);
      expect(onlyAmbiguous.completeness, RecordCompleteness.noData);
    });

    test('two unit representations of one nutrient ask instead of double count',
        () {
      final summary = const FoodCalculationService().summarize(
          iodineUg,
          [
            food('both', [
              obs(iodineUg, '150'),
              obs(const NutrientIdentity('iodine', 'mg', 'iodine'), '0.15'),
            ])
          ],
          DiaryCompleteness.userDeclaredComplete);
      expect(summary.recordedSum, isNull);
      expect(summary.known, 0);
      expect(summary.needsClarification, ['both']);
    });

    test('estimated contributions are summed separately and stay decisive', () {
      final summary = const FoodCalculationService().summarize(
          protein,
          [
            food('estimated', [
              obs(protein, '10',
                  qualifier: ObservationQualifier.estimated,
                  origin: 'photo-inference')
            ]),
            food('reported', [obs(protein, '20')]),
          ],
          DiaryCompleteness.userDeclaredComplete);
      expect(summary.recordedSum, Exact.parse('30'));
      expect(summary.estimatedContribution, Exact.parse('10'));
      expect(summary.estimated, 1);
      expect(summary.permitsComparison, isFalse);
    });
  });

  group('reference comparison eligibility', () {
    test('a declared no-intake day compares as a recorded zero', () {
      final summary = const FoodCalculationService()
          .summarize(sodium, [], DiaryCompleteness.confirmedNoIntake);
      expect(summary.recordedSum, isNull);
      expect(summary.completeness, RecordCompleteness.completeForRecord);
      expect(summary.permitsComparison, isTrue);
      const service = ReferenceComparisonService();
      expect(service.compare(summary, policy()),
          ComparisonStatus.recordedNotAboveGuidance);
      expect(
          service.compare(
              summary, policy(kind: ReferenceKind.ai, lower: '1500', upper: null)),
          ComparisonStatus.recordedBelowReference);
      expect(
          service.compare(
              summary,
              policy(
                  kind: ReferenceKind.riRange, lower: '1000', upper: '2400')),
          ComparisonStatus.recordedOutsideRange);
    });

    test('an empty declared-complete diary is still no data', () {
      final summary = const FoodCalculationService()
          .summarize(sodium, [], DiaryCompleteness.userDeclaredComplete);
      expect(summary.completeness, RecordCompleteness.noData);
      expect(summary.permitsComparison, isFalse);
      expect(const ReferenceComparisonService().compare(summary, policy()),
          ComparisonStatus.insufficientData);
    });

    test('a reference unit is converted exactly; unrelated units do not compare',
        () {
      final summary = RecordedSummary(
          nutrient: iodineUg,
          recordedSum: Exact.parse('100'),
          known: 1,
          missing: const [],
          estimated: 0,
          diaryCompleteness: DiaryCompleteness.userDeclaredComplete);
      const service = ReferenceComparisonService();
      expect(
          service.compare(
              summary,
              policy(
                  nutrient: const NutrientIdentity('iodine', 'mg', 'iodine'),
                  upper: '0.2')),
          ComparisonStatus.recordedNotAboveGuidance);
      expect(
          service.compare(
              summary,
              policy(
                  nutrient: const NutrientIdentity('iodine', 'IU', 'iodine'),
                  upper: '0.2')),
          ComparisonStatus.referenceNotApplicable);
      expect(
          service.compare(
              summary,
              policy(
                  nutrient: const NutrientIdentity('iodine', 'mg', 'free_iodine'),
                  upper: '0.2')),
          ComparisonStatus.referenceNotApplicable);
    });
  });

  group('derived energy', () {
    test('EU available carbohydrate subtracts polyols before the 4 kcal/g factor',
        () {
      final derived = derivedEu();
      expect(derived.ruleId, 'eu-declared-energy-v1');
      expect(derived.kcal, Exact.parse('167.8'));
      expect(derived.contributions[EnergyComponent.carbohydrate],
          Exact.parse('72'));
      expect(derived.contributions[EnergyComponent.polyols], Exact.parse('4.8'));
      expect(derived.notDeclared, [
        EnergyComponent.erythritol,
        EnergyComponent.alcohol,
        EnergyComponent.organicAcids,
      ]);
    });

    test('US total carbohydrate subtracts both fibre and polyols', () {
      final derived = deriveEnergyKcal(observations: [
        component('protein_g', 'protein_g', '10'),
        component('fat_g', 'fat_g', '5'),
        component('carbohydrate_g', NutrientDefinitions.usTotalCarbohydrate,
            '22'),
        component('fiber_g', 'fiber_g', '3'),
        component('polyols_g', 'polyols_g', '2'),
      ], basis: FoodAmount('100', FoodUnit.g)) as DerivedEnergy;
      expect(derived.kcal, Exact.parse('163.8'));
      expect(derived.contributions[EnergyComponent.carbohydrate],
          Exact.parse('68'));
    });

    test('declared optional components add their factor and scale with basis',
        () {
      expect(derivedEu(alcohol: '10').kcal, Exact.parse('237.8'));
      expect(derivedEu(basis: '50').kcal, Exact.parse('83.9'));
    });

    test('mass units convert exactly inside the derivation', () {
      final derived = deriveEnergyKcal(observations: [
        component('protein', 'protein', '10000', unit: 'mg'),
        component('fat_g', 'fat_g', '5'),
        component('carbohydrate_g', NutrientDefinitions.euAvailableCarbohydrate,
            '20'),
        component('fiber_g', 'fiber_g', '3'),
        component('polyols_g', 'polyols_g', '2'),
      ], basis: FoodAmount('100', FoodUnit.g)) as DerivedEnergy;
      expect(derived.kcal, Exact.parse('167.8'));
    });

    test('missing, ambiguous or unsupported inputs are not guessed', () {
      EnergyNotDerived failure(List<NutrientObservation> observations) =>
          deriveEnergyKcal(
              observations: observations,
              basis: FoodAmount('100', FoodUnit.g)) as EnergyNotDerived;

      final noPolyols = failure([
        for (final o in euMacros())
          if (o.nutrient.id != 'polyols_g') o
      ]);
      expect(noPolyols.ruleId, 'eu-declared-energy-v1');
      expect(noPolyols.missing, contains(EnergyComponent.polyols));
      expect(noPolyols.reasons, contains('polyols not declared'));

      final wrongScope = failure([
        for (final o in euMacros())
          if (o.nutrient.id == 'protein_g')
            component('protein_g', 'protein_g', '10', scope: 'supplement')
          else
            o
      ]);
      expect(wrongScope.reasons, contains('protein not declared'));

      final duplicate = failure([
        ...euMacros(),
        component('protein', 'protein', '10'),
      ]);
      expect(duplicate.reasons, contains('protein has 2 identities'));

      final nonMass = failure([
        for (final o in euMacros())
          if (o.nutrient.id == 'protein_g')
            component('protein_g', 'protein_g', '10', unit: 'IU')
          else
            o
      ]);
      expect(nonMass.reasons, contains('protein unit IU is not a mass'));

      final noAmount = failure([
        for (final o in euMacros())
          if (o.nutrient.id == 'protein_g')
            component('protein_g', 'protein_g', null,
                qualifier: ObservationQualifier.trace)
          else
            o
      ]);
      expect(noAmount.reasons, contains('protein has no numeric amount'));

      final basisMismatch = failure([
        for (final o in euMacros())
          if (o.nutrient.id == 'protein_g')
            component('protein_g', 'protein_g', '10',
                basisUnit: FoodUnit.ml)
          else
            o
      ]);
      expect(basisMismatch.reasons, contains('protein basis is not comparable'));

      final unsupported = failure([
        for (final o in euMacros())
          if (o.nutrient.id == 'carbohydrate_g')
            component('carbohydrate_g', 'unspecified', '20')
          else
            o
      ]);
      expect(unsupported.reasons.join(), contains('is not supported'));

      final overlap = failure([
        component('protein_g', 'protein_g', '10'),
        component('fat_g', 'fat_g', '5'),
        component('carbohydrate_g', NutrientDefinitions.euAvailableCarbohydrate,
            '1'),
        component('fiber_g', 'fiber_g', '3'),
        component('polyols_g', 'polyols_g', '2'),
      ]);
      expect(
          overlap.reasons,
          contains(
              'carbohydrate is smaller than its declared overlap components'));

      // A declared optional component that cannot be placed on the basis is a
      // reason too: omitting it silently would understate the derived energy.
      final percentAlcohol = failure([
        ...euMacros(),
        component('alcohol_g', 'alcohol_g', '5', unit: '%'),
      ]);
      expect(percentAlcohol.reasons, contains('alcohol unit % is not a mass'));
    });

    test('agreement needs an explicit rule and never rewrites a value', () {
      final derived = derivedEu();
      expect(
          assessEnergyAgreement(derived, suppliedEnergy('168'), strictRule)
              .status,
          EnergyAgreementStatus.agrees);
      final disagree =
          assessEnergyAgreement(derived, suppliedEnergy('200'), strictRule);
      expect(disagree.status, EnergyAgreementStatus.disagrees);
      expect(disagree.suppliedKcal, Exact.parse('200'));
      expect(derived.kcal, Exact.parse('167.8'));

      final identical =
          assessEnergyAgreement(derived, suppliedEnergy('167.8'), strictRule);
      expect(identical.status, EnergyAgreementStatus.agrees);
      expect(identical.relativeDifference, Exact.zero);
      expect(identical.policyRuleVersion, 'import-rule-1');

      final kilojoules = assessEnergyAgreement(
          derived, suppliedEnergy('702.0752', unit: 'kJ'), strictRule);
      expect(kilojoules.status, EnergyAgreementStatus.agrees);
      expect(kilojoules.suppliedKcal, Exact.parse('167.8'));

      final otherBasis = assessEnergyAgreement(
          derived, suppliedEnergy('100', basis: '50'), strictRule);
      expect(otherBasis.status, EnergyAgreementStatus.disagrees);
    });

    test('no comparison is claimed when the evidence is not comparable', () {
      final derived = derivedEu();
      expect(assessEnergyAgreement(derived, null, strictRule).status,
          EnergyAgreementStatus.notAssessed);
      expect(
          assessEnergyAgreement(
                  derived, suppliedEnergy('100', unit: 'IU'), strictRule)
              .status,
          EnergyAgreementStatus.notAssessed);
      expect(
          assessEnergyAgreement(
                  derived,
                  suppliedEnergy('100', basisUnit: FoodUnit.ml),
                  strictRule)
              .status,
          EnergyAgreementStatus.notAssessed);
      final incomplete = deriveEnergyKcal(
          observations: euMacros().where((o) => o.nutrient.id != 'fiber_g').toList(),
          basis: FoodAmount('100', FoodUnit.g));
      final missing = assessEnergyAgreement(
          incomplete, suppliedEnergy('100'), strictRule);
      expect(missing.status, EnergyAgreementStatus.notAssessed);
      expect(missing.reasons, contains('fibre not declared'));

      final zero = deriveEnergyKcal(observations: [
        for (final id in ['protein_g', 'fat_g', 'fiber_g', 'polyols_g'])
          component(id, id, '0'),
        component('carbohydrate_g', NutrientDefinitions.euAvailableCarbohydrate,
            '0'),
      ], basis: FoodAmount('100', FoodUnit.g));
      expect(assessEnergyAgreement(zero, suppliedEnergy('0'), strictRule).status,
          EnergyAgreementStatus.agrees);
      expect(assessEnergyAgreement(zero, suppliedEnergy('10'), strictRule).status,
          EnergyAgreementStatus.disagrees);
    });

    test('a rule without a positive tolerance or version is rejected', () {
      expect(
          () => EnergyAgreementPolicy(
              ruleVersion: '', relativeTolerance: Exact.one),
          throwsArgumentError);
      expect(
          () => EnergyAgreementPolicy(
              ruleVersion: 'v1', relativeTolerance: Exact.zero),
          throwsArgumentError);
    });
  });
}
