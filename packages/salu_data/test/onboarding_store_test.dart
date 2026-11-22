import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('draft resumes without marking setup complete', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = OnboardingStore(documents);
    final draft = OnboardingDraft(
      step: OnboardingStep.preferences,
      profile: const PlanningProfile(startingWeight: 75.5),
    );
    expect(await store.save(draft), isTrue);
    final resumed = await OnboardingStore(documents).load();
    expect(resumed.step, OnboardingStep.preferences);
    expect(resumed.profile.startingWeight, 75.5);
    expect(resumed.revision, 1);
    expect(await documents.read('planning-profile'), isNull);
    expect(await store.complete(resumed), isTrue);
    expect(await documents.read('onboarding-draft'), isNull);
    expect(
      (await documents.read('planning-profile'))!.data['onboarded'],
      isTrue,
    );
  });

  test('load returns default welcome draft at revision 0 when absent',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));
    final draft = await store.load();
    expect(draft.step, OnboardingStep.welcome);
    expect(draft.revision, 0);
    expect(draft.profile.startingWeight, isNull);
    expect(draft.profile.onboarded, isFalse);
  });

  test('save rejects stale draft revision without overwriting newer draft',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));

    final first = OnboardingDraft(
      step: OnboardingStep.goals,
      profile: const PlanningProfile(energyGoal: 'Maintain weight'),
    );
    expect(await store.save(first), isTrue);
    final loaded = await store.load();
    expect(loaded.revision, 1);

    final second = loaded.copyWith(
      step: OnboardingStep.startingPoint,
      profile: const PlanningProfile(
        energyGoal: 'Maintain weight',
        startingWeight: 72,
      ),
    );
    expect(await store.save(second), isTrue);

    // Stale revision 1 write must be rejected.
    expect(
      await store.save(
        loaded.copyWith(
          step: OnboardingStep.review,
          profile: const PlanningProfile(energyGoal: 'Stale overwrite'),
        ),
      ),
      isFalse,
    );

    final current = await store.load();
    expect(current.revision, 2);
    expect(current.step, OnboardingStep.startingPoint);
    expect(current.profile.startingWeight, 72);
    expect(current.profile.energyGoal, 'Maintain weight');
  });

  test('load rejects unknown or future draft versions with FormatException',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    await documents.put('onboarding-draft', 0, {
      'version': 2,
      'step': OnboardingStep.welcome.name,
      'profile': const PlanningProfile().toJson(),
    });

    final store = OnboardingStore(documents);
    await expectLater(store.load(), throwsFormatException);
  });

  test('save and complete reject non-positive or non-finite numeric fields',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = OnboardingStore(LocalDocumentStore(db));

    final invalidProfiles = <PlanningProfile>[
      const PlanningProfile(startingWeight: 0),
      const PlanningProfile(startingWeight: -5),
      const PlanningProfile(startingWeight: double.nan),
      const PlanningProfile(startingWeight: double.infinity),
      const PlanningProfile(dailyEnergyKcal: 0),
      const PlanningProfile(dailyEnergyKcal: -100),
      const PlanningProfile(dailyEnergyKcal: double.negativeInfinity),
      const PlanningProfile(proteinGrams: 0),
      const PlanningProfile(carbohydrateGrams: -1),
      const PlanningProfile(fatGrams: double.nan),
    ];

    for (final invalid in invalidProfiles) {
      final draft = OnboardingDraft(
        step: OnboardingStep.targets,
        profile: invalid,
      );
      await expectLater(store.save(draft), throwsArgumentError);
      await expectLater(store.complete(draft), throwsArgumentError);
    }
  });

  test('complete rejects stale draft revision and leaves state unchanged',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = OnboardingStore(documents);

    expect(
      await store.save(
        const OnboardingDraft(
          step: OnboardingStep.startingPoint,
          profile: PlanningProfile(startingWeight: 70),
        ),
      ),
      isTrue,
    );
    final stale = await store.load();

    expect(
      await store.save(
        stale.copyWith(
          step: OnboardingStep.review,
          profile: const PlanningProfile(startingWeight: 71),
        ),
      ),
      isTrue,
    );

    expect(await store.complete(stale), isFalse);
    expect(await documents.read('planning-profile'), isNull);
    final remaining = await store.load();
    expect(remaining.revision, 2);
    expect(remaining.profile.startingWeight, 71);
  });

  test('complete rolls back profile write if draft removal fails', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = OnboardingStore(documents);

    expect(
      await store.save(
        const OnboardingDraft(
          step: OnboardingStep.review,
          profile: PlanningProfile(startingWeight: 68.5),
        ),
      ),
      isTrue,
    );
    final draft = await store.load();

    await db.customStatement('''
      CREATE TRIGGER fail_draft_delete
      BEFORE DELETE ON local_documents
      WHEN OLD.id = 'onboarding-draft'
      BEGIN
        SELECT RAISE(ABORT, 'simulated delete failure');
      END;
    ''');

    await expectLater(store.complete(draft), throwsException);
    expect(await documents.read('planning-profile'), isNull);
    expect((await documents.read('onboarding-draft'))?.revision, 1);
  });

  test('complete rolls back profile write if profile write fails', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = OnboardingStore(documents);

    expect(
      await store.save(
        const OnboardingDraft(
          step: OnboardingStep.review,
          profile: PlanningProfile(startingWeight: 80),
        ),
      ),
      isTrue,
    );
    final draft = await store.load();

    await db.customStatement('''
      CREATE TRIGGER fail_profile_insert
      BEFORE INSERT ON local_documents
      WHEN NEW.id = 'planning-profile'
      BEGIN
        SELECT RAISE(ABORT, 'simulated profile conflict');
      END;
    ''');

    await expectLater(store.complete(draft), throwsException);
    expect(await documents.read('planning-profile'), isNull);
    expect((await documents.read('onboarding-draft'))?.revision, 1);
  });

  test('PlanningProfile.fromJson rejects non-positive and non-finite values',
      () {
    expect(
      () => PlanningProfile.fromJson({'startingWeight': 0}),
      throwsArgumentError,
    );
    expect(
      () => PlanningProfile.fromJson({'dailyEnergyKcal': -10}),
      throwsArgumentError,
    );
    expect(
      () => PlanningProfile.fromJson({'proteinGrams': double.nan}),
      throwsArgumentError,
    );
    expect(
      () => PlanningProfile.fromJson({'fatGrams': double.infinity}),
      throwsArgumentError,
    );
  });

  test('complete updates existing committed planning-profile atomically',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    const existing = PlanningProfile(
      preferences: FoodPreferences(dislikes: 'Mushrooms'),
      onboarded: false,
    );
    expect(
      await documents.put('planning-profile', 0, existing.toJson()),
      isTrue,
    );

    final store = OnboardingStore(documents);
    expect(
      await store.save(
        const OnboardingDraft(
          step: OnboardingStep.review,
          profile: PlanningProfile(
            startingWeight: 74,
            weightUnit: WeightUnit.kilograms,
            preferences: FoodPreferences(
              likes: 'Stews',
              dislikes: 'Mushrooms',
            ),
          ),
        ),
      ),
      isTrue,
    );
    final draft = await store.load();
    expect(await store.complete(draft), isTrue);
    expect(await documents.read('onboarding-draft'), isNull);

    final committed = await documents.read('planning-profile');
    expect(committed, isNotNull);
    expect(committed!.revision, 2);
    final profile = PlanningProfile.fromJson(committed.data);
    expect(profile.onboarded, isTrue);
    expect(profile.startingWeight, 74);
    expect(profile.preferences.likes, 'Stews');
    expect(profile.preferences.dislikes, 'Mushrooms');
  });

  test(
      'skip preserves existing committed profile without committing unfinished draft',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    const existing = PlanningProfile(
      startingWeight: 66.5,
      weightUnit: WeightUnit.pounds,
      energyGoal: 'Steady energy',
      dailyEnergyKcal: 2100,
      preferences: FoodPreferences(
        likes: 'Oats',
        strictAllergens: 'Peanut',
      ),
      onboarded: false,
    );
    expect(
      await documents.put('planning-profile', 0, existing.toJson()),
      isTrue,
    );

    final store = OnboardingStore(documents);
    expect(
      await store.save(
        const OnboardingDraft(
          step: OnboardingStep.targets,
          profile: PlanningProfile(
            startingWeight: 99,
            energyGoal: 'Unfinished draft goal',
            preferences: FoodPreferences(likes: 'Cake'),
          ),
        ),
      ),
      isTrue,
    );

    await store.skip();
    expect(await documents.read('onboarding-draft'), isNull);

    final record = await documents.read('planning-profile');
    expect(record, isNotNull);
    expect(record!.revision, 2);
    final profile = PlanningProfile.fromJson(record.data);
    expect(profile.onboarded, isTrue);
    expect(profile.startingWeight, 66.5);
    expect(profile.weightUnit, WeightUnit.pounds);
    expect(profile.energyGoal, 'Steady energy');
    expect(profile.dailyEnergyKcal, 2100);
    expect(profile.preferences.likes, 'Oats');
    expect(profile.preferences.strictAllergens, 'Peanut');
  });

  test(
      'skip with no committed profile marks onboarded without committing draft',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    final store = OnboardingStore(documents);

    expect(
      await store.save(
        const OnboardingDraft(
          step: OnboardingStep.startingPoint,
          profile: PlanningProfile(startingWeight: 85),
        ),
      ),
      isTrue,
    );

    await store.skip();
    expect(await documents.read('onboarding-draft'), isNull);
    final record = await documents.read('planning-profile');
    expect(record, isNotNull);
    final profile = PlanningProfile.fromJson(record!.data);
    expect(profile.onboarded, isTrue);
    expect(profile.startingWeight, isNull);
  });

  test('already-onboarded fixture remains onboarded on skip and clears draft',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final documents = LocalDocumentStore(db);
    const alreadyOnboarded = PlanningProfile(
      startingWeight: 70,
      dailyEnergyKcal: 2000,
      onboarded: true,
    );
    expect(
      await documents.put('planning-profile', 0, alreadyOnboarded.toJson()),
      isTrue,
    );
    await documents.put('onboarding-draft', 0, {
      'version': 1,
      'step': OnboardingStep.welcome.name,
      'profile': const PlanningProfile(startingWeight: 120).toJson(),
    });

    await OnboardingStore(documents).skip();
    expect(await documents.read('onboarding-draft'), isNull);
    final record = await documents.read('planning-profile');
    expect(record, isNotNull);
    final profile = PlanningProfile.fromJson(record!.data);
    expect(profile.onboarded, isTrue);
    expect(profile.startingWeight, 70);
    expect(profile.dailyEnergyKcal, 2000);
  });

  test('draft JSON format carries version 1 and excludes external revision',
      () {
    const draft = OnboardingDraft(
      step: OnboardingStep.aiSetup,
      profile: PlanningProfile(
        startingWeight: 75.5,
        weightUnit: WeightUnit.kilograms,
      ),
      revision: 4,
    );
    final json = draft.toJson();
    expect(json['version'], 1);
    expect(json['step'], 'aiSetup');
    expect(json.containsKey('revision'), isFalse);
    expect(json.containsKey('apiKey'), isFalse);
    expect(json.containsKey('token'), isFalse);

    final roundTripped = OnboardingDraft.fromJson(json, revision: 4);
    expect(roundTripped.step, OnboardingStep.aiSetup);
    expect(roundTripped.revision, 4);
    expect(roundTripped.profile.startingWeight, 75.5);
  });
}
