import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart' as core;

import 'data_transfer/data_transfer_screen.dart';
import 'features/plan/plan_screen.dart';
import 'features/plan/plan_suggestions.dart';
import 'features/plan/recipe_library.dart';
import 'features/plan/recipe_planning.dart';
import 'features/meals/meal_editor.dart';
import 'features/search/food_library.dart';
import 'features/search/library_controller.dart';
import 'features/search/library_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/search/search_screen.dart';
import 'features/plan/cooked_batches.dart';
import 'features/settings/connections_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/today/today_screen.dart';
import 'l10n/l10n_helper.dart';
import 'providers.dart';
import 'theme/glass_surface.dart';
import 'theme/tactile_controls.dart';

/// Route table.
///
/// Branches are stateful so each tab keeps its scroll position, and paths are
/// top-level so the provider OAuth redirect can target `/settings/providers`
/// later without restructuring.
final appRouter = GoRouter(
  initialLocation: '/today',
  routes: [
    GoRoute(
      path: DataTransferScreen.routeName,
      builder: (context, state) => const DataTransferScreen(),
    ),
    GoRoute(
      path: OnboardingScreen.routeName,
      builder: (context, state) => Consumer(
          builder: (context, ref, child) => OnboardingScreen(
                store: ref.watch(planningProfileStoreProvider),
                onboardingStore: state.uri.queryParameters.containsKey('first')
                    ? ref.watch(onboardingStoreProvider)
                    : null,
                gate: ref.watch(dataWriteGateProvider),
                onSaved: () =>
                    context.canPop() ? context.pop() : context.go('/today'),
                firstRun: state.uri.queryParameters.containsKey('first'),
                openConnections: (ctx) =>
                    Navigator.of(ctx, rootNavigator: true).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => ConnectionsScreen(
                      controller: ref.read(connectionsControllerProvider),
                    ),
                  ),
                ),
              )),
    ),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => HomeShell(
          navigationShell: navigationShell, currentPath: state.uri.path),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/today',
              builder: (context, state) => const TodayScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/search',
              builder: (context, state) => const SearchScreen(),
              routes: [
                GoRoute(
                  path: 'library',
                  builder: (context, state) => const _LibraryRoute(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/plan',
              builder: (context, state) =>
                  Consumer(builder: (context, ref, child) {
                final assistant = ref.watch(assistantProvider);
                return PlanScreen(
                  store: ref.watch(weekPlanStoreProvider),
                  profileStore: ref.watch(planningProfileStoreProvider),
                  assistant: assistant,
                  recipePlanning: RecipePlanning(
                      RecipeLibrary(
                        ref.watch(foodRepositoryProvider),
                        ref.watch(documentStoreProvider),
                        gate: ref.watch(dataWriteGateProvider),
                      ),
                      assistant),
                  suggestions:
                      AssistantPlanSuggestionSource(assistant: assistant),
                  onLogRecipe: (recipe, servings, slot, date) async {
                    await Navigator.of(context, rootNavigator: true)
                        .push<void>(MaterialPageRoute(
                            builder: (_) => MealEditor(
                                  repository:
                                      ref.read(photoMealRepositoryProvider),
                                  assistant: ref.read(assistantProvider),
                                  media: ref.read(managedMediaStoreProvider),
                                  activeEstimates:
                                      ref.read(activeMealEstimatesProvider),
                                  estimateStatusStore:
                                      ref.read(mealEstimateStatusStoreProvider),
                                  gate: ref.read(dataWriteGateProvider),
                                  fence: ref.read(operationFenceProvider),
                                  foods: ref.read(foodRepositoryProvider),
                                  date: date,
                                  today: ref.read(todayDiaryDateProvider),
                                  library: FoodLibrary(
                                    ref.read(documentStoreProvider),
                                    gate: ref.read(dataWriteGateProvider),
                                  ),
                                  newId: ref.read(idGeneratorProvider).next,
                                  initialDescription: recipe.name,
                                  initialItems: recipe.snapshot(servings),
                                  initialSlot: core.toIntakeMealSlot(slot),
                                )));
                  },
                );
              }),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen(),
            ),
          ],
        ),
      ],
    ),
  ],
);

/// Bottom-navigation shell around the four branches.
class HomeShell extends ConsumerStatefulWidget {
  /// Wraps [navigationShell].
  const HomeShell(
      {required this.navigationShell, required this.currentPath, super.key});

  /// The active branch container from go_router.
  final StatefulNavigationShell navigationShell;
  final String currentPath;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  late Future<bool> _setup;

  @override
  void initState() {
    super.initState();
    _setup = _loadSetup();
  }

  Future<bool> _loadSetup() async =>
      (await ref.read(planningProfileStoreProvider).load()).onboarded;

  @override
  Widget build(BuildContext context) {
    final navigationShell = widget.navigationShell;
    final l10n = saluL10n(context);
    return FutureBuilder<bool>(
      future: _setup,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(l10n.profileOpenErrorTitle,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(l10n.profileOpenErrorBody, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  SaluTactileButton(
                      onPressed: () => setState(() {
                            _setup = _loadSetup();
                          }),
                      child: Text(l10n.actionTryAgain)),
                  TextButton(
                      onPressed: () => setState(() {
                            _setup = Future.value(true);
                          }),
                      child: Text(l10n.actionContinueToDiary)),
                ]),
              ),
            ),
          );
        }
        if (snapshot.data != true) {
          return OnboardingScreen(
            store: ref.read(planningProfileStoreProvider),
            onboardingStore: ref.read(onboardingStoreProvider),
            firstRun: true,
            openConnections: (ctx) =>
                Navigator.of(ctx, rootNavigator: true).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => ConnectionsScreen(
                  controller: ref.read(connectionsControllerProvider),
                ),
              ),
            ),
            onSaved: () => setState(() {
              _setup = Future.value(true);
            }),
          );
        }
        return _home(navigationShell);
      },
    );
  }

  Widget _home(StatefulNavigationShell navigationShell) {
    final l10n = saluL10n(context);
    final titles = [
      l10n.navToday,
      l10n.navFood,
      l10n.navPlan,
      l10n.navSettings,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(titles[navigationShell.currentIndex])),
      body: navigationShell,
      bottomNavigationBar: GlassSurface(
        borderRadius: BorderRadius.zero,
        accentBorder: true,
        child: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (index) => navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          ),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.today_outlined),
              selectedIcon: const Icon(Icons.today),
              label: l10n.navToday,
            ),
            NavigationDestination(
              icon: const Icon(Icons.search_outlined),
              selectedIcon: const Icon(Icons.search),
              label: l10n.navFood,
            ),
            NavigationDestination(
              icon: const Icon(Icons.event_note_outlined),
              selectedIcon: const Icon(Icons.event_note),
              label: l10n.navPlan,
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: l10n.navSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryRoute extends ConsumerStatefulWidget {
  const _LibraryRoute();

  @override
  ConsumerState<_LibraryRoute> createState() => _LibraryRouteState();
}

class _LibraryRouteState extends ConsumerState<_LibraryRoute> {
  late final LibraryController _controller;

  @override
  void initState() {
    super.initState();
    final docs = ref.read(documentStoreProvider);
    final gate = ref.read(dataWriteGateProvider);
    final foods = ref.read(foodRepositoryProvider);
    _controller = LibraryController(
      foodLibrary: FoodLibrary(docs, gate: gate),
      recipeLibrary: RecipeLibrary(foods, docs, gate: gate),
      cookedBatches: CookedBatches(docs, gate: gate),
      gate: gate,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openEditor({
    String description = '',
    List<core.PhotoMealItem> items = const [],
  }) async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        builder: (_) => MealEditor(
          repository: ref.read(photoMealRepositoryProvider),
          assistant: ref.read(assistantProvider),
          media: ref.read(managedMediaStoreProvider),
          activeEstimates: ref.read(activeMealEstimatesProvider),
          estimateStatusStore: ref.read(mealEstimateStatusStoreProvider),
          gate: ref.read(dataWriteGateProvider),
          fence: ref.read(operationFenceProvider),
          foods: ref.read(foodRepositoryProvider),
          date: ref.read(todayDiaryDateProvider),
          today: ref.read(todayDiaryDateProvider),
          library: _controller.foodLibrary,
          newId: ref.read(idGeneratorProvider).next,
          initialDescription: description,
          initialItems: items,
        ),
      ),
    );
    if (mounted) ref.invalidate(todayMealsProvider);
  }

  @override
  Widget build(BuildContext context) {
    return LibraryScreen(
      controller: _controller,
      onUseFood: (food) async {
        final item = await pickSavedFoodPortion(context, food);
        if (mounted && item != null) {
          await _openEditor(description: food.name, items: [item]);
        }
      },
      onUseMeal: (meal) => _openEditor(
        description: meal.name,
        items: meal.items,
      ),
      onUseRecipe: (recipe) => _openEditor(
        description: recipe.name,
        items: recipe.snapshot(1),
      ),
      onUseBatch: (stored) => _openEditor(
        description: stored.batch.recipe.name,
        items: stored.batch.recipe.snapshot(1),
      ),
    );
  }
}
