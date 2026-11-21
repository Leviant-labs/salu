import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/onboarding/onboarding_wizard.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

final class _RejectingHttpOverrides extends HttpOverrides {
  int requests = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('External HTTP is forbidden during onboarding');
  }
}

final class _SlowWriteInterceptor extends QueryInterceptor {
  Completer<void>? writeGate;
  int draftWriteCount = 0;

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('local_documents')) {
      draftWriteCount++;
      final gate = writeGate;
      if (gate != null && !gate.isCompleted) {
        await gate.future;
      }
    }
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('local_documents')) {
      draftWriteCount++;
      final gate = writeGate;
      if (gate != null && !gate.isCompleted) {
        await gate.future;
      }
    }
    return super.runUpdate(executor, statement, args);
  }
}

void main() {
  testWidgets('Next advances one page and Back retains answers',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await tester.pumpWidget(
      MaterialApp(home: OnboardingWizard(store: store, onCompleted: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('Step 1 of 7'), findsOneWidget);
    expect(find.text('Starting weight'), findsNothing);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Declared energy goal (optional)'),
      'Steady energy',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 3 of 7'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(
              TextFormField,
              'Declared energy goal (optional)',
            ),
          )
          .controller
          ?.text,
      'Steady energy',
    );

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 7'), findsOneWidget);
  });

  testWidgets('walks through all seven pages and completes on Review',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    final store = OnboardingStore(docs);
    var completed = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingWizard(
          store: store,
          onCompleted: () => completed++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Welcome
    expect(find.text('Step 1 of 7'), findsOneWidget);
    expect(find.text('Welcome to Salu'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 2. Goals
    expect(find.text('Step 2 of 7'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Declared energy goal (optional)'),
      'Feel better',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Usual activity (optional)'),
      'Daily walks',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 3. Starting point
    expect(find.text('Step 3 of 7'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Starting weight'),
      '75,5',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 4. Preferences
    expect(find.text('Step 4 of 7'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Likes'),
      'Oats',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Dislikes'),
      'Mushrooms',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Must exclude'),
      'Sesame',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Strict allergies (optional)'),
      'Peanut',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 5. Targets
    expect(find.text('Step 5 of 7'), findsOneWidget);
    expect(
      find.textContaining('No automatic targets are calculated'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        'Declared daily energy target (optional)',
      ),
      '2100',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Protein'),
      '120',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 6. AI setup
    expect(find.text('Step 6 of 7'), findsOneWidget);
    expect(
      find.textContaining('never authorizes meal or photo uploads'),
      findsOneWidget,
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    // 7. Review
    expect(find.text('Step 7 of 7'), findsOneWidget);
    expect(find.text('Review your setup'), findsOneWidget);
    expect(find.textContaining('75.5 kg'), findsOneWidget);
    expect(find.textContaining('Feel better'), findsOneWidget);
    expect(find.textContaining('Daily walks'), findsOneWidget);
    expect(find.textContaining('2100 kcal'), findsOneWidget);
    expect(find.textContaining('Oats'), findsOneWidget);
    expect(find.textContaining('Peanut'), findsOneWidget);

    await tester.tap(find.text('Finish setup'));
    await tester.pumpAndSettle();

    expect(completed, 1);
    expect(await docs.read('onboarding-draft'), isNull);
    final saved = await docs.read('planning-profile');
    expect(saved, isNotNull);
    final profile = PlanningProfile.fromJson(saved!.data);
    expect(profile.onboarded, isTrue);
    expect(profile.startingWeight, 75.5);
    expect(profile.energyGoal, 'Feel better');
    expect(profile.habitualActivity, 'Daily walks');
    expect(profile.dailyEnergyKcal, 2100);
    expect(profile.proteinGrams, 120);
    expect(profile.preferences.likes, 'Oats');
    expect(profile.preferences.strictAllergens, 'Peanut');
  });

  testWidgets('resumes saved answers after widget disposal', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));

    await tester.pumpWidget(
      MaterialApp(home: OnboardingWizard(store: store, onCompleted: () {})),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Declared energy goal (optional)'),
      'Build stamina',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Starting weight'),
      '68',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Step 4 of 7'), findsOneWidget);

    // Dispose widget tree completely (simulating process kill/relaunch).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      MaterialApp(home: OnboardingWizard(store: store, onCompleted: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('Step 4 of 7'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Step 3 of 7'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Starting weight'),
          )
          .controller
          ?.text,
      '68',
    );

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(
              TextFormField,
              'Declared energy goal (optional)',
            ),
          )
          .controller
          ?.text,
      'Build stamina',
    );
  });

  testWidgets(
      'invalid number stays on page and clearing optional number saves null',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await store.save(
      const OnboardingDraft(
        step: OnboardingStep.startingPoint,
        profile: PlanningProfile(startingWeight: 70),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: OnboardingWizard(store: store, onCompleted: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('Step 3 of 7'), findsOneWidget);

    for (final invalid in ['abc', '-5', '0', 'Infinity']) {
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Starting weight'),
        invalid,
      );
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(find.text('Step 3 of 7'), findsOneWidget);
      expect(find.text('Enter a number greater than zero.'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Starting weight'),
            )
            .controller
            ?.text,
        invalid,
      );
    }

    // Clearing a previously entered optional number sets it back to null.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Starting weight'),
      '',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Step 4 of 7'), findsOneWidget);
    final reloaded = await store.load();
    expect(reloaded.profile.startingWeight, isNull);
  });

  testWidgets('save error blocks navigation and retains raw editing text',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await store.save(
      const OnboardingDraft(step: OnboardingStep.startingPoint),
    );

    await tester.pumpWidget(
      MaterialApp(home: OnboardingWizard(store: store, onCompleted: () {})),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Starting weight'),
      '73.5',
    );

    // 1. Simulated storage exception via SQLite trigger.
    await db.customStatement('''
      CREATE TRIGGER fail_draft_update
      BEFORE UPDATE ON local_documents
      WHEN NEW.id = 'onboarding-draft'
      BEGIN
        SELECT RAISE(ABORT, 'simulated draft write failure');
      END;
    ''');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Step 3 of 7'), findsOneWidget);
    expect(
      find.text('Could not save progress. Your answers are still here.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Starting weight'),
          )
          .controller
          ?.text,
      '73.5',
    );

    // 2. Simulated stale revision conflict.
    await db.customStatement('DROP TRIGGER fail_draft_update;');
    final latest = await store.load();
    expect(
      await store.save(latest.copyWith(step: OnboardingStep.preferences)),
      isTrue,
    );

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Step 3 of 7'), findsOneWidget);
    expect(
      find.text('Setup changed. Reopen the latest step and try again.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Starting weight'),
          )
          .controller
          ?.text,
      '73.5',
    );
  });

  testWidgets('two rapid Next taps advance only one page', (tester) async {
    final interceptor = _SlowWriteInterceptor();
    final db = AppDatabase(NativeDatabase.memory().interceptWith(interceptor));
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));

    await tester.pumpWidget(
      MaterialApp(home: OnboardingWizard(store: store, onCompleted: () {})),
    );
    await tester.pumpAndSettle();

    final gate = Completer<void>();
    interceptor.writeGate = gate;

    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.tap(find.text('Next'), warnIfMissed: false);
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();

    expect(interceptor.draftWriteCount, 1);
    expect(find.text('Step 2 of 7'), findsOneWidget);
    final saved = await store.load();
    expect(saved.step, OnboardingStep.goals);
  });

  testWidgets(
      'Android back routes to preceding step and exiting first page does not complete setup',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    final store = OnboardingStore(docs);
    var completed = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingWizard(
          store: store,
          onCompleted: () => completed++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Step 1 of 7'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(completed, 0);
    expect(await docs.read('planning-profile'), isNull);
  });

  testWidgets('empty optional pages can be skipped or advanced',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    var completed = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingWizard(
          store: store,
          onCompleted: () => completed++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Welcome -> Goals
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 7'), findsOneWidget);

    // Skip through Goals, StartingPoint, Preferences, Targets, AI Setup
    for (var step = 2; step <= 6; step++) {
      expect(find.text('Step $step of 7'), findsOneWidget);
      await tester.tap(find.text('Skip this step'));
      await tester.pumpAndSettle();
    }

    expect(find.text('Step 7 of 7'), findsOneWidget);
    expect(find.text('Review your setup'), findsOneWidget);

    await tester.tap(find.text('Finish setup'));
    await tester.pumpAndSettle();
    expect(completed, 1);

    final profile = PlanningProfile.fromJson(
      (await LocalDocumentStore(db).read('planning-profile'))!.data,
    );
    expect(profile.onboarded, isTrue);
    expect(profile.startingWeight, isNull);
    expect(profile.dailyEnergyKcal, isNull);
  });

  testWidgets('finish fires only once even on rapid taps', (tester) async {
    final interceptor = _SlowWriteInterceptor();
    final db = AppDatabase(NativeDatabase.memory().interceptWith(interceptor));
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await store.save(const OnboardingDraft(step: OnboardingStep.review));
    interceptor.draftWriteCount = 0;
    var completed = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingWizard(
          store: store,
          onCompleted: () => completed++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final gate = Completer<void>();
    interceptor.writeGate = gate;

    await tester.tap(find.text('Finish setup'));
    await tester.pump();
    await tester.tap(find.text('Finish setup'), warnIfMissed: false);
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();

    expect(interceptor.draftWriteCount, 1);
    expect(completed, 1);
  });

  testWidgets(
      'skipped or failed AI setup never blocks onboarding and makes zero HTTP calls',
      (tester) async {
    final previousOverrides = HttpOverrides.current;
    final rejecting = _RejectingHttpOverrides();
    HttpOverrides.global = rejecting;
    addTearDown(() => HttpOverrides.global = previousOverrides);

    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await store.save(const OnboardingDraft(step: OnboardingStep.aiSetup));
    var openCalled = 0;
    var completed = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingWizard(
          store: store,
          onCompleted: () => completed++,
          openConnections: (_) async {
            openCalled++;
            throw StateError('Connection flow failed');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Step 6 of 7'), findsOneWidget);
    await tester.tap(find.text('Set up AI connection'));
    await tester.pumpAndSettle();

    expect(openCalled, 1);
    expect(find.text('Step 6 of 7'), findsOneWidget);
    expect(
      find.textContaining('You can skip this step or set it up later'),
      findsOneWidget,
    );

    await tester.tap(find.text('Skip this step'));
    await tester.pumpAndSettle();
    expect(find.text('Step 7 of 7'), findsOneWidget);

    await tester.tap(find.text('Finish setup'));
    await tester.pumpAndSettle();
    expect(completed, 1);
    expect(rejecting.requests, 0);
  });

  testWidgets(
      'targets page rejects invalid numbers and clears emptied targets to null',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await store.save(
      const OnboardingDraft(
        step: OnboardingStep.targets,
        profile: PlanningProfile(
          dailyEnergyKcal: 2200,
          proteinGrams: 130,
          carbohydrateGrams: 240,
          fatGrams: 70,
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(home: OnboardingWizard(store: store, onCompleted: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('Step 5 of 7'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Protein'),
      '-10',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 5 of 7'), findsOneWidget);
    expect(find.text('Enter a number greater than zero.'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        'Declared daily energy target (optional)',
      ),
      '',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Protein'),
      '',
    );
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    expect(find.text('Step 6 of 7'), findsOneWidget);
    final reloaded = await store.load();
    expect(reloaded.profile.dailyEnergyKcal, isNull);
    expect(reloaded.profile.proteinGrams, isNull);
    expect(reloaded.profile.carbohydrateGrams, 240);
    expect(reloaded.profile.fatGrams, 70);
  });

  testWidgets(
      'successful openConnections stays on AI step until user taps Next and uploads nothing',
      (tester) async {
    final previousOverrides = HttpOverrides.current;
    final rejecting = _RejectingHttpOverrides();
    HttpOverrides.global = rejecting;
    addTearDown(() => HttpOverrides.global = previousOverrides);

    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await store.save(const OnboardingDraft(step: OnboardingStep.aiSetup));
    var openCalled = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingWizard(
          store: store,
          onCompleted: () {},
          openConnections: (_) async {
            openCalled++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Set up AI connection'));
    await tester.pumpAndSettle();

    expect(openCalled, 1);
    expect(find.text('Step 6 of 7'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 7 of 7'), findsOneWidget);
    expect(rejecting.requests, 0);
  });

  testWidgets('Welcome Skip setup completes onboarding and live region is set',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final docs = LocalDocumentStore(db);
    final store = OnboardingStore(docs);
    var completed = 0;

    final semanticsHandle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingWizard(
            store: store,
            onCompleted: () => completed++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final stepFinder = find.text('Step 1 of 7');
      expect(stepFinder, findsOneWidget);
      final semanticsNode = tester.getSemantics(stepFinder);
      expect(semanticsNode.flagsCollection.isLiveRegion, isTrue);

      await tester.tap(find.text('Skip setup'));
      await tester.pumpAndSettle();

      expect(completed, 1);
      final saved = await docs.read('planning-profile');
      expect(saved, isNotNull);
      expect(saved!.data['onboarded'], isTrue);
    } finally {
      semanticsHandle.dispose();
    }
  });

  testWidgets('renders without overflow at 320px width and 200% text scale',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    await store.save(const OnboardingDraft(step: OnboardingStep.targets));

    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2.0),
          ),
          child: child!,
        ),
        home: OnboardingWizard(store: store, onCompleted: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Skip this step'), findsOneWidget);
  });

  testWidgets('disposing wizard during an in-flight write does not throw',
      (tester) async {
    final interceptor = _SlowWriteInterceptor();
    final db = AppDatabase(NativeDatabase.memory().interceptWith(interceptor));
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));

    await tester.pumpWidget(
      MaterialApp(home: OnboardingWizard(store: store, onCompleted: () {})),
    );
    await tester.pumpAndSettle();

    final gate = Completer<void>();
    interceptor.writeGate = gate;

    await tester.tap(find.text('Next'));
    await tester.pump();

    // Unmount OnboardingWizard while store.save() is still awaiting SQLite.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    gate.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
