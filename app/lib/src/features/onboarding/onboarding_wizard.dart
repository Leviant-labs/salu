import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'onboarding_controller.dart';
import 'onboarding_pages.dart';

/// Resumable, seven-step first-run onboarding wizard.
class OnboardingWizard extends StatefulWidget {
  const OnboardingWizard({
    required this.store,
    required this.onCompleted,
    this.openConnections,
    super.key,
  });

  final OnboardingStore store;
  final VoidCallback onCompleted;
  final Future<void> Function(BuildContext)? openConnections;

  @override
  State<OnboardingWizard> createState() => _OnboardingWizardState();
}

class _OnboardingWizardState extends State<OnboardingWizard> {
  final _form = GlobalKey<FormState>();
  final _goal = TextEditingController();
  final _activity = TextEditingController();
  final _weight = TextEditingController();
  final _likes = TextEditingController();
  final _dislikes = TextEditingController();
  final _exclusions = TextEditingController();
  final _allergens = TextEditingController();
  final _energyTarget = TextEditingController();
  final _protein = TextEditingController();
  final _carbohydrate = TextEditingController();
  final _fat = TextEditingController();

  late OnboardingController _controller;
  WeightUnit _unit = WeightUnit.kilograms;
  bool _openingConnections = false;
  String? _aiMessage;

  @override
  void initState() {
    super.initState();
    _controller = OnboardingController(widget.store);
    _initLoad();
  }

  @override
  void didUpdateWidget(covariant OnboardingWizard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      _controller.dispose();
      _controller = OnboardingController(widget.store);
      _initLoad();
    }
  }

  Future<void> _initLoad() async {
    await _controller.load();
    if (!mounted) return;
    if (_controller.loaded) {
      _syncFields(_controller.draft.profile);
    }
  }

  void _syncFields(PlanningProfile profile) {
    _goal.text = profile.energyGoal;
    _activity.text = profile.habitualActivity;
    _weight.text = formatProfileNumber(profile.startingWeight);
    _unit = profile.weightUnit;
    _likes.text = profile.preferences.likes;
    _dislikes.text = profile.preferences.dislikes;
    _exclusions.text = profile.preferences.exclusions;
    _allergens.text = profile.preferences.strictAllergens;
    _energyTarget.text = formatProfileNumber(profile.dailyEnergyKcal);
    _protein.text = formatProfileNumber(profile.proteinGrams);
    _carbohydrate.text = formatProfileNumber(profile.carbohydrateGrams);
    _fat.text = formatProfileNumber(profile.fatGrams);
  }

  PlanningProfile _profileForCurrentStep(OnboardingStep step) {
    final base = _controller.draft.profile;
    return switch (step) {
      OnboardingStep.welcome ||
      OnboardingStep.aiSetup ||
      OnboardingStep.review =>
        base,
      OnboardingStep.goals => PlanningProfile(
          startingWeight: base.startingWeight,
          weightUnit: base.weightUnit,
          energyGoal: _goal.text.trim(),
          dailyEnergyKcal: base.dailyEnergyKcal,
          proteinGrams: base.proteinGrams,
          carbohydrateGrams: base.carbohydrateGrams,
          fatGrams: base.fatGrams,
          habitualActivity: _activity.text.trim(),
          preferences: base.preferences,
          onboarded: base.onboarded,
        ),
      OnboardingStep.startingPoint => PlanningProfile(
          startingWeight: parseProfileNumber(_weight.text),
          weightUnit: _unit,
          energyGoal: base.energyGoal,
          dailyEnergyKcal: base.dailyEnergyKcal,
          proteinGrams: base.proteinGrams,
          carbohydrateGrams: base.carbohydrateGrams,
          fatGrams: base.fatGrams,
          habitualActivity: base.habitualActivity,
          preferences: base.preferences,
          onboarded: base.onboarded,
        ),
      OnboardingStep.preferences => PlanningProfile(
          startingWeight: base.startingWeight,
          weightUnit: base.weightUnit,
          energyGoal: base.energyGoal,
          dailyEnergyKcal: base.dailyEnergyKcal,
          proteinGrams: base.proteinGrams,
          carbohydrateGrams: base.carbohydrateGrams,
          fatGrams: base.fatGrams,
          habitualActivity: base.habitualActivity,
          preferences: FoodPreferences(
            likes: _likes.text.trim(),
            dislikes: _dislikes.text.trim(),
            exclusions: _exclusions.text.trim(),
            strictAllergens: _allergens.text.trim(),
          ),
          onboarded: base.onboarded,
        ),
      OnboardingStep.targets => PlanningProfile(
          startingWeight: base.startingWeight,
          weightUnit: base.weightUnit,
          energyGoal: base.energyGoal,
          dailyEnergyKcal: parseProfileNumber(_energyTarget.text),
          proteinGrams: parseProfileNumber(_protein.text),
          carbohydrateGrams: parseProfileNumber(_carbohydrate.text),
          fatGrams: parseProfileNumber(_fat.text),
          habitualActivity: base.habitualActivity,
          preferences: base.preferences,
          onboarded: base.onboarded,
        ),
    };
  }

  Future<void> _onNext() async {
    if (_controller.busy) return;
    final formState = _form.currentState;
    if (formState != null && !formState.validate()) return;
    FocusScope.of(context).unfocus();
    final step = _controller.draft.step;
    final profile = _profileForCurrentStep(step);
    if (await _controller.next(profile) && mounted) {
      _syncFields(_controller.draft.profile);
    }
  }

  Future<void> _onBack() async {
    if (_controller.busy) return;
    FocusScope.of(context).unfocus();
    if (await _controller.back() && mounted) {
      _syncFields(_controller.draft.profile);
    }
  }

  Future<void> _onSkipStep() async {
    if (_controller.busy) return;
    FocusScope.of(context).unfocus();
    if (await _controller.skipStep() && mounted) {
      _syncFields(_controller.draft.profile);
    }
  }

  Future<void> _onFinish() async {
    if (_controller.busy) return;
    FocusScope.of(context).unfocus();
    if (await _controller.finish() && mounted) {
      widget.onCompleted();
    }
  }

  Future<void> _onSkipSetup() async {
    if (_controller.busy) return;
    FocusScope.of(context).unfocus();
    if (await _controller.skipSetup() && mounted) {
      widget.onCompleted();
    }
  }

  Future<void> _onOpenConnections() async {
    final open = widget.openConnections;
    if (open == null || _openingConnections) return;
    setState(() {
      _openingConnections = true;
      _aiMessage = null;
    });
    try {
      await open(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _aiMessage =
              'AI setup was not completed. You can skip this step or set it up later in Settings.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _openingConnections = false);
      }
    }
  }

  Widget _buildPage(OnboardingStep step, bool busy) => switch (step) {
        OnboardingStep.welcome => const WelcomeOnboardingPage(),
        OnboardingStep.goals => GoalsOnboardingPage(
            goalController: _goal,
            activityController: _activity,
            enabled: !busy,
          ),
        OnboardingStep.startingPoint => StartingPointOnboardingPage(
            weightController: _weight,
            unit: _unit,
            onUnitChanged: (unit) => setState(() => _unit = unit),
            enabled: !busy,
          ),
        OnboardingStep.preferences => PreferencesOnboardingPage(
            likesController: _likes,
            dislikesController: _dislikes,
            exclusionsController: _exclusions,
            allergensController: _allergens,
            enabled: !busy,
          ),
        OnboardingStep.targets => TargetsOnboardingPage(
            energyTargetController: _energyTarget,
            proteinController: _protein,
            carbohydrateController: _carbohydrate,
            fatController: _fat,
            enabled: !busy,
          ),
        OnboardingStep.aiSetup => AiSetupOnboardingPage(
            hasConnectionsAction: widget.openConnections != null,
            busy: busy,
            openingConnections: _openingConnections,
            statusMessage: _aiMessage,
            onOpenConnections: _onOpenConnections,
          ),
        OnboardingStep.review =>
          ReviewOnboardingPage(profile: _controller.draft.profile),
      };

  @override
  void dispose() {
    _controller.dispose();
    for (final controller in [
      _goal,
      _activity,
      _weight,
      _likes,
      _dislikes,
      _exclusions,
      _allergens,
      _energyTarget,
      _protein,
      _carbohydrate,
      _fat,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final step = _controller.draft.step;
        final busy = _controller.busy;
        final error = _controller.error;
        final totalSteps = OnboardingStep.values.length;
        final theme = Theme.of(context);

        return PopScope(
          canPop: step == OnboardingStep.welcome,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (step != OnboardingStep.welcome) {
              _onBack();
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Your setup'),
            ),
            body: !_controller.loaded && busy
                ? const Center(child: CircularProgressIndicator())
                : !_controller.loaded && error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(error, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              TextButton(
                                onPressed: _initLoad,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    'Step ${step.index + 1} of $totalSteps',
                                    style: theme.textTheme.labelLarge,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ExcludeSemantics(
                                  child: LinearProgressIndicator(
                                    value: (step.index + 1) / totalSteps,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                              child: Semantics(
                                liveRegion: true,
                                child: Material(
                                  color: theme.colorScheme.errorContainer,
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      error,
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        color:
                                            theme.colorScheme.onErrorContainer,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Expanded(
                            child: Form(
                              key: _form,
                              child: SingleChildScrollView(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 16, 24),
                                child: _buildPage(step, busy),
                              ),
                            ),
                          ),
                          SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                              child: Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  if (step == OnboardingStep.welcome)
                                    TextButton(
                                      onPressed: busy ? null : _onSkipSetup,
                                      child: const Text('Skip setup'),
                                    )
                                  else
                                    OutlinedButton(
                                      onPressed: busy ? null : _onBack,
                                      child: const Text('Back'),
                                    ),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      if (step != OnboardingStep.welcome &&
                                          step != OnboardingStep.review)
                                        TextButton(
                                          onPressed: busy ? null : _onSkipStep,
                                          child: const Text('Skip this step'),
                                        ),
                                      if (step == OnboardingStep.review)
                                        FilledButton(
                                          onPressed: busy ? null : _onFinish,
                                          child: const Text('Finish setup'),
                                        )
                                      else
                                        FilledButton(
                                          onPressed: busy ? null : _onNext,
                                          child: const Text('Next'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
          ),
        );
      },
    );
  }
}
