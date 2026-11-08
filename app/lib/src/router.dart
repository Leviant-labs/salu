import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'features/plan/plan_screen.dart';
import 'ui_support.dart';
import 'features/search/search_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/today/today_screen.dart';

/// Route table.
///
/// Branches are stateful so each tab keeps its scroll position, and paths are
/// top-level so the provider OAuth redirect can target `/settings/providers`
/// later without restructuring.
final appRouter = GoRouter(
  initialLocation: '/today',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          HomeShell(navigationShell: navigationShell),
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
              builder: (context, state) => const PlanScreen(),
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
class HomeShell extends StatelessWidget {
  /// Wraps [navigationShell].
  const HomeShell({required this.navigationShell, super.key});

  /// The active branch container from go_router.
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final titles = [
      tr(context, 'Today', 'Hoje'),
      tr(context, 'Food', 'Alimentos'),
      tr(context, 'Plan', 'Plano'),
      tr(context, 'Settings', 'Definições')
    ];
    return Scaffold(
      appBar: AppBar(title: Text(titles[navigationShell.currentIndex])),
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: titles[0],
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: titles[1],
          ),
          NavigationDestination(
            icon: Icon(Icons.event_note_outlined),
            selectedIcon: Icon(Icons.event_note),
            label: titles[2],
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: titles[3],
          ),
        ],
      ),
    );
  }
}
