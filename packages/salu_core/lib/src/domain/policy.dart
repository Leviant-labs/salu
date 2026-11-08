import 'nutrition_contract.dart';

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
      required this.declaredTargetPlanning,
      required this.seekAdvice});
  static const policyVersion = 'eligibility-draft-v2-unapproved';
  final List<String> reasonCodes;
  final bool supportMode,
      personalReferences,
      declaredTargetPlanning,
      seekAdvice;
  bool get recordingAllowed => true;
  bool get automaticTargetsAllowed => false;
  bool get adaptiveProposalsAllowed => false;
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
      'POLICY_NOT_APPROVED',
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
        declaredTargetPlanning: !routed,
        seekAdvice: p.symptoms ||
            p.clinicalNeed == true ||
            p.eatingConcern == true ||
            p.relevantMedication == true);
  }
}

enum TargetOrigin { userDeclared, clinicianProvided, reviewedPolicyGenerated }

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
      this.active = true}) {
    if (id.isEmpty ||
        revision < 1 ||
        !energyKcal.positive ||
        [proteinG, fatG, carbohydrateG]
            .any((x) => x != null && x.compareTo(Exact.zero) < 0)) {
      throw ArgumentError('Invalid target');
    }
    if (origin == TargetOrigin.reviewedPolicyGenerated) {
      throw StateError('POLICY_NOT_APPROVED');
    }
    final macroEnergy = (proteinG ?? Exact.zero) * Exact.parse('4') +
        (fatG ?? Exact.zero) * Exact.parse('9') +
        (carbohydrateG ?? Exact.zero) * Exact.parse('4');
    if (macroEnergy.compareTo(energyKcal) > 0) {
      throw StateError('TARGET_CONFLICT');
    }
  }
  final String id, effectiveDate, policyVersion;
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
        'active': active
      };
  factory DeclaredTarget.fromJson(Map<String, Object?> j) {
    Exact? amount(String key) => j[key] == null
        ? null
        : Exact.fromJson(Map<String, Object?>.from(j[key]! as Map));
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
        active: j['active'] == true);
  }
}

final class TargetService {
  const TargetService();
  String generateAutomaticTarget() => 'POLICY_NOT_APPROVED';
  String proposeAdaptation() => 'ADAPTATION_NOT_APPROVED';

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
