import 'health_declarations.dart';
import 'nutrition_contract.dart';
import 'nutrition_profile.dart';
/// Declarations are not assessments; null never certifies eligibility.
final class SafetyProfile {
  const SafetyProfile(
      {this.adult,
      this.pregnant,
      this.breastfeeding,
      this.clinicalNeed,
      this.eatingConcern,
      this.relevantMedication,
      this.symptoms = false,
      this.strictExclusions = const {}});
  final bool? adult,
      pregnant,
      breastfeeding,
      clinicalNeed,
      eatingConcern,
      relevantMedication;
  final bool symptoms;
  final Set<String> strictExclusions;
  Map<String, Object?> toJson() => {
        'adult': adult,
        'pregnant': pregnant,
        'breastfeeding': breastfeeding,
        'clinicalNeed': clinicalNeed,
        'eatingConcern': eatingConcern,
        'relevantMedication': relevantMedication,
        'symptoms': symptoms,
        'strictExclusions': strictExclusions.toList()
      };
  factory SafetyProfile.fromJson(Map<String, Object?> j) => SafetyProfile(
      adult: j['adult'] as bool?,
      pregnant: j['pregnant'] as bool?,
      breastfeeding: j['breastfeeding'] as bool?,
      clinicalNeed: j['clinicalNeed'] as bool?,
      eatingConcern: j['eatingConcern'] as bool?,
      relevantMedication: j['relevantMedication'] as bool?,
      symptoms: j['symptoms'] == true,
      strictExclusions:
          (j['strictExclusions'] as List? ?? []).cast<String>().toSet());
}

final class EligibilityDecision {
  EligibilityDecision(
      {required this.reasonCodes,
      required this.supportMode,
      required this.personalReferences,
      required this.seekAdvice});
  static const policyVersion = 'eligibility-draft-v2-unapproved';
  final List<String> reasonCodes;
  final bool supportMode, personalReferences, seekAdvice;
  bool get recordingAllowed => true;
}

final class EligibilityService {
  const EligibilityService();
  EligibilityDecision evaluate(SafetyProfile p) {
    final reasons = <String>[
      if (p.adult == false) 'MINOR',
      if (p.pregnant == true) 'PREGNANCY',
      if (p.breastfeeding == true) 'BREASTFEEDING',
      if (p.clinicalNeed == true) 'CLINICAL_NUTRITION',
      if (p.eatingConcern == true) 'SUPPORT_REQUESTED',
      if (p.relevantMedication == true) 'MEDICATION_REVIEW',
      if (p.symptoms) 'SYMPTOMS_REVIEW',
      if ([
        p.adult,
        p.pregnant,
        p.breastfeeding,
        p.clinicalNeed,
        p.eatingConcern,
        p.relevantMedication
      ].any((v) => v == null))
        'DECLARATIONS_INCOMPLETE',
    ];
    final routed = p.adult != true ||
        p.pregnant != false ||
        p.breastfeeding != false ||
        p.clinicalNeed != false ||
        p.eatingConcern != false ||
        p.relevantMedication != false ||
        p.symptoms;
    return EligibilityDecision(
        reasonCodes: List.unmodifiable(reasons),
        supportMode: p.eatingConcern == true,
        personalReferences: !routed,
        seekAdvice: p.symptoms ||
            p.clinicalNeed == true ||
            p.eatingConcern == true ||
            p.relevantMedication == true);
  }
}

enum TargetOrigin { userDeclared, clinicianProvided, calculatedEstimate }

/// Typed failure for starting-estimate calculation.
///
/// `TARGET_INPUT_REQUIRED` carries the exact [NutritionProfile] field names
/// the caller must ask for; nothing here is inferred. `TARGET_CONFLICT`
/// means the complete inputs cannot produce a usable target.
final class TargetEstimateException implements Exception {
  TargetEstimateException(this.code, {this.missingInputs = const []});
  final String code;
  final List<String> missingInputs;
  @override
  String toString() =>
      'TargetEstimateException($code, missingInputs: $missingInputs)';
}

final class DeclaredTarget {
  DeclaredTarget(
      {required this.id,
      required this.revision,
      required this.origin,
      required this.effectiveDate,
      required this.policyVersion,
      required this.energyKcal,
      this.proteinG,
      this.fatG,
      this.carbohydrateG,
      this.formulaVersion,
      this.assumptions,
      this.active = true}) {
    if (id.isEmpty ||
        revision < 1 ||
        !energyKcal.positive ||
        [proteinG, fatG, carbohydrateG]
            .any((x) => x != null && x.compareTo(Exact.zero) < 0)) {
      throw ArgumentError('Invalid target');
    }
    final macroEnergy = (proteinG ?? Exact.zero) * Exact.parse('4') +
        (fatG ?? Exact.zero) * Exact.parse('9') +
        (carbohydrateG ?? Exact.zero) * Exact.parse('4');
    if (macroEnergy.compareTo(energyKcal) > 0) {
      throw StateError('TARGET_CONFLICT');
    }
  }
  final String id, effectiveDate, policyVersion;
  final String? formulaVersion;
  final Map<String, Object?>? assumptions;
  final int revision;
  final TargetOrigin origin;
  final Exact energyKcal;
  final Exact? proteinG, fatG, carbohydrateG;
  final bool active;
  Map<String, Object?> toJson() => {
        'id': id,
        'revision': revision,
        'origin': origin.name,
        'effectiveDate': effectiveDate,
        'policyVersion': policyVersion,
        'energyKcal': energyKcal.toJson(),
        'proteinG': proteinG?.toJson(),
        'fatG': fatG?.toJson(),
        'carbohydrateG': carbohydrateG?.toJson(),
        if (formulaVersion != null) 'formulaVersion': formulaVersion,
        if (assumptions != null) 'assumptions': assumptions,
        'active': active
      };
  factory DeclaredTarget.fromJson(Map<String, Object?> j) {
    Exact? amount(String key) => j[key] == null
        ? null
        : Exact.fromJson(Map<String, Object?>.from(j[key]! as Map));
    Map<String, Object?>? provenance(String key) =>
        j[key] == null
            ? null
            : Map<String, Object?>.from(j[key]! as Map);
    return DeclaredTarget(
        id: j['id']! as String,
        revision: j['revision']! as int,
        origin: TargetOrigin.values.byName(j['origin']! as String),
        effectiveDate: j['effectiveDate']! as String,
        policyVersion: j['policyVersion']! as String,
        energyKcal: amount('energyKcal')!,
        proteinG: amount('proteinG'),
        fatG: amount('fatG'),
        carbohydrateG: amount('carbohydrateG'),
        formulaVersion: j['formulaVersion'] as String?,
        assumptions: provenance('assumptions'),
        active: j['active'] == true);
  }
}

final class TargetService {
  const TargetService();
  static const startingEstimatePolicyVersion = 'starting-estimate-v1';
  static const formulaVersion = 'mifflin-st-jeor-v1';

  /// Exact Mifflin-St Jeor starting estimate.
  ///
  /// `RMR = 10*weightKg + 6.25*heightCm - 5*ageYears + equationConstant`,
  /// maintenance is `RMR * activityPal` (no exercise add-back), goal
  /// multipliers are lose `0.90`, maintain/notDeclared `1.00`, gain `1.05`.
  /// Protein is `max(0.83*weightKg, 0.15*energy/4)`, fat is `0.30*energy/9`,
  /// carbohydrate is `(energy - 4*protein - 9*fat - 50)/4` with the 50-kcal
  /// fibre allocation kept explicit. Non-positive energy or negative
  /// carbohydrate throws `TARGET_CONFLICT`; missing inputs throw
  /// `TARGET_INPUT_REQUIRED` with exact profile field names.
  DeclaredTarget generateAutomaticTarget(
      {required NutritionProfile profile,
      required String id,
      required int revision,
      required String effectiveDate}) {
    final missing = <String>[
      if (profile.ageYears == null) 'ageYears',
      if (profile.heightCm == null) 'heightCm',
      if (profile.weightKg == null) 'weightKg',
      if (profile.equationConstant == null) 'equationConstant',
      if (profile.activityPal == null) 'activityPal',
    ];
    if (missing.isNotEmpty) {
      throw TargetEstimateException('TARGET_INPUT_REQUIRED',
          missingInputs: List.unmodifiable(missing));
    }
    final age = profile.ageYears!;
    final height = profile.heightCm!;
    final weight = profile.weightKg!;
    final constant = Exact.parse('${profile.equationConstant!}');
    final pal = profile.activityPal!;
    final rmr = Exact.parse('10') * weight +
        Exact.parse('6.25') * height -
        Exact.parse('5') * Exact.parse('$age') +
        constant;
    final maintenance = rmr * pal;
    final multiplier = switch (profile.goal) {
      AdultGoal.loseWeight => Exact.parse('0.90'),
      AdultGoal.maintainWeight => Exact.parse('1.00'),
      AdultGoal.gainWeight => Exact.parse('1.05'),
      AdultGoal.notDeclared => Exact.parse('1.00'),
    };
    final energy = maintenance * multiplier;
    if (!energy.positive) {
      throw TargetEstimateException('TARGET_CONFLICT');
    }
    final perKg = Exact.parse('0.83') * weight;
    final share = Exact.parse('0.15') * energy / Exact.parse('4');
    final protein = perKg.compareTo(share) >= 0 ? perKg : share;
    final fat = Exact.parse('0.30') * energy / Exact.parse('9');
    final carbohydrate = (energy -
            Exact.parse('4') * protein -
            Exact.parse('9') * fat -
            Exact.parse('50')) /
        Exact.parse('4');
    if (carbohydrate.compareTo(Exact.zero) < 0) {
      throw TargetEstimateException('TARGET_CONFLICT');
    }
    return DeclaredTarget(
        id: id,
        revision: revision,
        origin: TargetOrigin.calculatedEstimate,
        effectiveDate: effectiveDate,
        policyVersion: startingEstimatePolicyVersion,
        formulaVersion: formulaVersion,
        assumptions: {
          'ageYears': age,
          'heightCm': height.toJson(),
          'weightKg': weight.toJson(),
          'equationConstant': profile.equationConstant,
          'activityPal': pal.toJson(),
          'goalMultiplier': multiplier.toJson(),
          'fibreAllocationKcal': Exact.parse('50').toJson(),
          'isEstimate': true,
        },
        energyKcal: energy,
        proteinG: protein,
        fatG: fat,
        carbohydrateG: carbohydrate,
        active: true);
  }

  /// Changing targets always produces a new owned revision. No exercise add-back.
  DeclaredTarget revise(DeclaredTarget previous, DeclaredTarget next,
      {required int expectedRevision, required bool confirmed}) {
    if (!confirmed ||
        previous.revision != expectedRevision ||
        next.revision != expectedRevision + 1 ||
        previous.id != next.id) {
      throw StateError('STALE_OR_UNCONFIRMED_TARGET');
    }
    return next;
  }
}
