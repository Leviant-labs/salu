import 'package:flutter/material.dart';
import 'package:salu_data/salu_data.dart';

import '../../data_transfer/data_write_gate.dart';
import 'onboarding_pages.dart';
import 'onboarding_wizard.dart';
import 'planning_profile.dart';

/// Standalone profile setup/edit screen, suitable for a top-level route.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({
    super.key,
    this.store,
    this.onboardingStore,
    this.gate,
    this.onSaved,
    this.firstRun = false,
    this.openConnections,
  });

  static const routeName = '/onboarding';

  final PlanningProfileStore? store;
  final OnboardingStore? onboardingStore;
  final DataWriteGate? gate;
  final VoidCallback? onSaved;
  final bool firstRun;
  final Future<void> Function(BuildContext)? openConnections;

  @override
  Widget build(BuildContext context) {
    if (firstRun && onboardingStore != null) {
      return OnboardingWizard(
        store: onboardingStore!,
        gate: gate,
        onCompleted: onSaved ?? () {},
        openConnections: openConnections,
      );
    }
    return _ProfileEditor(
      store: store ?? PlanningProfileStore.local,
      preferencesOnly: false,
      onSaved: onSaved,
    );
  }
}

/// The Plan workspace can edit food preferences without collecting weight.
class FoodPreferencesScreen extends StatelessWidget {
  const FoodPreferencesScreen({super.key, this.store});

  final PlanningProfileStore? store;

  @override
  Widget build(BuildContext context) => _ProfileEditor(
        store: store ?? PlanningProfileStore.local,
        preferencesOnly: true,
      );
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({
    required this.store,
    required this.preferencesOnly,
    this.onSaved,
  });

  final PlanningProfileStore store;
  final bool preferencesOnly;
  final VoidCallback? onSaved;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  final _form = GlobalKey<FormState>();
  final _weight = TextEditingController();
  final _goal = TextEditingController();
  final _target = TextEditingController();
  final _activity = TextEditingController();
  final _likes = TextEditingController();
  final _dislikes = TextEditingController();
  final _exclusions = TextEditingController();
  final _allergens = TextEditingController();
  final _protein = TextEditingController();
  final _carbohydrate = TextEditingController();
  final _fat = TextEditingController();
  WeightUnit _unit = WeightUnit.kilograms;
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.store.load();
      if (!mounted) return;
      _weight.text = _formatNumber(profile.startingWeight);
      _goal.text = profile.energyGoal;
      _target.text = _formatNumber(profile.dailyEnergyKcal);
      _protein.text = _formatNumber(profile.proteinGrams);
      _carbohydrate.text = _formatNumber(profile.carbohydrateGrams);
      _fat.text = _formatNumber(profile.fatGrams);
      _activity.text = profile.habitualActivity;
      _likes.text = profile.preferences.likes;
      _dislikes.text = profile.preferences.dislikes;
      _exclusions.text = profile.preferences.exclusions;
      _allergens.text = profile.preferences.strictAllergens;
      setState(() {
        _unit = profile.weightUnit;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  String _formatNumber(double? value) =>
      value?.toString().replaceFirst(RegExp(r'\.0$'), '') ?? '';

  double? _number(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  String? _validateNumber(String? text, {bool required = false}) {
    final value = text?.trim() ?? '';
    if (value.isEmpty) return required ? 'Enter a starting weight.' : null;
    final number = _number(value);
    if (number == null || !number.isFinite || number <= 0) {
      return 'Enter a number greater than zero.';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    final preferences = FoodPreferences(
      likes: _likes.text.trim(),
      dislikes: _dislikes.text.trim(),
      exclusions: _exclusions.text.trim(),
      strictAllergens: _allergens.text.trim(),
    );
    try {
      if (widget.preferencesOnly) {
        await widget.store.savePreferences(preferences);
      } else {
        await widget.store.save(
          PlanningProfile(
            startingWeight: _number(_weight.text),
            weightUnit: _unit,
            energyGoal: _goal.text.trim(),
            dailyEnergyKcal: _number(_target.text),
            proteinGrams: _number(_protein.text),
            carbohydrateGrams: _number(_carbohydrate.text),
            fatGrams: _number(_fat.text),
            habitualActivity: _activity.text.trim(),
            preferences: preferences,
            onboarded: true,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save. Your edits are still here.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saved = true;
    });
    if (widget.preferencesOnly && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      widget.onSaved?.call();
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _weight,
      _goal,
      _target,
      _activity,
      _likes,
      _dislikes,
      _exclusions,
      _allergens,
      _protein,
      _carbohydrate,
      _fat,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    String? hint,
    int maxLines = 1,
    int maxLength = 500,
  }) =>
      TextFormField(
        controller: controller,
        enabled: !_saving,
        minLines: 1,
        maxLines: maxLines,
        maxLength: maxLength,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          counterText: '',
        ),
      );

  Widget _buildForm(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    return Form(
      key: _form,
      onChanged: () {
        if (_saved) setState(() => _saved = false);
      },
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.preferencesOnly) ...[
              const Text(
                'Record your starting point and any goals you’ve chosen. No targets are calculated for you.',
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _weight,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Starting weight',
                      ),
                      validator: (text) =>
                          _validateNumber(text, required: false),
                    ),
                  ),
                  const SizedBox(width: 16),
                  DropdownButton<WeightUnit>(
                    value: _unit,
                    onChanged: _saving
                        ? null
                        : (unit) {
                            if (unit != null) {
                              setState(() {
                                _unit = unit;
                                _saved = false;
                              });
                            }
                          },
                    items: [
                      for (final unit in WeightUnit.values)
                        DropdownMenuItem(value: unit, child: Text(unit.label)),
                    ],
                  ),
                ],
              ),
              _textField(
                _goal,
                'Declared energy goal (optional)',
                hint: 'In your own words',
              ),
              TextFormField(
                controller: _target,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Declared daily energy target (optional)',
                  suffixText: 'kcal',
                ),
                validator: (text) => _validateNumber(text, required: false),
              ),
              _textField(
                _activity,
                'Usual activity (optional)',
                hint: 'What a typical week looks like',
                maxLines: 3,
              ),
              ExpansionTile(
                  title: const Text('Declared macro targets (optional)'),
                  children: [
                    for (final (controller, label) in [
                      (_protein, 'Protein'),
                      (_carbohydrate, 'Carbohydrate'),
                      (_fat, 'Fat')
                    ])
                      TextFormField(
                          controller: controller,
                          enabled: !_saving,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: InputDecoration(
                              labelText: label, suffixText: 'g/day'),
                          validator: (text) =>
                              _validateNumber(text, required: false)),
                  ]),
              const SizedBox(height: 24),
              Text('Food preferences', style: titleStyle),
            ],
            const Text(
              'Optional. These stay on this device unless you choose to send them for meal suggestions.',
            ),
            const SizedBox(height: 8),
            _textField(
              _likes,
              'Likes',
              hint: 'Foods or cuisines you enjoy',
              maxLines: 3,
            ),
            _textField(
              _dislikes,
              'Dislikes',
              hint: 'Foods you prefer to avoid',
              maxLines: 3,
            ),
            _textField(
              _exclusions,
              'Must exclude',
              hint: 'Separate foods with commas or new lines',
              maxLines: 4,
            ),
            const SizedBox(height: 12),
            StrictAllergenSelector(
              controller: _allergens,
              enabled: !_saving,
              onChanged: () {
                if (_saved) setState(() => _saved = false);
              },
            ),
            if (_saved) ...[
              const SizedBox(height: 12),
              const Text('Saved on this device.', textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(
            widget.preferencesOnly ? 'Food preferences' : 'Planning profile',
          ),
        ),
        bottomNavigationBar: _loading || _loadFailed
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(
                      _saving
                          ? 'Saving…'
                          : widget.preferencesOnly
                              ? 'Save preferences'
                              : 'Save profile',
                    ),
                  ),
                ),
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadFailed
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Could not open your saved profile.'),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _loading = true;
                              _loadFailed = false;
                            });
                            _load();
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _buildForm(context),
      );
}
