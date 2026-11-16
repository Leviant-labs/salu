/// Explicit adult goal and optional condition declarations.
///
/// These declarations are deliberately separate from `SafetyProfile` and
/// `EligibilityService`: recording a goal or condition here never changes
/// eligibility, activates a target, or unlocks advice. A declaration is not a
/// diagnosis, and an undeclared condition is not evidence that it is absent.
library;

/// The goal an adult user chooses for their own records.
///
/// [notDeclared] is the only unselected state. No goal is inferred from weight,
/// intake, targets, or safety declarations.
enum AdultGoal {
  notDeclared,
  loseWeight,
  maintainWeight,
  gainWeight;

  /// Reads a stored goal name without treating unknown values as a choice.
  ///
  /// Returns null for a value this build does not know, so editing code can
  /// preserve the raw value instead of silently replacing it.
  static AdultGoal? byNameOrNull(String? name) {
    for (final goal in AdultGoal.values) {
      if (goal.name == name) return goal;
    }
    return null;
  }
}

/// Conditions a user may declare about themselves.
///
/// The list records a declaration only. It has no subtype, severity,
/// treatment, or diagnostic fields, and no value here is a clinical finding.
/// The serialized `.name` values are stable: persisted data and experimental
/// condition-aware planning read them by exact name.
///
/// [foodAllergy] and [coeliacDisease] are declaration flags only. They do not
/// create allergen or gluten exclusions, identify an allergen, or establish
/// that a food is suitable. Strict exclusions live in `SafetyProfile`, and
/// unknown allergen status never becomes evidence of safety. Pregnancy and
/// breastfeeding stay in `SafetyProfile` rather than being duplicated here.
enum DeclaredCondition {
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
  coeliacDisease
}

/// A user-owned choice of adult goal plus optional condition declarations.
///
/// Saving this document does not diagnose a condition, change a declared
/// target, or certify clinical suitability. This build runs an experimental,
/// source-linked test that may use some declarations to tailor meal
/// suggestions; it is not clinically validated and does not promise that every
/// declared condition has a rule or enough data to produce a tailored result.
final class AdultHealthDeclaration {
  const AdultHealthDeclaration({
    this.goal = AdultGoal.notDeclared,
    this.declaredConditions = const <DeclaredCondition>{},
    this.absentConditions = const <DeclaredCondition>{},
  });

  /// Version marker for the stored experimental condition-aware planning
  /// policy. It is not clinical approval.
  static const guidancePolicy = 'condition-guidance-experimental-v1';

  final AdultGoal goal;

  /// Conditions the user says apply to them.
  ///
  /// This is a declaration, not a diagnosis, severity assessment or subtype.
  final Set<DeclaredCondition> declaredConditions;

  /// Conditions the user explicitly says do not apply. A condition in neither
  /// set is not declared; unknown is never rewritten as "no".
  final Set<DeclaredCondition> absentConditions;

  /// True because this build includes the experimental, source-linked
  /// condition-aware planning test.
  ///
  /// It is not a claim that any particular declaration is supported, that
  /// allergen or gluten restrictions exist, or that guidance is clinically
  /// validated. Plan results must state their own basis, unresolved inputs and
  /// abstentions.
  bool get conditionGuidanceEnabled => true;

  /// True when [condition] is explicitly declared, false only when the user
  /// explicitly marked it absent, and null when it is not declared.
  bool? conditionStatus(DeclaredCondition condition) {
    if (declaredConditions.contains(condition)) return true;
    if (absentConditions.contains(condition)) return false;
    return null;
  }

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'goal': goal.name,
        'conditions': {
          for (final condition in DeclaredCondition.values)
            condition.name: conditionStatus(condition),
        },
        'guidancePolicy': guidancePolicy,
      };

  /// Reads known declarations and tolerates values written by other versions.
  ///
  /// An unknown goal or condition value reads as not declared; it is not
  /// guessed and does not become "no". Callers that rewrite a document keep
  /// their raw copy so values from a newer build survive unrelated edits.
  factory AdultHealthDeclaration.fromJson(Map<String, Object?> json) {
    final goalValue = json['goal'];
    if (goalValue != null && goalValue is! String) {
      throw const FormatException('Invalid declared goal');
    }
    final goalName = goalValue is String ? goalValue : null;
    final conditionsValue = json['conditions'];
    final rawConditions = <String, Object?>{};
    if (conditionsValue != null) {
      if (conditionsValue is! Map<Object?, Object?>) {
        throw const FormatException('Invalid condition declarations');
      }
      for (final entry in conditionsValue.entries) {
        final key = entry.key;
        if (key is! String) {
          throw const FormatException('Invalid condition declarations');
        }
        rawConditions[key] = entry.value;
      }
    }
    final declared = <DeclaredCondition>{};
    final absent = <DeclaredCondition>{};
    for (final condition in DeclaredCondition.values) {
      switch (rawConditions[condition.name]) {
        case true:
          declared.add(condition);
        case false:
          absent.add(condition);
        default:
          break;
      }
    }
    return AdultHealthDeclaration(
      goal: AdultGoal.byNameOrNull(goalName) ?? AdultGoal.notDeclared,
      declaredConditions: Set.unmodifiable(declared),
      absentConditions: Set.unmodifiable(absent),
    );
  }
}
