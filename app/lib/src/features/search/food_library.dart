import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../meals/meal_editor_data.dart';
import '../meals/meal_editor_dialogs.dart';
import '../plan/recipe_library.dart';

typedef SavedFood = ({
  String id,
  String name,
  String? barcode,
  BoundedNutrition nutrition
});
typedef SavedMeal = ({String id, String name, List<PhotoMealItem> items});

class FoodLibrary {
  const FoodLibrary(this.documents);
  final LocalDocumentStore documents;
  static const _key = 'food-library';

  Future<List<SavedFood>> foods() async => [
        for (final raw
            in (await documents.read(_key))?.data['foods'] as List? ?? const [])
          (
            id: raw['id'] as String,
            name: raw['name'] as String,
            barcode: raw['barcode'] as String?,
            nutrition: BoundedNutrition(
                MealPortion((raw['amount'] as num).toDouble(),
                    MealUnit.values.byName(raw['unit'] as String)),
                NutrientProfile.fromJson(
                    raw['nutrients'] as Map<String, dynamic>))
          ),
      ];

  Future<List<SavedMeal>> meals() async => [
        for (final raw
            in (await documents.read(_key))?.data['meals'] as List? ?? const [])
          (
            id: raw['id'] as String,
            name: raw['name'] as String,
            items: [
              for (final i in raw['items'] as List)
                PhotoMealItem(
                    name: i['name'] as String,
                    portion: i['amount'] == null
                        ? null
                        : MealPortion((i['amount'] as num).toDouble(),
                            MealUnit.values.byName(i['unit'] as String)),
                    nutrients: NutrientProfile.fromJson(
                        i['nutrients'] as Map<String, dynamic>),
                    source: i['source'] as String?),
            ]
          ),
      ];

  Future<Set<String>> favorites() async =>
      ((await documents.read(_key))?.data['favorites'] as List? ?? const [])
          .cast<String>()
          .toSet();

  Future<void> toggleFavorite(String id) => _update((json) {
        final ids =
            (json['favorites'] as List? ?? const []).cast<String>().toSet();
        if (!ids.remove(id)) ids.add(id);
        return {...json, 'favorites': ids.toList()};
      });

  Future<void> saveFood(SavedFood food) => _update((json) {
        final rows = (json['foods'] as List? ?? const [])
            .where((row) => row['id'] != food.id)
            .toList();
        if (food.barcode != null &&
            rows.any((row) => row['barcode'] == food.barcode)) {
          throw StateError('Barcode is already saved');
        }
        return {
          ...json,
          'foods': [
            ...rows,
            {
              'id': food.id,
              'name': food.name,
              'barcode': food.barcode,
              'amount': food.nutrition.basis.amount,
              'unit': food.nutrition.basis.unit.name,
              'nutrients': food.nutrition.nutrients.toJson()
            }
          ]
        };
      });

  Future<void> saveMeal(SavedMeal meal) => _update((json) => {
        ...json,
        'meals': [
          ...(json['meals'] as List? ?? const [])
              .where((row) => row['id'] != meal.id),
          {
            'id': meal.id,
            'name': meal.name,
            'items': [
              for (final item in meal.items)
                {
                  'name': item.name,
                  'amount': item.portion?.amount,
                  'unit': item.portion?.unit.name,
                  'source': item.source,
                  'nutrients': item.nutrients.toJson(),
                }
            ]
          },
        ]
      });

  Future<void> _update(
      Map<String, Object?> Function(Map<String, dynamic>) change) async {
    final old = await documents.read(_key);
    if (!await documents.put(
        _key, old?.revision ?? 0, change(old?.data ?? {}))) {
      throw StateError('Food library changed');
    }
  }
}

Future<PhotoMealItem?> pickSavedFoodPortion(
    BuildContext context, SavedFood food) async {
  var amount = food.nutrition.basis.amount.toString();
  final basis = food.nutrition.basis;
  final result = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
            title: Text(food.name),
            content: TextFormField(
                initialValue: amount,
                onChanged: (text) => amount = text,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Amount eaten (${basis.unit.label})')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () {
                    final value = mealNumber(amount);
                    if (value != null && value > 0) {
                      Navigator.pop(context, value);
                    }
                  },
                  child: const Text('Use this amount'))
            ],
          ));
  if (result == null) return null;
  final portion = MealPortion(result, basis.unit);
  return PhotoMealItem(
      name: food.name,
      portion: portion,
      nutrients: food.nutrition.forPortion(portion),
      source: 'saved-food:${food.id}');
}

Future<SavedFood?> editSavedFood(BuildContext context, String id,
        {PhotoMealItem? item, SavedFood? saved}) =>
    showDialog<SavedFood>(
      context: context,
      builder: (context) => _FoodForm(id: id, item: item, saved: saved),
    );

class _FoodForm extends StatefulWidget {
  const _FoodForm({required this.id, this.item, this.saved});
  final String id;
  final PhotoMealItem? item;
  final SavedFood? saved;
  @override
  State<_FoodForm> createState() => _FoodFormState();
}

class _FoodFormState extends State<_FoodForm> {
  final _key = GlobalKey<FormState>();
  MealPortion? get _initialBasis =>
      widget.saved?.nutrition.basis ?? widget.item?.portion;
  NutrientProfile? get _initial =>
      widget.saved?.nutrition.nutrients ?? widget.item?.nutrients;
  late var _name = widget.saved?.name ?? widget.item?.name ?? '';
  late var _barcode = widget.saved?.barcode ?? '';
  late var _amount = (_initialBasis?.amount ?? 100).toString();
  late var _unit = _initialBasis?.unit ?? MealUnit.grams;
  final _edited = <NutrientKey, String>{};

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Save reusable food'),
          scrollable: true,
          content: Form(
              key: _key,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                    initialValue: _name,
                    onChanged: (value) => _name = value,
                    decoration: const InputDecoration(labelText: 'Name'),
                    validator: (value) => value?.trim().isNotEmpty == true
                        ? null
                        : 'Enter a food name.'),
                TextFormField(
                    initialValue: _barcode,
                    onChanged: (value) => _barcode = value,
                    decoration:
                        const InputDecoration(labelText: 'Barcode (optional)'),
                    keyboardType: TextInputType.number,
                    validator: (value) => value?.trim().isNotEmpty == true &&
                            !RegExp(r'^\d{8,14}$').hasMatch(value!.trim())
                        ? 'Enter the printed digits.'
                        : null),
                TextFormField(
                    initialValue: _amount,
                    onChanged: (value) => _amount = value,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Nutrition values for this amount'),
                    validator: (value) => (mealNumber(value ?? '') ?? 0) > 0
                        ? null
                        : 'Enter a positive amount.'),
                DropdownButtonFormField<MealUnit>(
                    initialValue: _unit,
                    items: [
                      for (final unit in MealUnit.values)
                        DropdownMenuItem(value: unit, child: Text(unit.label))
                    ],
                    onChanged: (value) => _unit = value ?? _unit),
                const Text(
                    'Leave unknown values blank. Use the portion and units on the nutrition label.'),
                for (final key in NutrientKey.values)
                  TextFormField(
                      initialValue: _initial?[key].numericValue?.toString(),
                      onChanged: (value) => _edited[key] = value,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                          labelText: '${key.label} (${key.unit})'),
                      validator: (value) => value?.trim().isNotEmpty == true &&
                              (mealNumber(value!) ?? -1) < 0
                          ? 'Enter a non-negative value.'
                          : null),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () {
                  if (!_key.currentState!.validate()) return;
                  final amount = mealNumber(_amount)!;
                  final sameBasis = _initialBasis == null ||
                      (_initialBasis!.amount == amount &&
                          _initialBasis!.unit == _unit);
                  final values = <NutrientKey, NutrientValue>{
                    if (sameBasis) ...?_initial?.values
                  };
                  for (final entry in _edited.entries) {
                    final value = mealNumber(entry.value);
                    if (value == null) {
                      values.remove(entry.key);
                    } else {
                      values[entry.key] = NutrientReported(value);
                    }
                  }
                  final SavedFood food = (
                    id: widget.id,
                    name: _name.trim(),
                    barcode: _barcode.trim().isEmpty ? null : _barcode.trim(),
                    nutrition: BoundedNutrition(
                        MealPortion(amount, _unit), NutrientProfile(values))
                  );
                  Navigator.pop(context, food);
                },
                child: const Text('Save food'))
          ]);
}

Future<void> createRecipe(
    BuildContext context, RecipeLibrary library, String id,
    {RecipeVersion? previous, int version = 1}) async {
  final recipe = await showDialog<RecipeVersion>(
      context: context,
      builder: (context) => _RecipeForm(
          library: library, id: id, previous: previous, version: version));
  if (recipe != null) await library.add(recipe);
}

class _RecipeForm extends StatefulWidget {
  const _RecipeForm(
      {required this.library,
      required this.id,
      this.previous,
      this.version = 1});
  final RecipeLibrary library;
  final String id;
  final RecipeVersion? previous;
  final int version;
  @override
  State<_RecipeForm> createState() => _RecipeFormState();
}

class _RecipeFormState extends State<_RecipeForm> {
  final _key = GlobalKey<FormState>();
  late var name = widget.previous?.name ?? '';
  late var servings = widget.previous?.servings.toString() ?? '1';
  late var yieldText = widget.previous?.finishedGrams?.toString() ?? '';
  late var minutes = widget.previous?.prepMinutes.toString() ?? '15';
  late var method = widget.previous?.method ?? '';
  late final ingredients = <RecipeIngredient>[...?widget.previous?.ingredients];
  Future<void> _ingredient() async {
    final food = await findMealFood(context, widget.library.foods);
    if (food == null || !mounted) return;
    final item = await editMealItem(context, food: food);
    if (item?.portion?.unit != MealUnit.grams || !mounted) return;
    setState(() => ingredients.add(RecipeIngredient(
        food: food,
        edibleGrams: item!.portion!.amount,
        purchaseName: food.name,
        purchaseGrams: food.preparation == Preparation.raw
            ? item.portion!.amount
            : null)));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.previous == null
              ? 'Create a recipe'
              : 'Save a new recipe version'),
          scrollable: true,
          content: Form(
              key: _key,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                    initialValue: name,
                    decoration: const InputDecoration(labelText: 'Recipe name'),
                    onChanged: (value) => name = value,
                    validator: (value) => value?.trim().isNotEmpty == true
                        ? null
                        : 'Enter a name.'),
                TextFormField(
                    initialValue: method,
                    maxLines: 2,
                    decoration: const InputDecoration(
                        labelText: 'Preparation notes (optional)'),
                    onChanged: (value) => method = value),
                for (final (label, initial, change, optional)
                    in <(String, String, ValueChanged<String>, bool)>[
                  ('Servings', servings, (value) => servings = value, false),
                  (
                    'Finished weight (g, optional)',
                    yieldText,
                    (value) => yieldText = value,
                    true
                  ),
                  (
                    'Preparation time (min)',
                    minutes,
                    (value) => minutes = value,
                    false
                  ),
                ])
                  TextFormField(
                      initialValue: initial,
                      decoration: InputDecoration(labelText: label),
                      onChanged: change,
                      keyboardType: TextInputType.number,
                      validator: (value) =>
                          optional && value?.trim().isEmpty == true
                              ? null
                              : (mealNumber(value ?? '') ?? 0) > 0
                                  ? null
                                  : 'Enter a positive number.'),
                for (final (index, ingredient) in ingredients.indexed)
                  ListTile(
                      title: Text(ingredient.food.name),
                      subtitle: Text('${ingredient.edibleGrams} g edible'),
                      trailing: IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () =>
                              setState(() => ingredients.removeAt(index)))),
                TextButton.icon(
                    onPressed: _ingredient,
                    icon: const Icon(Icons.add),
                    label: const Text('Add catalogue ingredient in grams')),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: ingredients.isEmpty
                    ? null
                    : () {
                        if (!_key.currentState!.validate()) return;
                        Navigator.pop(
                            context,
                            RecipeVersion(
                                id: widget.id,
                                name: name.trim(),
                                version: widget.version,
                                method: method.trim(),
                                prepMinutes: mealNumber(minutes)!.round(),
                                servings: mealNumber(servings)!,
                                finishedGrams: mealNumber(yieldText),
                                ingredients: ingredients));
                      },
                child: const Text('Save recipe'))
          ]);
}
