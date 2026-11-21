import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../data_transfer/data_write_gate.dart';
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
  const FoodLibrary(this.documents, {this.gate});
  final LocalDocumentStore documents;
  final DataWriteGate? gate;
  static const _key = 'food-library';
  static const int currentVersion = 1;

  Future<T> _runWrite<T>(Future<T> Function() work) =>
      gate != null ? gate!.runWrite(work) : work();

  Future<List<SavedFood>> foods() async =>
      (await _loadValidated())?.foods ?? const [];

  Future<List<SavedMeal>> meals() async =>
      (await _loadValidated())?.meals ?? const [];

  Future<Set<String>> favorites() async =>
      (await _loadValidated())?.favorites ?? const <String>{};

  Future<void> toggleFavorite(String id) => _update((json) {
        final ids = _decodeFavorites(json['favorites']).toSet();
        if (!ids.remove(id)) ids.add(id);
        return {...json, 'favorites': ids.toList()};
      });

  Future<void> saveFood(SavedFood food) => _update((json) {
        final existingRows = _rawList(json['foods'], 'foods');
        final rows =
            existingRows.where((row) => (row as Map)['id'] != food.id).toList();
        if (food.barcode != null &&
            rows.any((row) => (row as Map)['barcode'] == food.barcode)) {
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
              'nutrients': food.nutrition.nutrients.toJson(),
            }
          ]
        };
      });

  Future<void> saveMeal(SavedMeal meal) => _update((json) => {
        ...json,
        'meals': [
          ..._rawList(json['meals'], 'meals')
              .where((row) => (row as Map)['id'] != meal.id),
          {
            'id': meal.id,
            'name': meal.name,
            'items': [
              for (final item in meal.items) encodePhotoMealItem(item),
            ]
          },
        ]
      });

  Future<
      ({
        int revision,
        Map<String, dynamic> data,
        List<SavedFood> foods,
        List<SavedMeal> meals,
        Set<String> favorites,
      })?> _loadValidated() async {
    final record = await documents.read(_key);
    if (record == null) return null;
    final parsed = _parseDocument(record.data);
    if (!isCurrentDocumentVersion(
      record.data,
      currentVersion,
      documentName: _key,
    )) {
      final migrated = <String, Object?>{
        ...record.data,
        'version': currentVersion,
      };
      if (await _runWrite(
          () => documents.put(_key, record.revision, migrated))) {
        return (
          revision: record.revision + 1,
          data: Map<String, dynamic>.from(migrated),
          foods: parsed.foods,
          meals: parsed.meals,
          favorites: parsed.favorites,
        );
      }
      final latest = await documents.read(_key);
      if (latest == null) return null;
      final latestParsed = _parseDocument(latest.data);
      return (
        revision: latest.revision,
        data: latest.data,
        foods: latestParsed.foods,
        meals: latestParsed.meals,
        favorites: latestParsed.favorites,
      );
    }
    return (
      revision: record.revision,
      data: record.data,
      foods: parsed.foods,
      meals: parsed.meals,
      favorites: parsed.favorites,
    );
  }

  ({
    List<SavedFood> foods,
    List<SavedMeal> meals,
    Set<String> favorites,
  }) _parseDocument(Map<String, dynamic> data) {
    isCurrentDocumentVersion(data, currentVersion, documentName: _key);
    final foods = [
      for (final raw in _rawList(data['foods'], 'foods')) _decodeFood(raw),
    ];
    final meals = [
      for (final raw in _rawList(data['meals'], 'meals')) _decodeMeal(raw),
    ];
    final favorites = _decodeFavorites(data['favorites']);
    return (foods: foods, meals: meals, favorites: favorites);
  }

  static List<Object?> _rawList(Object? raw, String field) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw FormatException('Expected list for $field in $_key', raw);
    }
    return raw;
  }

  static Set<String> _decodeFavorites(Object? raw) {
    if (raw == null) return const <String>{};
    if (raw is! List) {
      throw FormatException('Expected list for favorites in $_key', raw);
    }
    return {
      for (final item in raw)
        if (item is String)
          item
        else
          throw FormatException('Expected string favorite id in $_key', item),
    };
  }

  static SavedFood _decodeFood(Object? raw) {
    if (raw is! Map) {
      throw FormatException('Invalid saved food entry in $_key', raw);
    }
    final map = Map<String, dynamic>.from(raw);
    final id = map['id'];
    if (id is! String || id.trim().isEmpty) {
      throw FormatException('Invalid saved food id', id);
    }
    final name = map['name'];
    if (name is! String || name.trim().isEmpty) {
      throw FormatException('Invalid saved food name', name);
    }
    final barcode = map['barcode'];
    if (barcode != null && barcode is! String) {
      throw FormatException('Invalid saved food barcode', barcode);
    }
    final amount = map['amount'];
    if (amount is! num || !amount.isFinite || amount <= 0) {
      throw FormatException('Invalid saved food amount', amount);
    }
    final rawUnit = map['unit'];
    if (rawUnit is! String) {
      throw FormatException('Invalid saved food unit', rawUnit);
    }
    MealUnit? unit;
    for (final value in MealUnit.values) {
      if (value.name == rawUnit) {
        unit = value;
        break;
      }
    }
    if (unit == null) {
      throw FormatException('Unknown saved food unit: $rawUnit', rawUnit);
    }
    final nutrients = decodeNutrientProfile(map['nutrients']);
    return (
      id: id,
      name: name,
      barcode: barcode as String?,
      nutrition: BoundedNutrition(
        MealPortion(amount.toDouble(), unit),
        nutrients,
      ),
    );
  }

  static SavedMeal _decodeMeal(Object? raw) {
    if (raw is! Map) {
      throw FormatException('Invalid saved meal entry in $_key', raw);
    }
    final map = Map<String, dynamic>.from(raw);
    final id = map['id'];
    if (id is! String || id.trim().isEmpty) {
      throw FormatException('Invalid saved meal id', id);
    }
    final name = map['name'];
    if (name is! String || name.trim().isEmpty) {
      throw FormatException('Invalid saved meal name', name);
    }
    final rawItems = map['items'];
    if (rawItems is! List) {
      throw FormatException('Invalid saved meal items', rawItems);
    }
    return (
      id: id,
      name: name,
      items: [
        for (final item in rawItems) decodePhotoMealItem(item),
      ],
    );
  }

  Future<void> _update(
      Map<String, Object?> Function(Map<String, dynamic>) change) async {
    final old = await _loadValidated();
    final base = old?.data ?? const <String, dynamic>{};
    if (!await _runWrite(() => documents.put(_key, old?.revision ?? 0, {
          ...base,
          ...change(base),
          'version': currentVersion,
        }))) {
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
  final nutrients = food.nutrition.forPortion(portion);
  final reviewIssues = nutrients == null
      ? const <NutritionIssue>[]
      : screenNutrition(nutrients, portion: portion).issues;
  return PhotoMealItem(
      name: food.name,
      portion: portion,
      nutrients: nutrients,
      source: 'saved-food:${food.id}',
      reviewIssues: reviewIssues);
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
  late var _declaredAllergens = widget.previous?.allergens != null;
  late final Set<AllergenId> _selectedAllergens = {
    for (final tag in widget.previous?.allergens ?? const <String>{})
      if (resolveAllergen(tag) case final id?) id,
  };
  late final List<String> _legacyAllergenTags = [
    for (final tag in widget.previous?.allergens ?? const <String>{})
      if (resolveAllergen(tag) == null) tag,
  ];
  late var _allergenSource = widget.previous?.allergenSource ?? '';
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
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Allergen declaration',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('Unknown status'),
                      selected: !_declaredAllergens,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => _declaredAllergens = false);
                        }
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Declared allergens'),
                      selected: _declaredAllergens,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => _declaredAllergens = true);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                if (!_declaredAllergens)
                  const Text(
                      'Unknown status: excluded when strict allergies are active.')
                else ...[
                  const Text(
                      'Select allergens in listed ingredients. Leaving all unchecked declares none of the 14 canonical allergens (not a cross-contamination guarantee).'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final id in AllergenId.values)
                        FilterChip(
                          label: Text(id.label),
                          selected: _selectedAllergens.contains(id),
                          onSelected: (selected) => setState(() {
                            if (selected) {
                              _selectedAllergens.add(id);
                            } else {
                              _selectedAllergens.remove(id);
                            }
                          }),
                        ),
                    ],
                  ),
                  if (_selectedAllergens.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child:
                          Text('Declared: none of the 14 canonical allergens.'),
                    ),
                  TextFormField(
                    initialValue: _allergenSource,
                    decoration: const InputDecoration(
                      labelText: 'Allergen source / provenance',
                      hintText: 'e.g. Checked product ingredient labels',
                    ),
                    onChanged: (value) => _allergenSource = value,
                  ),
                ],
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
                                ingredients: ingredients,
                                allergens: _declaredAllergens
                                    ? {
                                        for (final id in _selectedAllergens)
                                          id.name,
                                        ..._legacyAllergenTags,
                                      }
                                    : null,
                                allergenSource: _declaredAllergens &&
                                        _allergenSource.trim().isNotEmpty
                                    ? _allergenSource.trim()
                                    : null));
                      },
                child: const Text('Save recipe'))
          ]);
}
