import 'package:flutter/material.dart';

import 'plan_item_editor.dart';
import 'plan_suggestions.dart';
import 'week_plan.dart';

class PlanDraftPreview extends StatefulWidget {
  const PlanDraftPreview({
    super.key,
    required this.plan,
    required this.draft,
    required this.onConfirm,
  });

  final WeekPlan plan;
  final PlanDraft draft;

  /// Returns an error to keep the preview open, or null after saving.
  final Future<String?> Function(PlanDraft) onConfirm;

  @override
  State<PlanDraftPreview> createState() => _PlanDraftPreviewState();
}

class _PlanDraftPreviewState extends State<PlanDraftPreview> {
  late final _meals = Map<MealPosition, PlannedMeal>.of(widget.draft.meals);
  late final _groceries = widget.draft.groceries.toList();
  late final _mealChoices =
      _meals.keys.where((key) => !widget.plan.meals.containsKey(key)).toSet();
  late final _groceryChoices = {
    for (var index = 0; index < _groceries.length; index++)
      if (!_hasGrocery(_groceries[index])) index,
  };
  bool _saving = false;

  bool _hasGrocery(GroceryItem item) =>
      widget.plan.groceries.any((saved) => saved.nameKey == item.nameKey);

  Future<void> _editMeal(MealPosition key) async {
    final meal = _meals[key]!;
    final edit = await editPlanItem(
      context,
      title: 'Edit suggested meal',
      grocery: false,
      name: meal.name,
      details: meal.details,
    );
    if (!mounted || edit == null || edit.name == null) return;
    setState(
      () => _meals[key] = PlannedMeal(edit.name!, details: edit.details),
    );
  }

  Future<void> _editGrocery(int index) async {
    final item = _groceries[index];
    final edit = await editPlanItem(
      context,
      title: 'Edit suggested grocery',
      grocery: true,
      name: item.name,
      details: item.amount,
    );
    if (!mounted || edit == null || edit.name == null) return;
    final next = GroceryItem(edit.name!, amount: edit.details);
    setState(() {
      _groceries[index] = next;
      if (next.nameKey != item.nameKey && _hasGrocery(next)) {
        _groceryChoices.remove(index);
      }
    });
  }

  Future<void> _confirm() async {
    if (_saving) return;
    final selected = PlanDraft(
      meals: {for (final key in _mealChoices) key: _meals[key]!},
      groceries: [
        for (var i = 0; i < _groceries.length; i++)
          if (_groceryChoices.contains(i)) _groceries[i],
      ],
    );
    if (selected.isEmpty) return;
    if (selected.hasDuplicateGroceries) {
      _showError('Select only one grocery suggestion per item.');
      return;
    }
    setState(() => _saving = true);
    final error = await widget.onConfirm(selected);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      _showError(error);
    }
  }

  void _showError(String message) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));

  Widget _choice({
    required String label,
    required String name,
    required String details,
    required bool checked,
    required ValueChanged<bool> onChecked,
    required VoidCallback onEdit,
  }) =>
      Card(
        child: Row(
          children: [
            Expanded(
              child: CheckboxListTile(
                value: checked,
                onChanged:
                    _saving ? null : (value) => onChecked(value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                title: Text('$label$name'),
                subtitle: details.isEmpty ? null : Text(details),
              ),
            ),
            IconButton(
              tooltip: 'Edit $name',
              onPressed: _saving ? null : onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final dates = MaterialLocalizations.of(context);
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    final count = _mealChoices.length + _groceryChoices.length;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('Review meal suggestions')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const Text(
              'Nothing is saved yet. Review ingredients yourself: suggestions aren’t checked for nutrition, hidden ingredients or allergens.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Existing entries aren’t replaced unless you select a replacement. Grocery choices are separate from meal choices.',
            ),
            if (widget.draft.summary.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('What the assistant aimed for', style: titleStyle),
              for (final reason in widget.draft.summary)
                Text('• ${reason.label}'),
            ],
            if (_meals.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Meals', style: titleStyle),
              for (var day = 0; day < 7; day++)
                for (final slot in MealSlot.values)
                  if (_meals.containsKey((day: day, slot: slot)))
                    _mealChoice(dates, (day: day, slot: slot)),
            ],
            if (_groceries.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Groceries', style: titleStyle),
              for (var index = 0; index < _groceries.length; index++)
                _groceryChoice(index),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: FilledButton(
            onPressed: count == 0 || _saving ? null : _confirm,
            child: Text(_saving ? 'Saving…' : 'Confirm selected ($count)'),
          ),
        ),
      ),
    );
  }

  Widget _mealChoice(MaterialLocalizations dates, MealPosition position) {
    final meal = _meals[position]!;
    final current = widget.plan.meals[position];
    return _choice(
      label:
          '${dates.formatMediumDate(widget.plan.dateFor(position.day))} · ${position.slot.label}\n',
      name: meal.name,
      details: [
        meal.details,
        if (current != null) 'Replaces: ${current.name}',
      ].where((text) => text.isNotEmpty).join('\n'),
      checked: _mealChoices.contains(position),
      onChecked: (value) => setState(() {
        value ? _mealChoices.add(position) : _mealChoices.remove(position);
      }),
      onEdit: () => _editMeal(position),
    );
  }

  Widget _groceryChoice(int index) {
    final item = _groceries[index];
    return _choice(
      label: '',
      name: item.name,
      details: [
        item.amount,
        if (_hasGrocery(item)) 'Updates item already on this list',
      ].where((text) => text.isNotEmpty).join('\n'),
      checked: _groceryChoices.contains(index),
      onChecked: (value) => setState(() {
        value ? _groceryChoices.add(index) : _groceryChoices.remove(index);
      }),
      onEdit: () => _editGrocery(index),
    );
  }
}
