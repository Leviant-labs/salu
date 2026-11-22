import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';

import '../../assistant/assistant.dart';
import '../../media/managed_media_store.dart';
import 'meal_editor_ai.dart';
import 'meal_editor_data.dart';

Future<PhotoMealItem?> editMealItem(
  BuildContext context, {
  PhotoMealItem? item,
  Food? food,
}) =>
    showDialog<PhotoMealItem>(
      context: context,
      builder: (_) => _MealItemForm(item: item, food: food),
    );

class _MealItemForm extends StatefulWidget {
  const _MealItemForm({this.item, this.food});

  final PhotoMealItem? item;
  final Food? food;

  @override
  State<_MealItemForm> createState() => _MealItemFormState();
}

class _MealItemFormState extends State<_MealItemForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.item?.name ?? widget.food?.name ?? '',
  );
  late final _amount = TextEditingController(
    text: widget.item?.portion?.amount.toString() ?? '',
  );
  late MealUnit _unit = widget.item?.portion?.unit ?? MealUnit.grams;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _apply() {
    if (!_form.currentState!.validate()) return;
    final amount = mealNumber(_amount.text);
    final portion = amount == null ? null : MealPortion(amount, _unit);
    final name = _name.text.trim();
    final item = widget.item;
    final food = widget.food;
    Navigator.of(context).pop(
      food != null
          ? catalogueMealItem(food, portion)
          : item != null
              ? reviseMealItem(item, name, portion)
              : PhotoMealItem(name: name, portion: portion),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.item == null ? 'Add food' : 'Edit food'),
        scrollable: true,
        content: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.food case final food?)
                Text(food.name, style: Theme.of(context).textTheme.titleMedium)
              else
                TextFormField(
                  controller: _name,
                  maxLength: 120,
                  decoration: const InputDecoration(
                    labelText: 'Food name',
                    counterText: '',
                  ),
                  validator: (value) =>
                      value!.trim().isEmpty ? 'Enter a food name.' : null,
                ),
              TextFormField(
                controller: _amount,
                maxLength: 30,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Amount eaten (optional)',
                  counterText: '',
                ),
                validator: (value) =>
                    value!.trim().isEmpty ? null : _positiveAmountError(value),
              ),
              _UnitField(
                unit: _unit,
                onChanged: (unit) => setState(() => _unit = unit),
              ),
              const SizedBox(height: 8),
              Text(switch ((widget.item, widget.food)) {
                (final item?, _) when item.labelPath != null =>
                  'Changing the food name clears its previous nutrition and label link.',
                (_, final food?) =>
                  'Catalogue: ${food.source.dataset}. Nutrition needs an amount that can be converted to grams.',
                _ => 'Leave the amount blank if you don’t know it.',
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: _apply, child: const Text('Apply to draft')),
        ],
      );
}

Future<PhotoMealItem?> editMealLabel(
  BuildContext context, {
  required PhotoMealItem item,
  required String labelPath,
  required ManagedMediaStore media,
  required Future<LabelTranscription?> Function() readLabel,
  LabelTranscription? initial,
  String? providerLabel,
}) =>
    showDialog<PhotoMealItem>(
      context: context,
      builder: (_) => _MealLabelForm(
          item: item,
          labelPath: labelPath,
          media: media,
          readLabel: readLabel,
          initial: initial,
          providerLabel: providerLabel),
    );

class _MealLabelForm extends StatefulWidget {
  const _MealLabelForm(
      {required this.item,
      required this.labelPath,
      required this.media,
      required this.readLabel,
      this.initial,
      this.providerLabel});

  final PhotoMealItem item;
  final String labelPath;
  final ManagedMediaStore media;
  final Future<LabelTranscription?> Function() readLabel;
  final LabelTranscription? initial;
  final String? providerLabel;

  @override
  State<_MealLabelForm> createState() => _MealLabelFormState();
}

class _MealLabelFormState extends State<_MealLabelForm> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _values = {
    for (final key in NutrientKey.values) key: TextEditingController(),
  };
  late MealUnit _unit = widget.item.portion?.unit ?? MealUnit.grams;
  String? _error;
  bool _reading = false;
  bool _transcribed = false;
  List<NutritionIssue> _issues = const [];

  @override
  void initState() {
    super.initState();
    if (widget.initial case final label?) {
      _fillLabel(label);
    }
  }

  void _fillLabel(LabelTranscription label) {
    _amount.text = label.basis.amount.toString();
    for (final entry in _values.entries) {
      entry.value.text = label.values[entry.key]?.toString() ?? '';
    }
    _unit = label.basis.unit;
    _transcribed = true;
    _issues = label.issues;
  }

  Future<void> _readLabel() async {
    setState(() {
      _reading = true;
      _error = null;
      _issues = const [];
    });
    try {
      final result = await widget.readLabel();
      if (!mounted) return;
      if (result == null) {
        setState(() => _error =
            'Could not read the printed basis and values. Enter them manually.');
        return;
      }
      setState(() => _fillLabel(result));
    } on SaluAssistantException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Could not read the label. Enter its values manually.');
      }
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _attachOnly() {
    Navigator.of(context)
        .pop(widget.item.copyWith(labelPath: widget.labelPath));
  }

  @override
  void dispose() {
    _amount.dispose();
    for (final controller in _values.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _applyLabel() {
    setState(() => _error = null);
    if (!_form.currentState!.validate()) return;
    final values = <NutrientKey, NutrientValue>{};
    for (final entry in _values.entries) {
      final number = mealNumber(entry.value.text);
      if (number != null) values[entry.key] = NutrientReported(number);
    }
    if (values.isEmpty) {
      setState(() => _error = 'Enter at least one value printed on the label.');
      return;
    }
    final scaled = scaleMealLabel(
      NutrientProfile(values),
      MealPortion(mealNumber(_amount.text)!, _unit),
      widget.item.portion,
    );
    if (scaled == null) {
      setState(
        () => _error =
            'Use the same unit as the amount eaten and a valid label basis.',
      );
      return;
    }
    final merged = NutrientProfile(
      {...widget.item.nutrients.values, ...scaled.values},
    );
    final screened = screenNutrition(merged, portion: widget.item.portion);
    Navigator.of(context).pop(
      widget.item.copyWith(
        labelPath: widget.labelPath,
        nutrients: merged,
        source: 'nutrition-label',
        reviewIssues: screened.issues,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final consumed = widget.item.portion;
    return AlertDialog(
      title: Text('Label for ${widget.item.name}'),
      scrollable: true,
      content: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 160,
              width: double.infinity,
              child: InteractiveViewer(
                maxScale: 5,
                child: ManagedMediaImage(
                  reference: widget.labelPath,
                  media: widget.media,
                  fit: BoxFit.contain,
                  semanticLabel: 'Nutrition label photo',
                  unavailableText: 'Label photo unavailable.',
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (consumed == null)
              const Text(
                'The amount eaten is unknown. Set it on the food before applying label values.',
              )
            else ...[
              Text('Amount eaten: ${mealPortionText(consumed)}.'),
              Text(
                  'Read with AI sends only this label photo to ${widget.providerLabel ?? 'your selected AI provider'}. Provider plan limits or user-funded API billing may apply.'),
              OutlinedButton(
                onPressed: _reading ? null : _readLabel,
                child: Text(_reading ? 'Reading label…' : 'Read label with AI'),
              ),
              if (_transcribed)
                const Text(
                    'Check every proposed value against the label before applying.'),
              if (_issues.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Review warnings',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context).colorScheme.error,
                            ),
                      ),
                      for (final issue in _issues)
                        Text(
                          mealNutritionIssueText(issue),
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                        ),
                    ],
                  ),
                ),
              const Text(
                'Enter the printed basis in the same unit as the amount eaten. Reviewed values replace only the matching nutrients; other recorded values are unchanged.',
              ),
              TextFormField(
                controller: _amount,
                enabled: !_reading,
                maxLength: 30,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Printed basis amount',
                  counterText: '',
                ),
                validator: (value) => _positiveAmountError(value ?? ''),
              ),
              _UnitField(
                unit: _unit,
                enabled: !_reading,
                onChanged: (unit) => setState(() => _unit = unit),
              ),
              for (final entry in _values.entries)
                TextFormField(
                  controller: entry.value,
                  enabled: !_reading,
                  maxLength: 30,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '${entry.key.label} (${entry.key.unit})',
                    counterText: '',
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) return null;
                    final number = mealNumber(value);
                    return number == null || number < 0
                        ? 'Enter zero or a positive number.'
                        : null;
                  },
                ),
            ],
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (!widget.item.labelPaths.contains(widget.labelPath))
          TextButton(
            onPressed: _attachOnly,
            child: const Text('Attach photo only'),
          ),
        if (consumed != null)
          FilledButton(
            onPressed: _reading ? null : _applyLabel,
            child: const Text('Apply label values'),
          ),
      ],
    );
  }
}

String? _positiveAmountError(String text) {
  final number = mealNumber(text);
  return number == null || number <= 0 ? 'Enter a positive amount.' : null;
}

class _UnitField extends StatelessWidget {
  const _UnitField(
      {required this.unit, required this.onChanged, this.enabled = true});

  final MealUnit unit;
  final ValueChanged<MealUnit> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<MealUnit>(
        key: ValueKey(unit),
        initialValue: unit,
        decoration: const InputDecoration(labelText: 'Unit'),
        items: [
          for (final unit in MealUnit.values)
            DropdownMenuItem(value: unit, child: Text(unit.label)),
        ],
        onChanged: !enabled
            ? null
            : (unit) {
                if (unit != null) onChanged(unit);
              },
      );
}

Future<Food?> findMealFood(BuildContext context, FoodRepository foods) =>
    showDialog<Food>(
      context: context,
      builder: (_) => _MealCatalogue(foods: foods),
    );

class _MealCatalogue extends StatefulWidget {
  const _MealCatalogue({required this.foods});

  final FoodRepository foods;

  @override
  State<_MealCatalogue> createState() => _MealCatalogueState();
}

class _MealCatalogueState extends State<_MealCatalogue> {
  final _query = TextEditingController();
  List<Food> _results = const [];
  bool _loading = false;
  String? _message;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (_loading || query.isEmpty) return;
    setState(() {
      _loading = true;
      _message = null;
      _results = const [];
    });
    try {
      final results = await widget.foods.search(query, limit: 15);
      if (!mounted) return;
      setState(() {
        _results = results;
        _message = results.isEmpty
            ? 'No matching foods. You can add a food by name instead.'
            : null;
      });
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not search the catalogue.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Search catalogue'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(
            children: [
              TextField(
                controller: _query,
                autofocus: true,
                enabled: !_loading,
                maxLength: 120,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(
                  labelText: 'Food name',
                  counterText: '',
                ),
              ),
              TextButton(
                onPressed: _loading ? null : _search,
                child: const Text('Search'),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_message case final message?) Text(message),
              for (final food in _results)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(food.name),
                  subtitle: Text(food.source.dataset),
                  onTap: () => Navigator.of(context).pop(food),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
}

Future<bool> previewMealCorrection(
  BuildContext context, {
  required DiaryDate date,
  required MealCorrection before,
  required MealCorrection after,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Correction preview · ${date.toIso()}'),
        scrollable: true,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CorrectionSnapshot(title: 'Current draft', value: before),
            const Divider(),
            _CorrectionSnapshot(title: 'Proposed draft', value: after),
            const SizedBox(height: 12),
            const Text(
              'Apply to the draft to review or edit it. The diary changes only when you tap Save changes.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply to draft'),
          ),
        ],
      ),
    ) ??
    false;

class _CorrectionSnapshot extends StatelessWidget {
  const _CorrectionSnapshot({required this.title, required this.value});

  final String title;
  final MealCorrection value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$title: ${value.slot.label}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (value.items.isEmpty) const Text('No items'),
          for (final item in value.items)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${item.name} · ${mealPortionText(item.portion) ?? 'Amount unknown'}'
                '${item.labelPath == null ? '' : ' · Label attached'}\n${mealNutrientDetails(item.nutrients)}',
              ),
            ),
          const SizedBox(height: 8),
          Text('Meal totals: ${mealTotalDetails(value.items)}'),
        ],
      );
}
