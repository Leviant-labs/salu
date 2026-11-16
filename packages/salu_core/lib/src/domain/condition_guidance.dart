import 'dart:convert';

import 'nutrients.dart';

/// Conditions the planner may react to.
///
/// The wire names are the stored `conditions` keys in
/// `health-declaration/current`. A declaration is not a diagnosis, severity
/// assessment, medication record or laboratory result, and none of those may be
/// inferred from it. Unknown names written by a newer build are preserved in
/// [ConditionGuidanceInput] rather than read as absent.
enum PlanningCondition {
  highTriglycerides,
  diabetes,
  highCholesterol,
  lowBloodGlucoseHistoryOrRisk,
  highBloodPressure,
  chronicKidneyDisease,
  eatingDisorderConcerns,
  lactoseIntolerance,
  gout,
  irritableBowelSyndrome,
  foodAllergy,
  coeliacDisease;

  /// Resolves a stored condition name, or `null` when this build does not
  /// understand it. An unknown value is never rewritten as "no".
  static PlanningCondition? byNameOrNull(String? name) {
    for (final condition in PlanningCondition.values) {
      if (condition.name == name) return condition;
    }
    return null;
  }
}

/// Direction of a relative soft preference. No absolute threshold is invented.
enum GuidanceDirection { lower, higher }

/// Traceable state of one condition rule or its evaluation over a plan.
enum GuidanceState {
  /// The rule produced a relative soft preference that has data for every
  /// planned meal it was evaluated against.
  applied,

  /// The rule produced a relative soft preference but some selected meals lack
  /// the decisive nutrient. Missing data is neither zero nor evidence of
  /// suitability; it is reported separately.
  partialData,

  /// The rule was relevant, but no selected meal has usable data for the
  /// decisive nutrient. No tailored recommendation can be stated.
  insufficientData,

  /// This build has no suitable tailored rule, or the declaration requires
  /// specialist review. Generic organization is not presented as tailored.
  noTailoredRecommendation,

  /// A declared allergy/coeliac condition has no matching explicit strict
  /// exclusion. No exclusion is inferred and the plan is unassessed.
  requiresExplicitExclusion,

  /// The user's explicit strict exclusions remain hard constraints. This is not
  /// a safety certification and does not assess coverage or cross-contact.
  exclusionsEnforced,

  /// A high-risk condition conflict means no condition ranking is applied.
  abstainedConflict,

  /// Informational display only; it does not rank meals.
  notice,
}

/// Source a rule or limitation is linked to.
///
/// These are the sources named by the condition table in
/// `docs/nutrition-engine-spec.md` §3.3. Linking a source does not assert
/// effectiveness, safety, Portuguese applicability, clinical review, or
/// currentness at release.
final class ConditionGuidanceSource {
  const ConditionGuidanceSource(this.label, this.url);
  final String label, url;

  @override
  bool operator ==(Object other) =>
      other is ConditionGuidanceSource && other.url == url;
  @override
  int get hashCode => url.hashCode;
}

/// Verbatim references from the spec's condition table.
abstract final class ConditionGuidanceSources {
  static const ahaCarbohydrates = ConditionGuidanceSource(
      'AHA carbohydrate guidance',
      'https://www.heart.org/en/healthy-living/healthy-eating/eat-smart/nutrition-basics/carbohydrates');
  static const ahaFats = ConditionGuidanceSource('AHA fats',
      'https://www.heart.org/en/healthy-living/healthy-eating/eat-smart/fats/fats-in-foods');
  static const adaFruit = ConditionGuidanceSource(
      'ADA: fruit and diabetes',
      'https://diabetes.org/food-nutrition/reading-food-labels/fruit');
  static const niddkDiabetes = ConditionGuidanceSource(
      'NIDDK: living with diabetes',
      'https://www.niddk.nih.gov/health-information/diabetes/overview/healthy-living-with-diabetes');
  static const niddkLowBloodGlucose = ConditionGuidanceSource(
      'NIDDK: low blood glucose',
      'https://www.niddk.nih.gov/health-information/diabetes/overview/preventing-problems/low-blood-glucose-hypoglycemia');
  static const euAllergens = ConditionGuidanceSource(
      'European Commission: allergen information',
      'https://food.ec.europa.eu/food-safety/labelling-and-nutrition/food-information-consumers-legislation_en');
  static const fdaAllergies = ConditionGuidanceSource('FDA: food allergies',
      'https://www.fda.gov/food/buy-store-serve-safe-food/food-allergies-what-you-need-know');
  static const niddkCoeliac = ConditionGuidanceSource('NIDDK: coeliac disease',
      'https://www.niddk.nih.gov/health-information/digestive-diseases/celiac-disease/eating-diet-nutrition');
  static const nhlbiDash = ConditionGuidanceSource('NHLBI: DASH',
      'https://www.nhlbi.nih.gov/health/dash-eating-plan');
  static const niddkCkd = ConditionGuidanceSource(
      'NIDDK: healthy eating with CKD',
      'https://www.niddk.nih.gov/health-information/kidney-disease/chronic-kidney-disease-ckd/healthy-eating-adults-chronic-kidney-disease');
  static const nimhEatingDisorders = ConditionGuidanceSource(
      'NIMH: eating disorders',
      'https://www.nimh.nih.gov/health/publications/eating-disorders');
  static const niddkLactose = ConditionGuidanceSource(
      'NIDDK: lactose intolerance',
      'https://www.niddk.nih.gov/health-information/digestive-diseases/lactose-intolerance/eating-diet-nutrition');
  static const niamsGout = ConditionGuidanceSource('NIAMS: gout',
      'https://www.niams.nih.gov/health-topics/gout/diagnosis-treatment-and-steps-to-take');
  static const niddkIbs = ConditionGuidanceSource(
      'NIDDK: IBS nutrition',
      'https://www.niddk.nih.gov/health-information/digestive-diseases/irritable-bowel-syndrome/eating-diet-nutrition');
}

/// One relative soft preference derived from a declared condition.
///
/// It names a nutrient and a direction only. It never supplies a nutrient
/// value, a threshold, a diagnosis or an inferred severity, and it never
/// bypasses hard exclusions or availability.
final class ConditionGuidanceDirective {
  const ConditionGuidanceDirective({
    required this.condition,
    required this.nutrient,
    required this.direction,
    required this.ruleCode,
    required this.sources,
    required this.limitation,
  });
  final PlanningCondition condition;
  final NutrientKey nutrient;
  final GuidanceDirection direction;
  final String ruleCode;
  final List<ConditionGuidanceSource> sources;
  final String limitation;
}

/// Stable, source-linked explanation of what was and was not applied.
final class ConditionGuidanceExplanation {
  const ConditionGuidanceExplanation({
    required this.code,
    required this.condition,
    required this.state,
    required this.sources,
    this.nutrients = const [],
    required this.limitation,
  });
  final String code;
  final PlanningCondition? condition;
  final GuidanceState state;
  final List<ConditionGuidanceSource> sources;
  final List<NutrientKey> nutrients;

  /// Plain-language limit of this rule. English here is a domain/test string;
  /// surfaces localize by [code].
  final String limitation;
}

/// Policy inputs reconstructed from `health-declaration/current`.
///
/// [declaration] keeps the raw `condition -> true|false|null` map so an edit
/// in a newer build (including an unrecognized condition name) changes
/// [fingerprint]. A plan stores this input and its [policyVersion]; a later edit
/// is therefore detected from the declarations themselves, not from a label.
final class ConditionGuidanceInput {
  ConditionGuidanceInput({
    required this.policyVersion,
    required Map<String, bool?> declaration,
  })  : declaration = Map<String, bool?>.unmodifiable(declaration),
        fingerprint = _fingerprint(declaration) {
    if (policyVersion.trim().isEmpty) {
      throw ArgumentError('Condition policy version is required');
    }
    if (declaration.keys.any((key) => key.trim().isEmpty)) {
      throw ArgumentError('Empty condition name');
    }
  }

  /// Reads the persisted declaration document.
  ///
  /// A missing document means no declarations. A present document with an
  /// unsupported `schemaVersion` or a malformed `conditions` value throws
  /// instead of being read as "no conditions".
  factory ConditionGuidanceInput.fromDeclarationDocument(
      Map<String, Object?>? document) {
    if (document == null) return ConditionGuidanceInput.empty();
    final schema = document['schemaVersion'];
    if (schema != null && (schema is! int || schema != 1)) {
      throw const FormatException('Unsupported health declaration schema');
    }
    final raw = document['conditions'];
    if (raw == null) return ConditionGuidanceInput.empty();
    if (raw is! Map) {
      throw const FormatException('Invalid condition declarations');
    }
    final declaration = <String, bool?>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || key.trim().isEmpty) {
        throw const FormatException('Invalid condition declarations');
      }
      if (value != null && value is! bool) {
        throw const FormatException('Invalid condition declarations');
      }
      declaration[key] = value as bool?;
    }
    return ConditionGuidanceInput(
      policyVersion: ConditionGuidancePolicy.version,
      declaration: declaration,
    );
  }

  factory ConditionGuidanceInput.empty() => ConditionGuidanceInput(
      policyVersion: ConditionGuidancePolicy.version, declaration: const {});

  /// Parses the plan-metadata form written by [toJson].
  factory ConditionGuidanceInput.fromJson(Map<String, Object?> json) {
    final version = json['policyVersion'];
    final raw = json['declaration'];
    if (version is! String || version.trim().isEmpty || raw is! Map) {
      throw const FormatException('Invalid condition guidance input');
    }
    final declaration = <String, bool?>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || key.trim().isEmpty) {
        throw const FormatException('Invalid condition guidance input');
      }
      if (value != null && value is! bool) {
        throw const FormatException('Invalid condition guidance input');
      }
      declaration[key] = value as bool?;
    }
    final input =
        ConditionGuidanceInput(policyVersion: version, declaration: declaration);
    final stored = json['declarationFingerprint'];
    if (stored is! String || stored != input.fingerprint) {
      throw const FormatException('Condition declaration fingerprint mismatch');
    }
    return input;
  }

  final String policyVersion;

  /// Raw stored condition values. `null` and a missing key both mean unknown.
  final Map<String, bool?> declaration;

  /// Canonical fingerprint over the explicit `true`/`false` choices in the raw
  /// declaration map. Null and a missing key are both unknown, so they do not
  /// change it; an unrecognized key declared true still does.
  final String fingerprint;

  static String _fingerprint(Map<String, bool?> declaration) {
    // Null and a missing key both mean unknown, so only explicit true/false
    // choices affect the fingerprint. Adding a new known condition name in a
    // later build therefore cannot invalidate an older plan by itself.
    final names = <String>{
      for (final entry in declaration.entries)
        if (entry.value != null) entry.key,
    }.toList()
      ..sort();
    return jsonEncode({for (final name in names) name: declaration[name]});
  }

  /// Conditions explicitly declared true by this build.
  Set<PlanningCondition> get declared => {
        for (final condition in PlanningCondition.values)
          if (declaration[condition.name] == true) condition,
      };

  /// Conditions the user explicitly marked false. Unknown stays unknown.
  Set<PlanningCondition> get absent => {
        for (final condition in PlanningCondition.values)
          if (declaration[condition.name] == false) condition,
      };

  /// Stored condition names this build does not understand and that the user
  /// declared true. They are never treated as absent.
  Set<String> get unrecognizedDeclared => {
        for (final entry in declaration.entries)
          if (PlanningCondition.byNameOrNull(entry.key) == null &&
              entry.value == true)
            entry.key,
      };

  bool get hasAnyDeclaration =>
      declared.isNotEmpty ||
      absent.isNotEmpty ||
      unrecognizedDeclared.isNotEmpty;

  /// True when both inputs describe the same declarations, regardless of
  /// policy version. Missing known names and explicit nulls are equal.
  bool sameDeclaration(ConditionGuidanceInput other) =>
      fingerprint == other.fingerprint;

  Map<String, Object?> toJson() => {
        'policyVersion': policyVersion,
        'declarationFingerprint': fingerprint,
        'declaration': declaration,
      };
}

/// The experimental condition-guidance policy.
///
/// This is active for private immediate-family testing only. It is not
/// approved clinical policy, not a diagnosis or treatment, and not a safety
/// guarantee. Hard allergen exclusions come only from the safety profile and
/// are never created or widened here.
abstract final class ConditionGuidancePolicy {
  static const version = 'condition-guidance-experimental-v1';
  static const scope = 'private-immediate-family-testing';
  static const experimental = true;
  static const clinicallyValidated = false;
  static const notice =
      'Experimental local-testing guidance. Not clinically validated, not '
      'medical advice or diagnosis, and no safety guarantee. Individual '
      'conditions, treatment, severity and combinations may change the '
      'appropriate advice.';

  /// Assesses declarations into relative soft directives plus source-linked
  /// explanations. High-risk conflicts abstain instead of ranking.
  ///
  /// [eatingConcern] is the safety profile's recorded concern. It is treated as
  /// an equivalent support-mode signal to a declared eating-disorder concern,
  /// even when the declaration checkbox is absent; it never creates exclusions.
  static ConditionGuidanceAssessment assess({
    required ConditionGuidanceInput input,
    required Set<String> strictExclusions,
    bool eatingConcern = false,
  }) {
    if (input.policyVersion != version) {
      throw ArgumentError('STALE_CONDITION_GUIDANCE_POLICY');
    }
    final declared = input.declared;
    final exclusions = {
      for (final value in strictExclusions)
        if (value.trim().isNotEmpty) value.trim(),
    };
    final directives = <ConditionGuidanceDirective>[];
    final explanations = <ConditionGuidanceExplanation>[];
    final display = <NutrientKey>{};

    final declaredEd =
        declared.contains(PlanningCondition.eatingDisorderConcerns);
    // A recorded safety-profile eating concern is an equivalent support-mode
    // signal. It withholds restrictive condition guidance even when the
    // condition checkbox is absent, and it never creates exclusions.
    final ed = declaredEd || eatingConcern;
    final edConflictCode = declaredEd
        ? 'EATING_DISORDER_CONFLICT_RESTRICTIVE_GUIDANCE'
        : 'SAFETY_EATING_CONCERN_CONFLICT_RESTRICTIVE_GUIDANCE';
    final lowGlucose =
        declared.contains(PlanningCondition.lowBloodGlucoseHistoryOrRisk);
    final ckd = declared.contains(PlanningCondition.chronicKidneyDisease);

    void addDirective(ConditionGuidanceDirective directive) {
      directives.add(directive);
      display.add(directive.nutrient);
    }

    void addExplanation({
      required String code,
      required PlanningCondition? condition,
      required GuidanceState state,
      required List<ConditionGuidanceSource> sources,
      List<NutrientKey> nutrients = const [],
      required String limitation,
    }) {
      explanations.add(ConditionGuidanceExplanation(
        code: code,
        condition: condition,
        state: state,
        sources: sources,
        nutrients: nutrients,
        limitation: limitation,
      ));
      display.addAll(nutrients);
    }

    if (declared.contains(PlanningCondition.highCholesterol)) {
      if (ed) {
        addExplanation(
          code: edConflictCode,
          condition: PlanningCondition.highCholesterol,
          state: GuidanceState.abstainedConflict,
          sources: const [
            ConditionGuidanceSources.ahaFats,
            ConditionGuidanceSources.nimhEatingDisorders,
          ],
          nutrients: const [NutrientKey.saturatedFatG],
          limitation:
              'No saturated-fat-restriction ranking is applied while an '
              'eating-disorder or safety-profile eating concern is recorded. '
              'This is not a diagnosis and no automatic restriction or '
              'weight-loss coaching is added.',
        );
      } else {
        addDirective(const ConditionGuidanceDirective(
          condition: PlanningCondition.highCholesterol,
          nutrient: NutrientKey.saturatedFatG,
          direction: GuidanceDirection.lower,
          ruleCode: 'CHOLESTEROL_LOWER_SATURATED_FAT',
          sources: [ConditionGuidanceSources.ahaFats],
          limitation:
              'Total fat is never treated as saturated fat. No clinical '
              'outcome is promised, and missing values are not zero.',
        ));
        addExplanation(
          code: 'CHOLESTEROL_LOWER_SATURATED_FAT',
          condition: PlanningCondition.highCholesterol,
          state: GuidanceState.applied,
          sources: const [ConditionGuidanceSources.ahaFats],
          nutrients: const [NutrientKey.saturatedFatG],
          limitation:
              'Relative soft preference only: lower saturated-fat meals are '
              'preferred when comparable. Total fat is not excluded, and no '
              'clinical outcome is promised.',
        );
      }
    }

    if (declared.contains(PlanningCondition.highTriglycerides)) {
      if (ed) {
        addExplanation(
          code: edConflictCode,
          condition: PlanningCondition.highTriglycerides,
          state: GuidanceState.abstainedConflict,
          sources: const [
            ConditionGuidanceSources.ahaCarbohydrates,
            ConditionGuidanceSources.ahaFats,
            ConditionGuidanceSources.nimhEatingDisorders,
          ],
          nutrients: const [
            NutrientKey.freeSugarsG,
            NutrientKey.saturatedFatG,
          ],
          limitation:
              'No sugar- or fat-restriction ranking is applied while an '
              'eating-disorder or safety-profile eating concern is recorded.',
        );
      } else {
        if (lowGlucose) {
          addExplanation(
            code: 'HYPOGLYCAEMIA_CONFLICT_SUGAR_RESTRICTION',
            condition: PlanningCondition.highTriglycerides,
            state: GuidanceState.abstainedConflict,
            sources: const [
              ConditionGuidanceSources.ahaCarbohydrates,
              ConditionGuidanceSources.niddkLowBloodGlucose,
            ],
            nutrients: const [NutrientKey.freeSugarsG],
            limitation:
                'Lower-added-sugar ranking is not applied while a history or '
                'risk of low blood glucose is declared. Blanket sugar '
                'avoidance is not a condition-specific strategy.',
          );
        } else {
          addDirective(const ConditionGuidanceDirective(
            condition: PlanningCondition.highTriglycerides,
            nutrient: NutrientKey.freeSugarsG,
            direction: GuidanceDirection.lower,
            ruleCode: 'TRIGLYCERIDES_LOWER_FREE_SUGARS',
            sources: [ConditionGuidanceSources.ahaCarbohydrates],
            limitation:
                'Uses only free/added-sugar values supplied by the source. '
                'Total sugars are never reclassified as added sugars, and '
                'refined-carbohydrate classification is unavailable.',
          ));
          addExplanation(
            code: 'TRIGLYCERIDES_LOWER_FREE_SUGARS',
            condition: PlanningCondition.highTriglycerides,
            state: GuidanceState.applied,
            sources: const [ConditionGuidanceSources.ahaCarbohydrates],
            nutrients: const [NutrientKey.freeSugarsG],
            limitation:
                'Relative soft preference only. Free sugars are used when '
                'known; total sugars are not proof of added sugars. Very high '
                'triglycerides may need individualized advice; severity is '
                'not inferred.',
          );
        }
        addDirective(const ConditionGuidanceDirective(
          condition: PlanningCondition.highTriglycerides,
          nutrient: NutrientKey.saturatedFatG,
          direction: GuidanceDirection.lower,
          ruleCode: 'TRIGLYCERIDES_LOWER_SATURATED_FAT',
          sources: [ConditionGuidanceSources.ahaFats],
          limitation:
              'Saturated and unsaturated fats are not the same field. This '
              'does not exclude all carbohydrate or fat and promises no '
              'clinical outcome.',
        ));
        addExplanation(
          code: 'TRIGLYCERIDES_LOWER_SATURATED_FAT',
          condition: PlanningCondition.highTriglycerides,
          state: GuidanceState.applied,
          sources: const [ConditionGuidanceSources.ahaFats],
          nutrients: const [NutrientKey.saturatedFatG],
          limitation:
              'Relative soft preference only: lower saturated fat is '
              'considered rather than excluding all carbohydrate or fat. '
              'Unsaturated-fat values are not synthesized when absent.',
        );
      }
    }

    if (declared.contains(PlanningCondition.diabetes)) {
      display.add(NutrientKey.carbohydrateG);
      addExplanation(
        code: 'DIABETES_SHOW_CARBOHYDRATE',
        condition: PlanningCondition.diabetes,
        state: GuidanceState.notice,
        sources: const [
          ConditionGuidanceSources.adaFruit,
          ConditionGuidanceSources.niddkDiabetes,
        ],
        nutrients: const [NutrientKey.carbohydrateG],
        limitation:
            'Known meal carbohydrate is displayed with its source definition. '
            'No universal carbohydrate target or ban on whole fruit is '
            'imposed. Total sugars are not added sugars.',
      );
      if (ed || lowGlucose) {
        addExplanation(
          code: ed
              ? edConflictCode
              : 'HYPOGLYCAEMIA_CONFLICT_SUGAR_RESTRICTION',
          condition: PlanningCondition.diabetes,
          state: GuidanceState.abstainedConflict,
          sources: ed
              ? const [
                  ConditionGuidanceSources.nimhEatingDisorders,
                  ConditionGuidanceSources.niddkDiabetes,
                ]
              : const [
                  ConditionGuidanceSources.niddkLowBloodGlucose,
                  ConditionGuidanceSources.niddkDiabetes,
                ],
          nutrients: const [NutrientKey.freeSugarsG, NutrientKey.fiberG],
          limitation: ed
              ? 'No lower-sugar or higher-fibre ranking is applied while an '
                  'eating-disorder or safety-profile eating concern is '
                  'recorded.'
              : 'Lower-added-sugar and higher-fibre ranking is not applied '
                  'while a history or risk of low blood glucose is declared; '
                  'diabetes guidance must not override low-glucose safety.',
        );
      } else {
        addDirective(const ConditionGuidanceDirective(
          condition: PlanningCondition.diabetes,
          nutrient: NutrientKey.freeSugarsG,
          direction: GuidanceDirection.lower,
          ruleCode: 'DIABETES_LOWER_FREE_SUGARS',
          sources: [
            ConditionGuidanceSources.adaFruit,
            ConditionGuidanceSources.niddkDiabetes,
          ],
          limitation:
              'Only free/added-sugar values supplied by the source are used. '
              'Total sugars are never treated as added sugars.',
        ));
        addExplanation(
          code: 'DIABETES_LOWER_FREE_SUGARS',
          condition: PlanningCondition.diabetes,
          state: GuidanceState.applied,
          sources: const [
            ConditionGuidanceSources.adaFruit,
            ConditionGuidanceSources.niddkDiabetes,
          ],
          nutrients: const [NutrientKey.freeSugarsG],
          limitation:
              'Relative soft preference only; no universal carbohydrate '
              'target is imposed and whole fruit is not banned. Missing free '
              'sugar data is unknown, not zero.',
        );
        addDirective(const ConditionGuidanceDirective(
          condition: PlanningCondition.diabetes,
          nutrient: NutrientKey.fiberG,
          direction: GuidanceDirection.higher,
          ruleCode: 'DIABETES_HIGHER_FIBER',
          sources: [ConditionGuidanceSources.niddkDiabetes],
          limitation:
              'Relative soft preference for fibre-containing choices when '
              'fibre is known; no fibre target is invented.',
        ));
        addExplanation(
          code: 'DIABETES_HIGHER_FIBER',
          condition: PlanningCondition.diabetes,
          state: GuidanceState.applied,
          sources: const [ConditionGuidanceSources.niddkDiabetes],
          nutrients: const [NutrientKey.fiberG],
          limitation:
              'Relative soft preference only. A missing fibre value is never '
              'ranked as a low value or as healthy.',
        );
      }
    }

    if (lowGlucose) {
      addExplanation(
        code: 'HYPOGLYCAEMIA_NO_BLANKET_RESTRICTION',
        condition: PlanningCondition.lowBloodGlucoseHistoryOrRisk,
        state: GuidanceState.noTailoredRecommendation,
        sources: const [ConditionGuidanceSources.niddkLowBloodGlucose],
        limitation:
            'No fasting, skipped-meal or blanket sugar-avoidance advice is '
            'generated. Timing may depend on treatment and circumstances. '
            'Ordinary meal planning is not a response to an active '
            'low-glucose event, and no laboratory value is inferred.',
      );
    }

    if (declared.contains(PlanningCondition.highBloodPressure)) {
      display.add(NutrientKey.sodiumMg);
      if (ed) {
        addExplanation(
          code: edConflictCode,
          condition: PlanningCondition.highBloodPressure,
          state: GuidanceState.abstainedConflict,
          sources: const [
            ConditionGuidanceSources.nhlbiDash,
            ConditionGuidanceSources.nimhEatingDisorders,
          ],
          nutrients: const [NutrientKey.sodiumMg],
          limitation:
              'No sodium-lowering ranking is applied while an eating-disorder '
              'concern is declared.',
        );
      } else if (ckd) {
        addExplanation(
          code: 'BLOOD_PRESSURE_KIDNEY_CONFLICT',
          condition: PlanningCondition.highBloodPressure,
          state: GuidanceState.abstainedConflict,
          sources: const [
            ConditionGuidanceSources.nhlbiDash,
            ConditionGuidanceSources.niddkCkd,
          ],
          nutrients: const [NutrientKey.sodiumMg],
          limitation:
              'Sodium-lowering ranking is not applied while chronic kidney '
              'disease is declared. No potassium salt substitute is '
              'recommended; kidney-related restrictions need specialist '
              'review and cannot be inferred.',
        );
      } else {
        addDirective(const ConditionGuidanceDirective(
          condition: PlanningCondition.highBloodPressure,
          nutrient: NutrientKey.sodiumMg,
          direction: GuidanceDirection.lower,
          ruleCode: 'BLOOD_PRESSURE_LOWER_SODIUM',
          sources: [ConditionGuidanceSources.nhlbiDash],
          limitation:
              'Relative soft preference for lower-sodium alternatives when '
              'comparable and known. No potassium salt substitute is '
              'recommended and no sodium limit is invented.',
        ));
        addExplanation(
          code: 'BLOOD_PRESSURE_LOWER_SODIUM',
          condition: PlanningCondition.highBloodPressure,
          state: GuidanceState.applied,
          sources: const [ConditionGuidanceSources.nhlbiDash],
          nutrients: const [NutrientKey.sodiumMg],
          limitation:
              'Relative soft preference only, when known values and other '
              'constraints permit. No automatic potassium salt substitute is '
              'recommended; kidney disease and other circumstances matter.',
        );
      }
    }

    if (ckd) {
      addExplanation(
        code: 'KIDNEY_NO_INFERRED_LIMITS',
        condition: PlanningCondition.chronicKidneyDisease,
        state: GuidanceState.noTailoredRecommendation,
        sources: const [ConditionGuidanceSources.niddkCkd],
        limitation:
            'No protein, potassium, phosphorus, sodium or fluid limit is '
            'inferred from the declaration. Only explicit user- or '
            'clinician-provided constraints would be honored; qualified '
            'advice is required for kidney-related nutrition.',
      );
    }

    if (declaredEd) {
      addExplanation(
        code: 'EATING_DISORDER_SUPPORTIVE_ONLY',
        condition: PlanningCondition.eatingDisorderConcerns,
        state: GuidanceState.noTailoredRecommendation,
        sources: const [ConditionGuidanceSources.nimhEatingDisorders],
        limitation:
            'No automatic restriction, weight-loss coaching or punitive '
            'presentation is applied. This is a product safety choice, not a '
            'diagnosis, and a weight category never infers an eating '
            'disorder.',
      );
    } else if (eatingConcern) {
      addExplanation(
        code: 'SAFETY_EATING_CONCERN_SUPPORTIVE_ONLY',
        condition: null,
        state: GuidanceState.noTailoredRecommendation,
        sources: const [ConditionGuidanceSources.nimhEatingDisorders],
        limitation:
            'A safety-profile eating concern is recorded. No restrictive '
            'condition guidance, weight-loss coaching or generated '
            'calorie-pressure prompt is applied, and this is not a diagnosis.',
      );
    }

    if (declared.contains(PlanningCondition.lactoseIntolerance)) {
      addExplanation(
        code: exclusions.isEmpty
            ? 'LACTOSE_NO_AUTOMATIC_EXCLUSION'
            : 'LACTOSE_EXCLUSIONS_ENFORCED',
        condition: PlanningCondition.lactoseIntolerance,
        state: exclusions.isEmpty
            ? GuidanceState.noTailoredRecommendation
            : GuidanceState.exclusionsEnforced,
        sources: const [ConditionGuidanceSources.niddkLactose],
        limitation:
            'Lactose content is not modeled and dairy is not excluded '
            'automatically. Only explicit user exclusions are enforced; '
            'lactose intolerance is not milk allergy and tolerance varies.',
      );
    }

    if (declared.contains(PlanningCondition.gout)) {
      addExplanation(
        code: 'GOUT_NO_PURINE_DATA',
        condition: PlanningCondition.gout,
        state: GuidanceState.noTailoredRecommendation,
        sources: const [ConditionGuidanceSources.niamsGout],
        limitation:
            'Purine content and a reviewed beverage/food classification are '
            'not available. All protein is not banned, and diet alone is not '
            'claimed to treat gout.',
      );
    }

    if (declared.contains(PlanningCondition.irritableBowelSyndrome)) {
      addExplanation(
        code: exclusions.isEmpty
            ? 'IBS_NO_UNIVERSAL_TRIGGERS'
            : 'IBS_EXCLUSIONS_ENFORCED',
        condition: PlanningCondition.irritableBowelSyndrome,
        state: exclusions.isEmpty
            ? GuidanceState.noTailoredRecommendation
            : GuidanceState.exclusionsEnforced,
        sources: const [ConditionGuidanceSources.niddkIbs],
        limitation:
            'There is no universal trigger list. No low-FODMAP, gluten-free '
            'or other restrictive diet is prescribed automatically; only '
            'explicit user exclusions are enforced.',
      );
    }

    if (declared.contains(PlanningCondition.foodAllergy)) {
      // The declaration format does not store which allergen was declared, so
      // no exclusion can be proven to match it. Even with explicit exclusions,
      // coverage stays unassessed rather than implied.
      addExplanation(
        code: exclusions.isEmpty
            ? 'ALLERGY_REQUIRES_EXPLICIT_EXCLUSION'
            : 'ALLERGY_COVERAGE_UNASSESSED',
        condition: PlanningCondition.foodAllergy,
        state: GuidanceState.requiresExplicitExclusion,
        sources: const [
          ConditionGuidanceSources.euAllergens,
          ConditionGuidanceSources.fdaAllergies,
        ],
        limitation: exclusions.isEmpty
            ? 'An allergy declaration without a specific allergen exclusion '
                'cannot be enforced. No exclusion was inferred. Name the '
                'allergen in strict exclusions; labels and cross-contact must '
                'be checked independently, and no safety is guaranteed.'
            : 'Declared exclusions remain hard constraints, but the '
                'declaration does not store the allergen identity. No '
                'exclusion can be proven to match the declared allergy, so '
                'coverage is unassessed. Verify the specific allergen is '
                'listed; labels and cross-contact are not certified, and no '
                'safety is guaranteed.',
      );
    }

    if (declared.contains(PlanningCondition.coeliacDisease)) {
      final glutenEnforced = hasGlutenExclusion(exclusions);
      addExplanation(
        code: glutenEnforced
            ? 'COELIAC_EXCLUSIONS_ENFORCED'
            : 'COELIAC_REQUIRES_GLUTEN_EXCLUSION',
        condition: PlanningCondition.coeliacDisease,
        state: glutenEnforced
            ? GuidanceState.exclusionsEnforced
            : GuidanceState.requiresExplicitExclusion,
        sources: const [
          ConditionGuidanceSources.niddkCoeliac,
          ConditionGuidanceSources.euAllergens,
        ],
        limitation: glutenEnforced
            ? 'An explicit gluten-related exclusion is hard-enforced. '
                'Cross-contact, hidden sources and processed-food safety are '
                'not certified, and unknown gluten status cannot establish '
                'eligibility.'
            : 'A coeliac declaration alone does not add a gluten exclusion. '
                'State wheat, barley, rye or gluten explicitly in strict '
                'exclusions. Unknown gluten status cannot establish '
                'eligibility, and no exclusion was inferred.',
      );
    }

    if (input.unrecognizedDeclared.isNotEmpty) {
      addExplanation(
        code: 'UNRECOGNIZED_CONDITION_DECLARED',
        condition: null,
        state: GuidanceState.noTailoredRecommendation,
        sources: const [],
        limitation:
            'At least one declared condition is not understood by this build. '
            'It was not treated as absent and no recommendation was derived. '
            'Update the app or consult a qualified professional.',
      );
    }

    // A high-risk conflict is not resolved by ranking another condition as if
    // the combination had been assessed. Withhold every relative directive and
    // state that the applied-condition rules were withheld.
    if (explanations
        .any((e) => e.state == GuidanceState.abstainedConflict)) {
      final withheld = <ConditionGuidanceExplanation>[];
      for (final explanation in explanations) {
        if (explanation.state != GuidanceState.applied) {
          withheld.add(explanation);
          continue;
        }
        withheld.add(ConditionGuidanceExplanation(
          code: 'CONDITION_GUIDANCE_WITHHELD_CONFLICT',
          condition: explanation.condition,
          state: GuidanceState.abstainedConflict,
          sources: explanation.sources,
          nutrients: explanation.nutrients,
          limitation:
              'This relative rule was withheld because a high-risk condition '
              'conflict is declared. No compromise is invented and no '
              'condition ranking is applied.',
        ));
      }
      directives.clear();
      explanations
        ..clear()
        ..addAll(withheld);
      // Keep only the neutral known-carbohydrate notice; no decisive nutrient
      // that a withheld rule would have ranked is presented as monitoring.
      display.retainWhere((key) =>
          key == NutrientKey.carbohydrateG &&
          declared.contains(PlanningCondition.diabetes));
    }

    final orderedDisplay = display.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return ConditionGuidanceAssessment._(
      input: input,
      strictExclusions: exclusions,
      directives: directives,
      explanations: explanations,
      displayNutrients: orderedDisplay.toSet(),
      abstained:
          explanations.any((e) => e.state == GuidanceState.abstainedConflict),
      requiresExplicitExclusion: explanations
          .any((e) => e.state == GuidanceState.requiresExplicitExclusion),
    );
  }

  /// True when an explicit exclusion names a gluten-related grain or the
  /// condition itself. Whole-word matching avoids treating "buckwheat" as
  /// "wheat".
  static bool hasGlutenExclusion(Set<String> exclusions) {
    const tokens = {
      'gluten',
      'wheat',
      'barley',
      'rye',
      'triticale',
      'spelt',
      'kamut',
      'semolina',
      'couscous',
      'bulgur',
      'malt',
      'celiac',
      'coeliac',
    };
    final words = RegExp(r'[a-z0-9]+');
    for (final exclusion in exclusions) {
      final normalized = exclusion.toLowerCase();
      for (final match in words.allMatches(normalized)) {
        if (tokens.contains(match.group(0))) return true;
      }
    }
    return false;
  }

  static String exclusionFingerprint(Set<String> exclusions) => jsonEncode(
      (exclusions.map((e) => e.trim()).where((e) => e.isNotEmpty).toList()
        ..sort()));
}

/// Result of assessing declarations against the experimental policy.
final class ConditionGuidanceAssessment {
  ConditionGuidanceAssessment._({
    required this.input,
    required Set<String> strictExclusions,
    required List<ConditionGuidanceDirective> directives,
    required List<ConditionGuidanceExplanation> explanations,
    required Set<NutrientKey> displayNutrients,
    required this.abstained,
    required this.requiresExplicitExclusion,
  })  : strictExclusions = Set<String>.unmodifiable(strictExclusions),
        directives = List<ConditionGuidanceDirective>.unmodifiable(directives),
        explanations =
            List<ConditionGuidanceExplanation>.unmodifiable(explanations),
        displayNutrients = Set<NutrientKey>.unmodifiable(displayNutrients);

  final ConditionGuidanceInput input;
  final Set<String> strictExclusions;
  final List<ConditionGuidanceDirective> directives;
  final List<ConditionGuidanceExplanation> explanations;
  final Set<NutrientKey> displayNutrients;

  /// A high-risk condition conflict suppressed every relative directive.
  /// The conflict is never resolved by ranking another condition as if the
  /// combination had been assessed.
  final bool abstained;

  /// A declared allergy/coeliac condition lacks a matching explicit strict
  /// exclusion.
  final bool requiresExplicitExclusion;

  bool get hasDeclaredConditions =>
      input.declared.isNotEmpty || input.unrecognizedDeclared.isNotEmpty;

  bool get isEmpty =>
      !hasDeclaredConditions && directives.isEmpty && explanations.isEmpty;

  /// Conditions that explicitly received no tailored recommendation in this
  /// assessment (as opposed to a relative soft directive).
  Set<PlanningCondition> get untailoredConditions {
    final withDirective = {
      for (final directive in directives) directive.condition,
    };
    return {
      for (final explanation in explanations)
        if (explanation.condition != null &&
            !withDirective.contains(explanation.condition) &&
            (explanation.state == GuidanceState.noTailoredRecommendation ||
                explanation.state ==
                    GuidanceState.requiresExplicitExclusion ||
                explanation.state == GuidanceState.abstainedConflict))
          explanation.condition!,
    };
  }

  String get strictExclusionFingerprint =>
      ConditionGuidancePolicy.exclusionFingerprint(strictExclusions);
}

/// One planned meal's nutrient data as seen by condition guidance.
final class ConditionGuidanceMealData {
  const ConditionGuidanceMealData({
    required this.ingredientsResolved,
    required this.nutrients,
  });
  final bool ingredientsResolved;
  final Map<NutrientKey, NutrientSum> nutrients;
}

/// Data availability for one directive over the selected meals.
final class ConditionGuidanceDirectiveEvidence {
  const ConditionGuidanceDirectiveEvidence({
    required this.directive,
    required this.mealCount,
    required this.knownMeals,
    required this.unknownMeals,
  });
  final ConditionGuidanceDirective directive;
  final int mealCount, knownMeals, unknownMeals;

  GuidanceState get state => knownMeals == 0
      ? GuidanceState.insufficientData
      : unknownMeals == 0
          ? GuidanceState.applied
          : GuidanceState.partialData;
}

/// Evaluation of an assessment over a concrete set of planned meals.
///
/// It reports how much decisive data exists. It never fills a missing nutrient,
/// never treats unknown as zero or as healthier, and never states that a meal is
/// safe for a condition.
final class ConditionGuidanceReport {
  ConditionGuidanceReport._({
    required this.assessment,
    required List<ConditionGuidanceDirectiveEvidence> evidence,
    required List<ConditionGuidanceExplanation> explanations,
    required this.mealCount,
  })  : evidence = List<ConditionGuidanceDirectiveEvidence>.unmodifiable(
            evidence),
        explanations =
            List<ConditionGuidanceExplanation>.unmodifiable(explanations);

  factory ConditionGuidanceReport.evaluate(
      ConditionGuidanceAssessment assessment,
      List<ConditionGuidanceMealData> meals) {
    final evidence = <ConditionGuidanceDirectiveEvidence>[];
    final dataNotes = <ConditionGuidanceExplanation>[];
    final byNutrient = <NutrientKey, ConditionGuidanceDirective>{};
    final conflicting = <NutrientKey>{};
    for (final directive in assessment.directives) {
      final prior = byNutrient[directive.nutrient];
      if (prior == null) {
        byNutrient[directive.nutrient] = directive;
      } else if (prior.direction != directive.direction) {
        conflicting.add(directive.nutrient);
      }
    }
    final nutrients = byNutrient.keys
        .where((key) => !conflicting.contains(key))
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    for (final nutrient in nutrients) {
      final directive = byNutrient[nutrient]!;
      var known = 0;
      for (final meal in meals) {
        if (_isKnown(meal, nutrient)) known++;
      }
      final unknown = meals.length - known;
      final item = ConditionGuidanceDirectiveEvidence(
        directive: directive,
        mealCount: meals.length,
        knownMeals: known,
        unknownMeals: unknown,
      );
      evidence.add(item);
      if (known == 0) {
        dataNotes.add(ConditionGuidanceExplanation(
          code: 'CONDITION_NUTRIENT_DATA_INSUFFICIENT',
          condition: directive.condition,
          state: GuidanceState.insufficientData,
          sources: directive.sources,
          nutrients: [nutrient],
          limitation:
              'No selected meal has a usable ${nutrient.wire} value. Missing '
              'data stays unknown; it is not zero and does not establish '
              'suitability. No tailored recommendation can be stated for this '
              'rule.',
        ));
      } else if (unknown > 0) {
        dataNotes.add(ConditionGuidanceExplanation(
          code: 'CONDITION_NUTRIENT_DATA_PARTIAL',
          condition: directive.condition,
          state: GuidanceState.partialData,
          sources: directive.sources,
          nutrients: [nutrient],
          limitation:
              '$unknown of ${meals.length} selected meals lack a usable '
              '${nutrient.wire} value. Unknown values were not treated as zero '
              'or as healthier, and no tailored claim covers them.',
        ));
      }
    }
    return ConditionGuidanceReport._(
      assessment: assessment,
      evidence: evidence,
      explanations: [...assessment.explanations, ...dataNotes],
      mealCount: meals.length,
    );
  }

  static bool _isKnown(ConditionGuidanceMealData meal, NutrientKey key) {
    if (!meal.ingredientsResolved) return false;
    final nutrient = meal.nutrients[key];
    return nutrient != null &&
        nutrient.knownEntries > 0 &&
        nutrient.isComplete &&
        !nutrient.includesEstimate;
  }

  final ConditionGuidanceAssessment assessment;
  final List<ConditionGuidanceDirectiveEvidence> evidence;
  final List<ConditionGuidanceExplanation> explanations;
  final int mealCount;

  Set<NutrientKey> get displayNutrients => assessment.displayNutrients;

  /// True when at least one relative directive has usable data for a selected
  /// meal. This still does not mean the plan is tailored for every declared
  /// condition, safe or clinically suitable.
  bool get hasTailoredGuidance =>
      evidence.any((item) => item.knownMeals > 0);

  /// True when every relative directive lacked usable data for all selected
  /// meals. Generic organization must not be presented as tailored.
  bool get allDirectiveDataInsufficient =>
      evidence.isNotEmpty && evidence.every((item) => item.knownMeals == 0);

  bool get hasPartialDirectiveData =>
      evidence.any((item) => item.knownMeals > 0 && item.unknownMeals > 0);

  /// Conditions that received no relative directive: no suitable tailored rule,
  /// a conflict abstention, or missing matching exclusions.
  Set<PlanningCondition> get untailoredConditions =>
      assessment.untailoredConditions;
}
