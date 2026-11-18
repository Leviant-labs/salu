import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart' as core;

import 'features/plan/plan_screen.dart';
import 'features/plan/plan_suggestions.dart';
import 'features/plan/recipe_library.dart';
import 'features/plan/recipe_planning.dart';
import 'features/meals/meal_editor.dart';
import 'features/search/food_library.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/search/search_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/today/today_screen.dart';
import 'providers.dart';

/// Route table.
///
/// Branches are stateful so each tab keeps its scroll position, and paths are
/// top-level so the provider OAuth redirect can target `/settings/providers`
/// later without restructuring.
final appRouter = GoRouter(
  initialLocation: '/today',
  routes: [
    GoRoute(
      path: OnboardingScreen.routeName,
      builder: (context, state) => Consumer(
          builder: (context, ref, child) => OnboardingScreen(
                store: ref.watch(planningProfileStoreProvider),
                onSaved: () =>
                    context.canPop() ? context.pop() : context.go('/today'),
                firstRun: state.uri.queryParameters.containsKey('first'),
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
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/plan',
              builder: (context, state) => Consumer(
                  builder: (context, ref, child) => PlanScreen(
                        store: ref.watch(weekPlanStoreProvider),
                        profileStore: ref.watch(planningProfileStoreProvider),
                        recipePlanning: RecipePlanning(
                            RecipeLibrary(ref.watch(foodRepositoryProvider),
                                ref.watch(documentStoreProvider)),
                            saluAssistant),
                        suggestions: AssistantPlanSuggestionSource(
                            assistant: saluAssistant),
                        onLogRecipe: (recipe, servings, slot, date) async {
                          await Navigator.of(context, rootNavigator: true)
                              .push<void>(MaterialPageRoute(
                                  builder: (_) => MealEditor(
                                        repository: ref
                                            .read(photoMealRepositoryProvider),
                                        assistant: saluAssistant,
                                        foods: ref.read(foodRepositoryProvider),
                                        date: date,
                                        today: ref.read(todayDiaryDateProvider),
                                        library: FoodLibrary(
                                            ref.read(documentStoreProvider)),
                                        newId:
                                            ref.read(idGeneratorProvider).next,
                                        initialDescription: recipe.name,
                                        initialItems: recipe.snapshot(servings),
                                        initialSlot: core.MealSlot.values
                                            .byName(slot.name),
                                      )));
                        },
                      )),
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final profile = await ref.read(planningProfileStoreProvider).load();
        if (mounted && !profile.onboarded && widget.currentPath == '/today') {
          await context.push('${OnboardingScreen.routeName}?first=1');
        }
      } catch (_) {
        // A corrupt or inaccessible profile cannot block diary use.
      }
    });
  }

  static const _titles = ['Today', 'Food', 'Plan', 'Settings'];

  @override
  Widget build(BuildContext context) {
    final navigationShell = widget.navigationShell;
    return Scaffold(
      appBar: AppBar(title: Text(_titles[navigationShell.currentIndex])),
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'Food',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_note_outlined),
            selectedIcon: Icon(Icons.event_note),
            label: 'Plan',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
