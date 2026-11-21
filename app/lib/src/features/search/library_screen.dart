import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';

import '../../l10n/l10n_helper.dart';
import '../../theme/glass_surface.dart';
import '../../theme/salu_theme.dart';
import '../../theme/tactile_controls.dart';
import '../plan/cooked_batches.dart';
import 'food_library.dart';
import 'library_controller.dart';
import 'library_sections.dart';

/// Stateful, searchable 4-tab food library route (`/search/library`).
///
/// Tapping any item invokes its callback once and never writes intake directly;
/// the caller routes into the normal meal editor for portion review.
class LibraryScreen extends StatefulWidget {
  /// Creates the library screen.
  const LibraryScreen({
    required this.controller,
    required this.onUseFood,
    required this.onUseMeal,
    required this.onUseRecipe,
    required this.onUseBatch,
    super.key,
  });

  /// Route path under the Food branch.
  static const routePath = '/search/library';

  /// Unified library state controller.
  final LibraryController controller;

  /// Called when the user selects a saved food.
  final ValueChanged<SavedFood> onUseFood;

  /// Called when the user selects a saved meal.
  final ValueChanged<SavedMeal> onUseMeal;

  /// Called when the user selects a recipe.
  final ValueChanged<RecipeVersion> onUseRecipe;

  /// Called when the user selects a cooked batch (leftovers).
  final ValueChanged<StoredBatch> onUseBatch;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late final TextEditingController _searchController;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.controller.query);
    widget.controller.addListener(_onControllerChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _searchController.text = widget.controller.query;
      _refresh();
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() => _loadError = null);
    try {
      await widget.controller.refresh();
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = saluL10n(context);
    final tokens = SaluSurfaceTokens.of(context);
    final theme = Theme.of(context);
    final ctrl = widget.controller;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.libraryTitle),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: GlassSurface(
              frosted: false,
              borderRadius: BorderRadius.zero,
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: tokens.accentSage,
                labelColor: tokens.textPrimary,
                unselectedLabelColor: tokens.textMuted,
                tabs: [
                  Tab(text: l10n.libraryTabFoods),
                  Tab(text: l10n.libraryTabMeals),
                  Tab(text: l10n.libraryTabRecipes),
                  Tab(text: l10n.libraryTabLeftovers),
                ],
              ),
            ),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: ctrl.setQuery,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.librarySearchHint,
                  suffixIcon: ctrl.query.isNotEmpty
                      ? IconButton(
                          tooltip: l10n.actionClose,
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            ctrl.setQuery('');
                          },
                        )
                      : null,
                ),
              ),
            ),
            if (ctrl.loading)
              Semantics(
                label: l10n.libraryTitle,
                child: const LinearProgressIndicator(),
              ),
            if (_loadError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: GlassSurface(
                  frosted: false,
                  accentBorder: true,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.libraryLoadError,
                        style: theme.textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      SaluTactileButton(
                        onPressed: _refresh,
                        child: Text(l10n.actionTryAgain),
                      ),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: TabBarView(
                  children: [
                    LibraryFoodsSection(
                      foods: ctrl.filteredFoods,
                      favorites: ctrl.favorites,
                      onUseFood: widget.onUseFood,
                      onToggleFavorite: ctrl.toggleFavorite,
                    ),
                    LibraryMealsSection(
                      meals: ctrl.filteredMeals,
                      onUseMeal: widget.onUseMeal,
                    ),
                    LibraryRecipesSection(
                      recipes: ctrl.filteredRecipes,
                      onUseRecipe: widget.onUseRecipe,
                    ),
                    LibraryLeftoversSection(
                      batches: ctrl.filteredBatches,
                      onUseBatch: widget.onUseBatch,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
