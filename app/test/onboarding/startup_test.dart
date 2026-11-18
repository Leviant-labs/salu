import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/router.dart';

class _Profile extends PlanningProfileStore {
  PlanningProfile profile = const PlanningProfile();
  @override
  Future<PlanningProfile> load() async => profile;
  @override
  Future<void> skipOnboarding() async =>
      profile = const PlanningProfile(onboarded: true);
}

void main() {
  testWidgets(
      'startup shows setup once, then opens the diary on later launches',
      (tester) async {
    final store = _Profile();
    GoRouter router() => GoRouter(initialLocation: '/today', routes: [
          StatefulShellRoute.indexedStack(
            builder: (context, state, shell) =>
                HomeShell(navigationShell: shell, currentPath: state.uri.path),
            branches: [
              StatefulShellBranch(routes: [
                GoRoute(
                    path: '/today',
                    builder: (_, __) => const Text('Diary content'))
              ])
            ],
          ),
        ]);
    final first = router();
    await tester.pumpWidget(ProviderScope(
        overrides: [planningProfileStoreProvider.overrideWithValue(store)],
        child: MaterialApp.router(routerConfig: first)));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Salu'), findsOneWidget);
    expect(find.text('Diary content'), findsNothing);
    await tester.ensureVisible(find.text('Skip for now'));
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(store.profile.onboarded, isTrue);
    expect(find.text('Diary content'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    first.dispose();
    final next = router();
    await tester.pumpWidget(ProviderScope(
        overrides: [planningProfileStoreProvider.overrideWithValue(store)],
        child: MaterialApp.router(routerConfig: next)));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Salu'), findsNothing);
    expect(find.text('Diary content'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    next.dispose();
  });
}
