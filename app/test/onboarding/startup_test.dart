import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/router.dart';
import 'package:salu_data/salu_data.dart';

GoRouter _testRouter() => GoRouter(
      initialLocation: '/today',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) =>
              HomeShell(navigationShell: shell, currentPath: state.uri.path),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/today',
                  builder: (_, __) => const Text('Diary content'),
                ),
              ],
            ),
          ],
        ),
      ],
    );

Future<void> _pumpRouter(
  WidgetTester tester, {
  required AppDatabase db,
  required PlanningProfileStore profiles,
  required GoRouter router,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        planningProfileStoreProvider.overrideWithValue(profiles),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 2),
  );
}

void main() {
  testWidgets(
      'startup shows setup once, then opens the diary on later launches',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final dir = Directory.systemTemp.createTempSync('salu_startup_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final profiles = PlanningProfileStore(
      directory: () async => dir,
      documents: LocalDocumentStore(db),
    );

    final first = _testRouter();
    await _pumpRouter(tester, db: db, profiles: profiles, router: first);

    expect(find.text('Welcome to Salu'), findsOneWidget);
    expect(find.text('Step 1 of 7'), findsOneWidget);
    expect(find.text('Diary content'), findsNothing);

    await tester.ensureVisible(find.text('Skip setup'));
    await tester.tap(find.text('Skip setup'));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );

    expect((await profiles.load()).onboarded, isTrue);
    expect(find.text('Diary content'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    first.dispose();

    final next = _testRouter();
    await _pumpRouter(tester, db: db, profiles: profiles, router: next);

    expect(find.text('Welcome to Salu'), findsNothing);
    expect(find.text('Diary content'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    next.dispose();
  });

  testWidgets(
      'already-onboarded legacy profile migrates to SQLite without showing wizard',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final dir = Directory.systemTemp.createTempSync('salu_legacy_startup_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final legacyFile =
        File('${dir.path}${Platform.pathSeparator}planning_profile_v1.json');
    legacyFile.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'startingWeight': 74.0,
        'onboarded': true,
      }),
    );

    final docs = LocalDocumentStore(db);
    final profiles = PlanningProfileStore(
      directory: () async => dir,
      documents: docs,
    );

    final router = _testRouter();
    await _pumpRouter(tester, db: db, profiles: profiles, router: router);

    expect(find.text('Welcome to Salu'), findsNothing);
    expect(find.text('Diary content'), findsOneWidget);

    final migrated = await docs.read('planning-profile');
    expect(migrated, isNotNull);
    expect(migrated!.data['onboarded'], isTrue);
    expect(migrated.data['startingWeight'], 74.0);

    await tester.pumpWidget(const SizedBox());
    router.dispose();
  });
}
