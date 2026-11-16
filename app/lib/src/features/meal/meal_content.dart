import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';
import '../../ui_support.dart';

/// Typed view of a `meal-content-v1` record plus recipe fallback.
///
/// Legacy recipes without content display their name/ingredients and never
/// claim instructions or a meal category.
class MealContent {
  const MealContent({
    this.title,
    this.description,
    this.instructions = const [],
    this.mealLabels = const [],
    this.coldSuitable,
    this.costTier,
    this.minutes,
  });

  final String? title;
  final String? description;
  final List<String> instructions;
  final List<String> mealLabels;
  final bool? coldSuitable;

  /// Stored as `lowerCost` / `standard` in the payload.
  final String? costTier;
  final int? minutes;

  bool get hasInstructions => instructions.isNotEmpty;

  factory MealContent.fromJson(Map<String, Object?> json, BuildContext context) {
    final locale = _locale(context);
    String? text(String field, [String? loc]) {
      final value = json[field];
      if (value is Map) {
        final map = Map<String, Object?>.from(value);
        final v = map[loc ?? locale] ?? map['en'];
        return v is String ? v : null;
      }
      return null;
    }

    List<String> steps(String field) {
      final value = json[field];
      if (value is Map) {
        final map = Map<String, Object?>.from(value);
        final v = map[locale] ?? map['en'];
        return v is List ? v.map((e) => e.toString()).toList() : const [];
      }
      return const [];
    }

    final rawLabels = json['mealLabels'];
    return MealContent(
      title: text('titles'),
      description: text('descriptions'),
      instructions: steps('instructions'),
      mealLabels: rawLabels is List
          ? rawLabels.map((e) => e.toString()).toList()
          : const [],
      coldSuitable: json['coldSuitable'] is bool ? json['coldSuitable']! as bool : null,
      costTier: json['costTier'] is String ? json['costTier']! as String : null,
      minutes: json['minutes'] is int ? json['minutes']! as int : null,
    );
  }

  static String _locale(BuildContext c) =>
      Localizations.localeOf(c).languageCode == 'pt' ? 'pt-PT' : 'en';

  /// Display title: localized content title when present, else recipe name.
  String titleFor(RecipeVersion recipe, BuildContext context) =>
      title ?? recipe.name;
}

/// Looks up content by recipe id, tolerating absent records.
MealContent? mealContentFor(
    Map<String, Map<String, Object?>> all, String recipeId, BuildContext context) {
  final raw = all[recipeId];
  if (raw == null) return null;
  if (raw['revision'] is! int) return null;
  try {
    return MealContent.fromJson(raw, context);
  } catch (_) {
    return null;
  }
}

/// Source credit + INSA carbohydrate detail for meal detail.
///
/// The EU legacy [NutrientKey.carbohydrateG] projection never contains
/// INSA values; source-native carbohydrate is summed through
/// [FoodCalculationService.summarize] with the retained INSA observation
/// identity.
class MealNutritionDetails extends StatelessWidget {
  const MealNutritionDetails({
    super.key,
    required this.meal,
    this.hideCalories = false,
  });

  final PlannedMeal meal;
  final bool hideCalories;

  @override
  Widget build(BuildContext context) {
    final sums = meal.nutrients;
    final rows = <Widget>[];
    for (final key in _primaryKeys) {
      if (hideCalories && key == NutrientKey.energyKcal) continue;
      rows.add(_row(context, key, sums[key]));
    }
    final insa = _insaCarbohydrate();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows) row,
        if (insa != null) ...[
          const SizedBox(height: 8),
          Text(
            'Carbohydrate (INSA): ${number(insa.toDouble())} g',
            key: const Key('carbohydrateInsa'),
          ),
          Text(
            tr(
                context,
                'Source-native INSA basis (insa_available_carbohydrate_excluding_fibre), shown separately from the EU carbohydrate projection.',
                'Base nativa INSA (insa_available_carbohydrate_excluding_fibre), mostrada separadamente da projeção europeia de hidratos de carbono.'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (meal.recipe.ingredients.any((ingredient) =>
            ingredient.food.id.startsWith('insa-bdca:'))) ...[
          const SizedBox(height: 8),
          Text(tr(context, 'Source: INSA BDCA 7.1-2026.',
              'Fonte: INSA BDCA 7.1-2026.'),
              style: Theme.of(context).textTheme.bodySmall,
              key: const Key('mealSourceCredit')),
        ],
      ],
    );
  }

  static const _primaryKeys = [
    NutrientKey.energyKcal,
    NutrientKey.proteinG,
    NutrientKey.carbohydrateG,
    NutrientKey.fatG,
  ];

  Widget _row(BuildContext context, NutrientKey key, NutrientSum? sum) {
    final known = sum != null && sum.knownEntries > 0;
    final value = known ? sum.recordedValue : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Text(nutrientLabel(context, key.wire)),
        const Spacer(),
        Text(value == null
            ? '-- ${key.unit}'
            : '${number(value)} ${key.unit}'),
        if (value != null && sum != null && !sum.isComplete) ...[
          const SizedBox(width: 8),
          Text(tr(context, 'partial', 'parcial')),
        ],
      ]),
    );
  }

  Exact? _insaCarbohydrate() {
    const identity = NutrientIdentity(
      'carbohydrate_g',
      'g',
      'insa_available_carbohydrate_excluding_fibre',
    );
    final observed = <ObservedFood>[];
    for (final ingredient in meal.recipe.ingredients) {
      final grams = ingredient.grams * meal.portions / meal.recipe.servings;
      if (!grams.positive) continue;
      final observation = ingredient.food.observations
          .where((o) => o.nutrient.key == identity.key)
          .toList();
      if (observation.isEmpty) continue;
      observed.add(ObservedFood(
        id: ingredient.food.id,
        quantity: FoodAmount.exact(grams, FoodUnit.g),
        observations: observation,
      ));
    }
    if (observed.isEmpty) return null;
    final summary = const FoodCalculationService().summarize(
      identity,
      observed,
      DiaryCompleteness.unknown,
    );
    return summary.recordedSum;
  }
}

/// Meal detail page: title, time, ingredients, steps, nutrition/source,
/// caveats. Legacy recipes without content show ingredients only.
class MealDetailScreen extends StatelessWidget {
  const MealDetailScreen({
    super.key,
    required this.meal,
    this.content,
    this.hideCalories = false,
    this.onConsume,
    this.onSwap,
    this.onLikeDislike,
    this.onTooMuchWork,
  });

  final PlannedMeal meal;
  final MealContent? content;
  final bool hideCalories;
  final VoidCallback? onConsume;
  final VoidCallback? onSwap;
  final void Function(String action)? onLikeDislike;
  final void Function()? onTooMuchWork;

  @override
  Widget build(BuildContext context) {
    final recipe = meal.recipe;
    final c = content;
    final title = c?.title ?? recipe.name;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '${meal.slot.date} · ${_label(context, meal.slot.label)} · ${recipe.minutes} min · ${number(meal.portions.toDouble())} ${tr(context, 'servings', 'porções')}',
          ),
          const SizedBox(height: 16),
          if (c?.description != null && c!.description!.isNotEmpty) ...[
            Text(c.description!, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
          ],
          Text(tr(context, 'Ingredients', 'Ingredientes'),
              style: Theme.of(context).textTheme.titleMedium),
          for (final i in recipe.ingredients)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(i.food.name),
              trailing: Text('${number((i.grams * meal.portions / recipe.servings).toDouble())} g'),
            ),
          if (c != null && c.hasInstructions) ...[
            const SizedBox(height: 16),
            Text(tr(context, 'Preparation', 'Preparação'),
                style: Theme.of(context).textTheme.titleMedium),
            for (var idx = 0; idx < c.instructions.length; idx++)
              ListTile(
                leading: CircleAvatar(child: Text('${idx + 1}')),
                title: Text(c.instructions[idx]),
              ),
          ] else if (c != null) ...[
            const SizedBox(height: 8),
            Text(tr(context, 'No preparation steps stored for this recipe.',
                'Sem passos de preparação guardados para esta receita.')),
          ],
          const SizedBox(height: 16),
          ExpansionTile(
            title: Text(tr(context, 'Nutrition and sources', 'Nutrição e fontes')),
            children: [Padding(padding: const EdgeInsets.all(16),
                child: MealNutritionDetails(meal: meal, hideCalories: hideCalories))]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (onConsume != null)
              FilledButton.icon(
                onPressed: onConsume,
                icon: const Icon(Icons.check),
                label: Text(tr(context, 'I ate this', 'Comi isto')),
              ),
            if (onSwap != null)
              OutlinedButton.icon(
                onPressed: onSwap,
                icon: const Icon(Icons.swap_horiz_outlined),
                label: Text(tr(context, 'Swap', 'Trocar')),
              ),
            if (onLikeDislike != null) ...[
              OutlinedButton.icon(
                key: const Key('mealLike'),
                onPressed: () => onLikeDislike!('like'),
                icon: const Icon(Icons.thumb_up_outlined),
                label: Text(tr(context, 'Like', 'Gosto')),
              ),
              OutlinedButton.icon(
                key: const Key('mealDislike'),
                onPressed: () => onLikeDislike!('dislike'),
                icon: const Icon(Icons.thumb_down_outlined),
                label: Text(tr(context, 'Not for me', 'Não é para mim')),
              ),
            ],
            if (onTooMuchWork != null)
              TextButton(
                key: const Key('mealTooMuchWork'),
                onPressed: onTooMuchWork,
                child: Text(tr(context, 'Too much work', 'Demasiado trabalho')),
              ),
          ]),
        ],
      ),
    );
  }

  String _label(BuildContext c, String label) => switch (label) {
        'breakfast' => tr(c, 'Breakfast', 'Pequeno-almoço'),
        'lunch' => tr(c, 'Lunch', 'Almoço'),
        'snack' => tr(c, 'Snack', 'Lanche'),
        'dinner' => tr(c, 'Dinner', 'Jantar'),
        _ => label,
      };
}
