import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';

import '../../l10n/l10n_helper.dart';
import '../../theme/glass_surface.dart';
import '../../theme/salu_theme.dart';
import '../plan/cooked_batches.dart';
import 'food_library.dart';

/// Lazy list section for saved foods in [LibraryScreen].
class LibraryFoodsSection extends StatelessWidget {
  const LibraryFoodsSection({
    required this.foods,
    required this.favorites,
    required this.onUseFood,
    this.onToggleFavorite,
    super.key,
  });

  final List<SavedFood> foods;
  final Set<String> favorites;
  final ValueChanged<SavedFood> onUseFood;
  final ValueChanged<String>? onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final l10n = saluL10n(context);
    if (foods.isEmpty) {
      return _EmptyLibraryState(message: l10n.libraryEmptyFoods);
    }
    return ListView.builder(
      key: const PageStorageKey<String>('library-foods-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: foods.length,
      itemBuilder: (context, index) {
        final food = foods[index];
        final isFav = favorites.contains(food.id);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: GlassSurface(
            frosted: false,
            borderRadius: BorderRadius.circular(16),
            child: ListTile(
              title: Text(food.name),
              subtitle: food.barcode != null ? Text(food.barcode!) : null,
              trailing: onToggleFavorite == null
                  ? const Icon(Icons.chevron_right)
                  : IconButton(
                      tooltip: l10n.libraryFavoriteLabel,
                      icon: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        color: isFav
                            ? SaluSurfaceTokens.of(context).accentSage
                            : null,
                      ),
                      onPressed: () => onToggleFavorite!(food.id),
                    ),
              onTap: () => onUseFood(food),
            ),
          ),
        );
      },
    );
  }
}

/// Lazy list section for saved meals in [LibraryScreen].
class LibraryMealsSection extends StatelessWidget {
  const LibraryMealsSection({
    required this.meals,
    required this.onUseMeal,
    super.key,
  });

  final List<SavedMeal> meals;
  final ValueChanged<SavedMeal> onUseMeal;

  @override
  Widget build(BuildContext context) {
    final l10n = saluL10n(context);
    if (meals.isEmpty) {
      return _EmptyLibraryState(message: l10n.libraryEmptyMeals);
    }
    return ListView.builder(
      key: const PageStorageKey<String>('library-meals-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: meals.length,
      itemBuilder: (context, index) {
        final meal = meals[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: GlassSurface(
            frosted: false,
            borderRadius: BorderRadius.circular(16),
            child: ListTile(
              title: Text(meal.name),
              subtitle: meal.items.isNotEmpty
                  ? Text(meal.items.map((item) => item.name).join(', '))
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onUseMeal(meal),
            ),
          ),
        );
      },
    );
  }
}

/// Lazy list section for recipes in [LibraryScreen].
class LibraryRecipesSection extends StatelessWidget {
  const LibraryRecipesSection({
    required this.recipes,
    required this.onUseRecipe,
    super.key,
  });

  final List<RecipeVersion> recipes;
  final ValueChanged<RecipeVersion> onUseRecipe;

  @override
  Widget build(BuildContext context) {
    final l10n = saluL10n(context);
    if (recipes.isEmpty) {
      return _EmptyLibraryState(message: l10n.libraryEmptyRecipes);
    }
    return ListView.builder(
      key: const PageStorageKey<String>('library-recipes-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: recipes.length,
      itemBuilder: (context, index) {
        final recipe = recipes[index];
        final title = recipe.version == 1
            ? recipe.name
            : '${recipe.name} · v${recipe.version}';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: GlassSurface(
            frosted: false,
            borderRadius: BorderRadius.circular(16),
            child: ListTile(
              title: Text(title),
              subtitle: recipe.method.isNotEmpty
                  ? Text(
                      recipe.method,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onUseRecipe(recipe),
            ),
          ),
        );
      },
    );
  }
}

/// Lazy list section for cooked batches (leftovers) in [LibraryScreen].
class LibraryLeftoversSection extends StatelessWidget {
  const LibraryLeftoversSection({
    required this.batches,
    required this.onUseBatch,
    super.key,
  });

  final List<StoredBatch> batches;
  final ValueChanged<StoredBatch> onUseBatch;

  @override
  Widget build(BuildContext context) {
    final l10n = saluL10n(context);
    if (batches.isEmpty) {
      return _EmptyLibraryState(message: l10n.libraryEmptyLeftovers);
    }
    return ListView.builder(
      key: const PageStorageKey<String>('library-leftovers-list'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: batches.length,
      itemBuilder: (context, index) {
        final stored = batches[index];
        final remaining =
            (stored.batch.cookedServings * stored.batch.remainingFraction)
                .round();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: GlassSurface(
            frosted: false,
            borderRadius: BorderRadius.circular(16),
            child: ListTile(
              title: Text(stored.batch.recipe.name),
              subtitle: Text(l10n.libraryServingsRemaining(remaining)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onUseBatch(stored),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyLibraryState extends StatelessWidget {
  const _EmptyLibraryState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = SaluSurfaceTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.textMuted),
        ),
      ),
    );
  }
}
