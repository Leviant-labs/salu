import 'package:flutter/material.dart';

import 'planning_profile.dart';

String formatProfileNumber(double? value) =>
    value?.toString().replaceFirst(RegExp(r'\.0$'), '') ?? '';

double? parseProfileNumber(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));

String? validateOptionalPositiveNumber(String? text) {
  final value = text?.trim() ?? '';
  if (value.isEmpty) return null;
  final number = parseProfileNumber(value);
  if (number == null || !number.isFinite || number <= 0) {
    return 'Enter a number greater than zero.';
  }
  return null;
}

class WelcomeOnboardingPage extends StatelessWidget {
  const WelcomeOnboardingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Welcome to Salu', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 12),
        const Text(
          'Let’s make your diary and meal plans your own. Everything here is optional and can be changed later in Settings.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Your diary works offline on this device. No nutrition targets are calculated automatically, and AI setup is completely optional.',
        ),
      ],
    );
  }
}

class GoalsOnboardingPage extends StatelessWidget {
  const GoalsOnboardingPage({
    required this.goalController,
    required this.activityController,
    required this.enabled,
    super.key,
  });

  final TextEditingController goalController;
  final TextEditingController activityController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your goals and routine', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Optional. Describe any goals or routine in your own words, or skip this step.',
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: goalController,
          enabled: enabled,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Declared energy goal (optional)',
            hintText: 'In your own words',
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: activityController,
          enabled: enabled,
          minLines: 1,
          maxLines: 3,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Usual activity (optional)',
            hintText: 'What a typical week looks like',
            counterText: '',
          ),
        ),
      ],
    );
  }
}

class StartingPointOnboardingPage extends StatelessWidget {
  const StartingPointOnboardingPage({
    required this.weightController,
    required this.unit,
    required this.onUnitChanged,
    required this.enabled,
    super.key,
  });

  final TextEditingController weightController;
  final WeightUnit unit;
  final ValueChanged<WeightUnit> onUnitChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your starting point', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Optional. Leave starting weight blank if you prefer, or add it later.',
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                controller: weightController,
                enabled: enabled,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Starting weight',
                ),
                validator: validateOptionalPositiveNumber,
              ),
            ),
            const SizedBox(width: 16),
            Semantics(
              label: 'Weight unit',
              child: DropdownButton<WeightUnit>(
                value: unit,
                onChanged: enabled
                    ? (selected) {
                        if (selected != null) onUnitChanged(selected);
                      }
                    : null,
                items: [
                  for (final option in WeightUnit.values)
                    DropdownMenuItem(value: option, child: Text(option.label)),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class PreferencesOnboardingPage extends StatelessWidget {
  const PreferencesOnboardingPage({
    required this.likesController,
    required this.dislikesController,
    required this.exclusionsController,
    required this.allergensController,
    required this.enabled,
    super.key,
  });

  final TextEditingController likesController;
  final TextEditingController dislikesController;
  final TextEditingController exclusionsController;
  final TextEditingController allergensController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Food preferences', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Optional. These stay on this device unless you choose to send them for meal suggestions.',
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: likesController,
          enabled: enabled,
          minLines: 1,
          maxLines: 3,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Likes',
            hintText: 'Foods or cuisines you enjoy',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: dislikesController,
          enabled: enabled,
          minLines: 1,
          maxLines: 3,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Dislikes',
            hintText: 'Foods you prefer to avoid',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: exclusionsController,
          enabled: enabled,
          minLines: 1,
          maxLines: 4,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Must exclude',
            hintText: 'Separate foods with commas or new lines',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: allergensController,
          enabled: enabled,
          minLines: 1,
          maxLines: 2,
          maxLength: 500,
          decoration: const InputDecoration(
            labelText: 'Strict allergies (optional)',
            hintText:
                'Separate names with commas. Recipes with unknown allergy information are excluded from suggestions.',
            counterText: '',
          ),
        ),
      ],
    );
  }
}

class TargetsOnboardingPage extends StatelessWidget {
  const TargetsOnboardingPage({
    required this.energyTargetController,
    required this.proteinController,
    required this.carbohydrateController,
    required this.fatController,
    required this.enabled,
    super.key,
  });

  final TextEditingController energyTargetController;
  final TextEditingController proteinController;
  final TextEditingController carbohydrateController;
  final TextEditingController fatController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your daily targets', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Optional. Enter only targets you have already chosen. No automatic targets are calculated for you.',
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: energyTargetController,
          enabled: enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Declared daily energy target (optional)',
            suffixText: 'kcal',
          ),
          validator: validateOptionalPositiveNumber,
        ),
        const SizedBox(height: 20),
        Text(
          'Declared macro targets (optional)',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        for (final (controller, label) in [
          (proteinController, 'Protein'),
          (carbohydrateController, 'Carbohydrate'),
          (fatController, 'Fat'),
        ]) ...[
          TextFormField(
            controller: controller,
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: label,
              suffixText: 'g/day',
            ),
            validator: validateOptionalPositiveNumber,
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class AiSetupOnboardingPage extends StatelessWidget {
  const AiSetupOnboardingPage({
    required this.hasConnectionsAction,
    required this.busy,
    required this.openingConnections,
    required this.statusMessage,
    required this.onOpenConnections,
    super.key,
  });

  final bool hasConnectionsAction;
  final bool busy;
  final bool openingConnections;
  final String? statusMessage;
  final VoidCallback onOpenConnections;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Optional AI assistant', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'AI setup is optional. Your food diary, manual meal logging, and local planning work offline without connecting an AI provider.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Connecting or selecting an AI provider never authorizes meal or photo uploads. Requests happen only when you explicitly ask for an estimate or suggestion.',
        ),
        const SizedBox(height: 20),
        if (hasConnectionsAction) ...[
          OutlinedButton.icon(
            onPressed: busy || openingConnections ? null : onOpenConnections,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: Text(
              openingConnections ? 'Opening AI setup…' : 'Set up AI connection',
            ),
          ),
        ] else
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'You can connect an AI provider anytime in Settings.',
              ),
            ),
          ),
        if (statusMessage != null) ...[
          const SizedBox(height: 12),
          Text(statusMessage!, style: theme.textTheme.bodyMedium),
        ],
      ],
    );
  }
}

class ReviewOnboardingPage extends StatelessWidget {
  const ReviewOnboardingPage({required this.profile, super.key});

  final PlanningProfile profile;

  String _textOrUnset(String value) => value.trim().isEmpty ? 'Not set' : value;

  String _weightSummary() {
    final weight = profile.startingWeight;
    if (weight == null) return 'Not set';
    return '${formatProfileNumber(weight)} ${profile.weightUnit.label}';
  }

  String _energySummary() {
    final kcal = profile.dailyEnergyKcal;
    if (kcal == null) return 'Not set';
    return '${formatProfileNumber(kcal)} kcal';
  }

  String _macroSummary() {
    final parts = <String>[
      if (profile.proteinGrams != null)
        'Protein ${formatProfileNumber(profile.proteinGrams)} g/day',
      if (profile.carbohydrateGrams != null)
        'Carbohydrate ${formatProfileNumber(profile.carbohydrateGrams)} g/day',
      if (profile.fatGrams != null)
        'Fat ${formatProfileNumber(profile.fatGrams)} g/day',
    ];
    return parts.isEmpty ? 'Not set' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Review your setup', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text(
          'Everything here stays on this device and can be updated anytime in Settings.',
        ),
        const SizedBox(height: 16),
        _SummaryRow(
          label: 'Declared energy goal',
          value: _textOrUnset(profile.energyGoal),
        ),
        _SummaryRow(
          label: 'Usual activity',
          value: _textOrUnset(profile.habitualActivity),
        ),
        _SummaryRow(label: 'Starting weight', value: _weightSummary()),
        _SummaryRow(
          label: 'Likes',
          value: _textOrUnset(profile.preferences.likes),
        ),
        _SummaryRow(
          label: 'Dislikes',
          value: _textOrUnset(profile.preferences.dislikes),
        ),
        _SummaryRow(
          label: 'Must exclude',
          value: _textOrUnset(profile.preferences.exclusions),
        ),
        _SummaryRow(
          label: 'Strict allergies',
          value: _textOrUnset(profile.preferences.strictAllergens),
        ),
        _SummaryRow(label: 'Daily energy target', value: _energySummary()),
        _SummaryRow(label: 'Macro targets', value: _macroSummary()),
        const _SummaryRow(
          label: 'AI assistant',
          value: 'Optional · no meal or photo uploads authorized',
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
