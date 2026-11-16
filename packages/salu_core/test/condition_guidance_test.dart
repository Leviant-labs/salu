import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

ConditionGuidanceInput _input(Map<String, bool?> declaration) =>
    ConditionGuidanceInput(
        policyVersion: ConditionGuidancePolicy.version,
        declaration: declaration);

ConditionGuidanceAssessment _assess(Set<PlanningCondition> declared,
        {Set<String> exclusions = const {}, bool eatingConcern = false}) =>
    ConditionGuidancePolicy.assess(
        input: _input({
          for (final condition in declared) condition.name: true,
        }),
        strictExclusions: exclusions,
        eatingConcern: eatingConcern);

Iterable<String> _codes(ConditionGuidanceAssessment assessment) =>
    assessment.explanations.map((e) => e.code);

Iterable<NutrientKey> _directiveNutrients(
        ConditionGuidanceAssessment assessment) =>
    assessment.directives.map((d) => d.nutrient);

void main() {
  test('planning condition names stay in sync with stored declarations', () {
    expect(PlanningCondition.values.map((condition) => condition.name),
        DeclaredCondition.values.map((condition) => condition.name));
  });

  test('no declared condition produces no guidance', () {
    final assessment = _assess(const {});
    expect(assessment.directives, isEmpty);
    expect(assessment.explanations, isEmpty);
    expect(assessment.displayNutrients, isEmpty);
    expect(assessment.isEmpty, isTrue);
    expect(assessment.abstained, isFalse);
  });

  test('diabetes offers lower free sugars and higher fibre, never total sugar',
      () {
    final assessment = _assess({PlanningCondition.diabetes});
    final nutrients = _directiveNutrients(assessment).toSet();
    expect(nutrients, contains(NutrientKey.freeSugarsG));
    expect(nutrients, contains(NutrientKey.fiberG));
    expect(nutrients, isNot(contains(NutrientKey.sugarsG)),
        reason: 'total sugars are not added sugars');
    expect(nutrients, isNot(contains(NutrientKey.carbohydrateG)),
        reason: 'no universal carbohydrate target is invented');
    expect(assessment.displayNutrients, contains(NutrientKey.carbohydrateG));
    expect(_codes(assessment), contains('DIABETES_SHOW_CARBOHYDRATE'));
    expect(assessment.directives.every((d) => d.sources.isNotEmpty), isTrue,
        reason: 'every soft rule must link its source');
    expect(assessment.requiresExplicitExclusion, isFalse);
  });

  test('cholesterol and blood pressure use saturated fat and sodium only', () {
    final cholesterol = _assess({PlanningCondition.highCholesterol});
    expect(_directiveNutrients(cholesterol).toSet(),
        {NutrientKey.saturatedFatG});
    expect(_directiveNutrients(cholesterol),
        isNot(contains(NutrientKey.fatG)));

    final pressure = _assess({PlanningCondition.highBloodPressure});
    expect(_directiveNutrients(pressure).toSet(), {NutrientKey.sodiumMg});
    expect(_codes(pressure), contains('BLOOD_PRESSURE_LOWER_SODIUM'));
  });

  test('triglycerides use free sugars and saturated fat, not total sugar', () {
    final assessment = _assess({PlanningCondition.highTriglycerides});
    final nutrients = _directiveNutrients(assessment).toSet();
    expect(nutrients, {NutrientKey.freeSugarsG, NutrientKey.saturatedFatG});
    expect(nutrients, isNot(contains(NutrientKey.sugarsG)));
    expect(nutrients, isNot(contains(NutrientKey.carbohydrateG)));
  });

  test('low-glucose history conflicts with sugar restriction and abstains', () {
    final assessment = _assess({
      PlanningCondition.diabetes,
      PlanningCondition.highTriglycerides,
      PlanningCondition.lowBloodGlucoseHistoryOrRisk,
    });
    expect(assessment.directives, isEmpty);
    expect(assessment.abstained, isTrue);
    expect(_codes(assessment),
        contains('HYPOGLYCAEMIA_CONFLICT_SUGAR_RESTRICTION'));
    expect(_codes(assessment), contains('HYPOGLYCAEMIA_NO_BLANKET_RESTRICTION'));
    expect(
        assessment.explanations
            .where((e) => e.code == 'HYPOGLYCAEMIA_NO_BLANKET_RESTRICTION')
            .single
            .limitation,
        contains('No fasting'));
  });

  test('a high-risk conflict withholds unrelated condition ranking too', () {
    final assessment = _assess({
      PlanningCondition.diabetes,
      PlanningCondition.lowBloodGlucoseHistoryOrRisk,
      PlanningCondition.highCholesterol,
    });
    expect(assessment.directives, isEmpty);
    expect(assessment.abstained, isTrue);
    expect(_codes(assessment),
        contains('CONDITION_GUIDANCE_WITHHELD_CONFLICT'));
    expect(assessment.untailoredConditions,
        contains(PlanningCondition.highCholesterol));
    expect(assessment.displayNutrients,
        isNot(contains(NutrientKey.saturatedFatG)),
        reason: 'a withheld rule must not present decisive data as monitoring');
  });

  test('kidney disease conflicts with sodium advice and infers no limits', () {
    final assessment = _assess({
      PlanningCondition.highBloodPressure,
      PlanningCondition.chronicKidneyDisease,
    });
    expect(assessment.directives, isEmpty);
    expect(assessment.abstained, isTrue);
    expect(_codes(assessment), contains('BLOOD_PRESSURE_KIDNEY_CONFLICT'));
    final kidney = assessment.explanations
        .where((e) => e.code == 'KIDNEY_NO_INFERRED_LIMITS')
        .single;
    expect(kidney.state, GuidanceState.noTailoredRecommendation);
    expect(kidney.limitation, contains('No protein'));
    expect(kidney.nutrients, isEmpty,
        reason: 'no potassium, phosphorus, sodium or fluid limit is emitted');
  });

  test('eating-disorder concern withholds restrictive condition guidance', () {
    final assessment = _assess({
      PlanningCondition.eatingDisorderConcerns,
      PlanningCondition.diabetes,
      PlanningCondition.highCholesterol,
    });
    expect(assessment.directives, isEmpty);
    expect(assessment.abstained, isTrue);
    expect(
        assessment.explanations
            .where((e) =>
                e.code == 'EATING_DISORDER_CONFLICT_RESTRICTIVE_GUIDANCE')
            .map((e) => e.condition),
        containsAll([
          PlanningCondition.diabetes,
          PlanningCondition.highCholesterol,
        ]));
  });

  test('safety-profile eating concern withholds restrictive guidance', () {
    final assessment =
        _assess({PlanningCondition.highCholesterol}, eatingConcern: true);
    expect(assessment.directives, isEmpty);
    expect(assessment.abstained, isTrue);
    expect(_codes(assessment),
        contains('SAFETY_EATING_CONCERN_SUPPORTIVE_ONLY'));
    expect(_codes(assessment),
        contains('SAFETY_EATING_CONCERN_CONFLICT_RESTRICTIVE_GUIDANCE'));
  });

  test('safety-profile eating concern alone stays supportive and inert', () {
    final assessment = _assess(const {}, eatingConcern: true);
    expect(assessment.directives, isEmpty);
    expect(assessment.abstained, isFalse);
    expect(_codes(assessment),
        contains('SAFETY_EATING_CONCERN_SUPPORTIVE_ONLY'));
    expect(assessment.hasDeclaredConditions, isFalse);
    expect(assessment.isEmpty, isFalse);
  });

  test('conditions without suitable data state no tailored recommendation',
      () {
    final assessment = _assess({
      PlanningCondition.chronicKidneyDisease,
      PlanningCondition.lactoseIntolerance,
      PlanningCondition.gout,
      PlanningCondition.irritableBowelSyndrome,
    });
    expect(assessment.directives, isEmpty);
    expect(assessment.abstained, isFalse);
    expect(
        assessment.untailoredConditions,
        containsAll([
          PlanningCondition.chronicKidneyDisease,
          PlanningCondition.lactoseIntolerance,
          PlanningCondition.gout,
          PlanningCondition.irritableBowelSyndrome,
        ]));
    expect(_codes(assessment), contains('GOUT_NO_PURINE_DATA'));
    expect(_codes(assessment), contains('LACTOSE_NO_AUTOMATIC_EXCLUSION'));
    expect(_codes(assessment), contains('IBS_NO_UNIVERSAL_TRIGGERS'));
  });

  test('allergy and coeliac flags never invent exclusions', () {
    final allergy = _assess({PlanningCondition.foodAllergy});
    expect(allergy.requiresExplicitExclusion, isTrue);
    expect(allergy.directives, isEmpty);
    expect(_codes(allergy), contains('ALLERGY_REQUIRES_EXPLICIT_EXCLUSION'));

    final coeliac = _assess({PlanningCondition.coeliacDisease});
    expect(coeliac.requiresExplicitExclusion, isTrue);
    expect(_codes(coeliac), contains('COELIAC_REQUIRES_GLUTEN_EXCLUSION'));

    final nonGluten = _assess({PlanningCondition.coeliacDisease},
        exclusions: {'milk'});
    expect(nonGluten.requiresExplicitExclusion, isTrue);

    final enforced = _assess({PlanningCondition.coeliacDisease},
        exclusions: {'Gluten'});
    expect(enforced.requiresExplicitExclusion, isFalse);
    expect(_codes(enforced), contains('COELIAC_EXCLUSIONS_ENFORCED'));

    final allergyWithExclusions =
        _assess({PlanningCondition.foodAllergy}, exclusions: {'peanut'});
    expect(allergyWithExclusions.requiresExplicitExclusion, isTrue,
        reason: 'the declaration does not store which allergen was declared');
    expect(_codes(allergyWithExclusions),
        contains('ALLERGY_COVERAGE_UNASSESSED'));
  });

  test('whole-word gluten matching does not treat buckwheat as wheat', () {
    expect(ConditionGuidancePolicy.hasGlutenExclusion({'buckwheat'}), isFalse);
    expect(ConditionGuidancePolicy.hasGlutenExclusion({'gluten-free'}), isTrue);
    expect(ConditionGuidancePolicy.hasGlutenExclusion({'wheat flour'}), isTrue);
    expect(ConditionGuidancePolicy.hasGlutenExclusion({'rye'}), isTrue);
  });

  test('unknown declared condition is preserved and not treated as absent', () {
    final input = _input({
      'diabetes': true,
      'futureCondition': true,
      'futureAbsent': false,
    });
    expect(input.declared, {PlanningCondition.diabetes});
    expect(input.unrecognizedDeclared, {'futureCondition'});
    final assessment = ConditionGuidancePolicy.assess(
        input: input, strictExclusions: const {});
    expect(_codes(assessment), contains('UNRECOGNIZED_CONDITION_DECLARED'));
    expect(input.fingerprint, contains('futureCondition'));
  });

  test('declaration fingerprint is canonical and detects edits', () {
    final a = _input({'diabetes': true, 'gout': null});
    final b = _input({'gout': null, 'diabetes': true});
    expect(a.fingerprint, b.fingerprint);
    expect(a.sameDeclaration(b), isTrue);

    final absent = _input({'diabetes': false});
    expect(a.fingerprint, isNot(absent.fingerprint));
    expect(a.sameDeclaration(absent), isFalse,
        reason: 'unknown is not the same user choice as explicitly absent');
  });

  test('missing decisive data is reported, never scored as zero', () {
    final assessment = _assess({PlanningCondition.diabetes});
    final missing = ConditionGuidanceReport.evaluate(assessment, [
      const ConditionGuidanceMealData(
          ingredientsResolved: true,
          nutrients: <NutrientKey, NutrientSum>{}),
      const ConditionGuidanceMealData(
          ingredientsResolved: true,
          nutrients: <NutrientKey, NutrientSum>{}),
    ]);
    expect(missing.allDirectiveDataInsufficient, isTrue);
    expect(missing.hasTailoredGuidance, isFalse);
    expect(missing.explanations.map((e) => e.code),
        contains('CONDITION_NUTRIENT_DATA_INSUFFICIENT'));
    expect(missing.evidence.every((e) => e.knownMeals == 0), isTrue);

    final partial = ConditionGuidanceReport.evaluate(assessment, [
      ConditionGuidanceMealData(
          ingredientsResolved: true,
          nutrients: {
            NutrientKey.freeSugarsG: const NutrientSum(
                value: 2,
                isComplete: true,
                includesTrace: false,
                includesEstimate: false,
                knownEntries: 1),
            NutrientKey.fiberG: const NutrientSum(
                value: 4,
                isComplete: true,
                includesTrace: false,
                includesEstimate: false,
                knownEntries: 1),
          }),
      const ConditionGuidanceMealData(
          ingredientsResolved: true,
          nutrients: <NutrientKey, NutrientSum>{}),
    ]);
    expect(partial.hasPartialDirectiveData, isTrue);
    expect(partial.evidence.every((e) => e.knownMeals == 1), isTrue);
    expect(partial.explanations.map((e) => e.code),
        contains('CONDITION_NUTRIENT_DATA_PARTIAL'));
  });

  test('declaration document parser fails closed on unsupported shapes', () {
    expect(
        () => ConditionGuidanceInput.fromDeclarationDocument({
              'schemaVersion': 2,
              'conditions': <String, Object?>{},
            }),
        throwsFormatException);
    expect(
        () => ConditionGuidanceInput.fromDeclarationDocument({
              'schemaVersion': 1,
              'conditions': 'diabetes',
            }),
        throwsFormatException);
    expect(
        () => ConditionGuidanceInput.fromDeclarationDocument({
              'schemaVersion': 1,
              'conditions': {'diabetes': 'yes'},
            }),
        throwsFormatException);

    final absentDocument = ConditionGuidanceInput.fromDeclarationDocument(null);
    final nullConditions = ConditionGuidanceInput.fromDeclarationDocument({
      'schemaVersion': 1,
      'conditions': <String, Object?>{'diabetes': null},
    });
    expect(absentDocument.fingerprint, nullConditions.fingerprint);
    expect(nullConditions.declared, isEmpty);
    expect(nullConditions.absent, isEmpty);
  });
}
