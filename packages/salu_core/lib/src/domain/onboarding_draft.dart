import 'planning_profile.dart';

enum OnboardingStep {
  welcome,
  goals,
  startingPoint,
  preferences,
  targets,
  aiSetup,
  review,
}

OnboardingStep? _parseStep(Object? name) {
  if (name is! String) return null;
  for (final step in OnboardingStep.values) {
    if (step.name == name) return step;
  }
  return null;
}

final class OnboardingDraft {
  const OnboardingDraft({
    this.step = OnboardingStep.welcome,
    this.profile = const PlanningProfile(),
    this.revision = 0,
  });

  factory OnboardingDraft.fromJson(
    Map<String, dynamic> json, {
    int revision = 0,
  }) {
    final version = json['version'];
    if (version != currentVersion) {
      throw FormatException(
        'Unsupported onboarding draft version: $version',
        version,
      );
    }
    final stepName = json['step'];
    final step = _parseStep(stepName);
    if (step == null) {
      throw FormatException('Invalid onboarding step: $stepName', stepName);
    }
    final rawProfile = json['profile'];
    if (rawProfile is! Map) {
      throw FormatException('Invalid onboarding draft profile', rawProfile);
    }
    return OnboardingDraft(
      step: step,
      profile: PlanningProfile.fromJson(
        Map<String, dynamic>.from(rawProfile),
      ),
      revision: revision,
    );
  }

  static const int currentVersion = 1;

  final OnboardingStep step;
  final PlanningProfile profile;
  final int revision;

  OnboardingDraft copyWith({
    OnboardingStep? step,
    PlanningProfile? profile,
    int? revision,
  }) =>
      OnboardingDraft(
        step: step ?? this.step,
        profile: profile ?? this.profile,
        revision: revision ?? this.revision,
      );

  Map<String, Object?> toJson() => {
        'version': currentVersion,
        'step': step.name,
        'profile': profile.toJson(),
      };
}
