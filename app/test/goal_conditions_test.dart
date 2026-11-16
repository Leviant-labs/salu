import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/settings/settings_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as harness;

const eligible = SafetyProfile(
    adult: true,
    pregnant: false,
    breastfeeding: false,
    clinicalNeed: false,
    eatingConcern: false,
    relevantMedication: false);

Future<void> putProfile(LocalWorkspace w, SafetyProfile profile) => w.put(
    requestId: 'safety-profile',
    collection: 'profile',
    id: 'safety',
    expectedRevision: 0,
    data: profile.toJson());

Future<void> putTarget(LocalWorkspace w) => w.put(
    requestId: 'declared-target',
    collection: 'target',
    id: 'current',
    expectedRevision: 0,
    data: DeclaredTarget(
            id: 'current',
            revision: 1,
            origin: TargetOrigin.userDeclared,
            effectiveDate: '2026-01-01',
            policyVersion: 'user-declared-v1',
            energyKcal: Exact.parse('2000'))
        .toJson());

Future<void> putPreferences(LocalWorkspace w) => w.put(
    requestId: 'app-preferences',
    collection: 'preferences',
    id: 'app',
    expectedRevision: 0,
    data: const <String, Object?>{
      'language': 'en',
      'support': false,
      'onboarded': true,
      'rewardCosmetic': 'everyday'
    });

final Finder goalDropdown = find.widgetWithText(
    DropdownButtonFormField<AdultGoal>, 'Your goal');
Finder conditionDropdown(String label) =>
    find.widgetWithText(DropdownButtonFormField<bool?>, label);

/// Scrolls the long declarations form until [label] is reachable, then picks
/// [option]. New-format builds place all conditions after explanatory copy, so
/// tests must not assume a dropdown starts on screen.
Future<void> setCondition(
    WidgetTester tester, String label, String option) async {
  final dropdown = conditionDropdown(label);
  await tester.scrollUntilVisible(dropdown, 250,
      scrollable: find.byType(Scrollable).last);
  await tester.ensureVisible(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

/// Brings the form's save button fully into the viewport before tapping.
/// `scrollUntilVisible` stops once the widget is built, which can still leave
/// it below the visible area, so `ensureVisible` is required before the tap.
Future<void> tapSaveDeclarations(WidgetTester tester,
    {String label = 'Save declarations'}) async {
  final save = find.text(label);
  await tester.scrollUntilVisible(save, 250,
      scrollable: find.byType(Scrollable).last);
  await tester.ensureVisible(save);
  await tester.pumpAndSettle();
  await tester.tap(save);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('goal edits update the guided profile and declaration together',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = NutritionProfileStore(db);
    await store.save(
        requestId: 'guided-profile',
        expectedRevision: 0,
        profile: NutritionProfile(
            goal: AdultGoal.notDeclared, householdServings: 2));
    await harness.pump(tester, db, const SettingsScreen());
    await tester.tap(find.text('Goal and health declarations'));
    await tester.pumpAndSettle();
    await tester.tap(goalDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maintain weight').last);
    await tester.pumpAndSettle();
    await tapSaveDeclarations(tester);
    final profile = NutritionProfile.fromJson((await store.read())!.data);
    final declaration =
        await LocalWorkspace(db).read('health-declaration', 'current');
    expect(profile.goal, AdultGoal.maintainWeight);
    expect(profile.householdServings, 2);
    expect(declaration!.data['goal'], 'maintainWeight');
  });

  test('condition wire names stay stable and null means unknown', () {
    const declaration = AdultHealthDeclaration(
        declaredConditions: {DeclaredCondition.foodAllergy},
        absentConditions: {DeclaredCondition.coeliacDisease});
    final json = declaration.toJson();
    expect(json['guidancePolicy'], AdultHealthDeclaration.guidancePolicy);
    final conditions = json['conditions']! as Map<String, Object?>;
    expect(conditions.keys.toSet(),
        {for (final condition in DeclaredCondition.values) condition.name});
    expect(
        conditions.keys,
        containsAll([
          'highTriglycerides',
          'diabetes',
          'highCholesterol',
          'lowBloodGlucoseHistoryOrRisk',
          'highBloodPressure',
          'chronicKidneyDisease',
          'eatingDisorderConcerns',
          'lactoseIntolerance',
          'gout',
          'irritableBowelSyndrome',
          'foodAllergy',
          'coeliacDisease',
        ]));
    expect(conditions['foodAllergy'], isTrue);
    expect(conditions['coeliacDisease'], isFalse);
    expect(conditions['highBloodPressure'], isNull);

    final parsed = AdultHealthDeclaration.fromJson({
      ...json,
      'conditions': {...conditions, 'futureCondition': true},
    });
    expect(parsed.conditionStatus(DeclaredCondition.foodAllergy), isTrue);
    expect(parsed.conditionStatus(DeclaredCondition.coeliacDisease), isFalse);
    expect(parsed.conditionStatus(DeclaredCondition.highBloodPressure), isNull);
    expect(parsed.conditionStatus(DeclaredCondition.gout), isNull);
  });

  testWidgets(
      'new condition declarations persist without creating allergen exclusions',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    const safety = SafetyProfile(
        adult: true,
        pregnant: false,
        breastfeeding: false,
        clinicalNeed: false,
        eatingConcern: false,
        relevantMedication: false,
        strictExclusions: {'milk'});
    await putProfile(workspace, safety);
    final safetyBefore = (await workspace.read('profile', 'safety'))!;

    await harness.pump(tester, db, const SettingsScreen());
    await tester.tap(find.text('Goal and health declarations'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This record alone excludes nothing'),
        findsNothing);

    final scrollable = find.byType(Scrollable).last;
    await setCondition(tester, 'High blood pressure', 'Yes, I declare this');
    await setCondition(tester, 'Chronic kidney disease', 'No');
    await setCondition(tester, 'Food allergy', 'Yes, I declare this');
    await setCondition(tester, 'Coeliac disease', 'Yes, I declare this');
    await tester.scrollUntilVisible(
        find.textContaining('This record alone excludes nothing'), 250,
        scrollable: scrollable);
    expect(find.textContaining('This record alone excludes nothing'),
        findsOneWidget);

    await tapSaveDeclarations(tester);

    final saved = (await workspace.read('health-declaration', 'current'))!;
    final conditions = saved.data['conditions']! as Map<String, Object?>;
    expect(conditions['highBloodPressure'], isTrue);
    expect(conditions['chronicKidneyDisease'], isFalse);
    expect(conditions['foodAllergy'], isTrue);
    expect(conditions['coeliacDisease'], isTrue);
    expect(conditions['eatingDisorderConcerns'], isNull);
    expect(conditions['gout'], isNull);
    expect(conditions['irritableBowelSyndrome'], isNull);
    expect(conditions['lactoseIntolerance'], isNull);

    // The declarations never create, widen or guess strict exclusions.
    final safetyAfter = (await workspace.read('profile', 'safety'))!;
    expect(safetyAfter.revision, safetyBefore.revision);
    expect(safetyAfter.data, safetyBefore.data);
    expect(safetyAfter.data['strictExclusions'], ['milk']);

    expect(find.textContaining('declared: High blood pressure'),
        findsOneWidget);
    expect(find.textContaining('do not enforce exclusions'), findsOneWidget);
  });

  testWidgets(
      'goal and condition choices persist without touching safety, target or preferences',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await putProfile(workspace, eligible);
    await putPreferences(workspace);
    await putTarget(workspace);
    final safetyBefore = (await workspace.read('profile', 'safety'))!;
    final preferencesBefore = (await workspace.read('preferences', 'app'))!;
    final decisionBefore = const EligibilityService().evaluate(eligible);

    await harness.pump(tester, db, const SettingsScreen());
    expect(find.textContaining('goal not declared'), findsOneWidget);
    expect(find.textContaining('no declared conditions'), findsOneWidget);

    await tester.tap(find.text('Goal and health declarations'));
    await tester.pumpAndSettle();

    expect(tester.widget<DropdownButtonFormField<AdultGoal>>(goalDropdown)
        .initialValue, AdultGoal.notDeclared);

    await tester.tap(goalDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maintain weight').last);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(conditionDropdown('Diabetes'), 250,
        scrollable: find.byType(Scrollable).last);
    expect(
        tester
            .widget<DropdownButtonFormField<bool?>>(conditionDropdown('Diabetes'))
            .initialValue,
        isNull);

    await setCondition(tester, 'Diabetes', 'Yes, I declare this');
    await setCondition(tester, 'High cholesterol', 'No');
    await setCondition(
        tester, 'History or risk of low blood glucose', 'No');

    await tapSaveDeclarations(tester);

    final saved = (await workspace.read('health-declaration', 'current'))!;
    expect(saved.revision, 1);
    expect(saved.data['schemaVersion'], 1);
    expect(saved.data['goal'], 'maintainWeight');
    expect(saved.data['guidancePolicy'],
        AdultHealthDeclaration.guidancePolicy);
    final conditions = saved.data['conditions']! as Map<String, Object?>;
    expect(conditions['diabetes'], isTrue);
    expect(conditions['highCholesterol'], isFalse);
    expect(conditions['lowBloodGlucoseHistoryOrRisk'], isFalse);
    expect(conditions['highTriglycerides'], isNull);

    final declaration = AdultHealthDeclaration.fromJson(saved.data);
    expect(declaration.goal, AdultGoal.maintainWeight);
    expect(declaration.conditionStatus(DeclaredCondition.diabetes), isTrue);
    expect(
        declaration.conditionStatus(DeclaredCondition.highCholesterol), isFalse);
    expect(
        declaration.conditionStatus(
            DeclaredCondition.lowBloodGlucoseHistoryOrRisk),
        isFalse);
    expect(declaration.conditionStatus(DeclaredCondition.highTriglycerides),
        isNull);
    // The experimental condition-aware planning test is present in this build,
    // but it is not clinical approval and never guarantees a condition rule.
    expect(declaration.conditionGuidanceEnabled, isTrue);

    // Unrelated saved profile data, preferences and target stay byte-identical.
    final safetyAfter = (await workspace.read('profile', 'safety'))!;
    expect(safetyAfter.revision, safetyBefore.revision);
    expect(safetyAfter.data, safetyBefore.data);
    final preferencesAfter = (await workspace.read('preferences', 'app'))!;
    expect(preferencesAfter.revision, preferencesBefore.revision);
    expect(preferencesAfter.data, preferencesBefore.data);
    final target = (await workspace.read('target', 'current'))!;
    expect(target.revision, 1);
    expect(target.data['active'], true);

    // Declaring diabetes does not change eligibility.
    final decisionAfter = const EligibilityService()
        .evaluate(SafetyProfile.fromJson(safetyAfter.data));
    expect(decisionAfter.reasonCodes, decisionBefore.reasonCodes);
    expect(decisionAfter.recordingAllowed, isTrue);

    // The summary reads the stored declarations without asserting a diagnosis.
    expect(find.textContaining('goal: Maintain weight'), findsOneWidget);
    expect(find.textContaining('declared: Diabetes'), findsOneWidget);
  });

  testWidgets('future declaration values survive an unrelated condition edit',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await workspace.put(
        requestId: 'future-declaration',
        collection: 'health-declaration',
        id: 'current',
        expectedRevision: 0,
        data: {
          'schemaVersion': 1,
          'goal': 'futureGoalName',
          'conditions': {
            'highTriglycerides': true,
            'diabetes': 'futureStatus',
            'futureCondition': {'note': 'keep'},
          },
          'futureTopLevel': ['keep'],
          'guidancePolicy': AdultHealthDeclaration.guidancePolicy,
        });
    await harness.pump(tester, db, const SettingsScreen());
    // Unknown values read as not declared, not "no" and not a guess.
    expect(find.textContaining('goal not declared'), findsOneWidget);

    await tester.tap(find.text('Goal and health declarations'));
    await tester.pumpAndSettle();
    await setCondition(tester, 'High cholesterol', 'Yes, I declare this');
    await tapSaveDeclarations(tester);

    final saved = (await workspace.read('health-declaration', 'current'))!;
    expect(saved.revision, 2);
    expect(saved.data['goal'], 'futureGoalName');
    expect(saved.data['futureTopLevel'], ['keep']);
    final conditions = saved.data['conditions']! as Map<String, Object?>;
    expect(conditions['highTriglycerides'], isTrue);
    expect(conditions['highCholesterol'], isTrue);
    expect(conditions['diabetes'], 'futureStatus');
    expect(conditions['futureCondition'], {'note': 'keep'});
  });

  testWidgets('concurrent declaration edit cannot be overwritten',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await workspace.put(
        requestId: 'initial-declaration',
        collection: 'health-declaration',
        id: 'current',
        expectedRevision: 0,
        data: const AdultHealthDeclaration(goal: AdultGoal.maintainWeight)
            .toJson());
    await harness.pump(tester, db, const SettingsScreen());
    await tester.tap(find.text('Goal and health declarations'));
    await tester.pumpAndSettle();

    await workspace.put(
        requestId: 'external-declaration',
        collection: 'health-declaration',
        id: 'current',
        expectedRevision: 1,
        data: const AdultHealthDeclaration(goal: AdultGoal.gainWeight)
            .toJson());

    await setCondition(tester, 'Diabetes', 'Yes, I declare this');
    await tapSaveDeclarations(tester);

    final saved = (await workspace.read('health-declaration', 'current'))!;
    expect(saved.revision, 2);
    expect(AdultHealthDeclaration.fromJson(saved.data).goal,
        AdultGoal.gainWeight);
    expect(
        AdultHealthDeclaration.fromJson(saved.data)
            .conditionStatus(DeclaredCondition.diabetes),
        isNull);
    expect(find.textContaining('GOAL_DECLARATIONS_CHANGED'), findsOneWidget);
  });

  testWidgets('pt-PT copy keeps declarations separate from advice',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await harness.pump(tester, db, const SettingsScreen(), pt: true);
    await tester.tap(find.text('Meta e declarações de saúde'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Não são um diagnóstico'), findsOneWidget);
    expect(find.textContaining('Não é clinicamente validado'), findsOneWidget);

    await tester.tap(find.widgetWithText(
        DropdownButtonFormField<AdultGoal>, 'A tua meta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Perder peso').last);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
        find.widgetWithText(
            DropdownButtonFormField<bool?>, 'Triglicéridos elevados'),
        250,
        scrollable: find.byType(Scrollable).last);
    expect(
        tester
            .widget<DropdownButtonFormField<bool?>>(find.widgetWithText(
                DropdownButtonFormField<bool?>, 'Triglicéridos elevados'))
            .initialValue,
        isNull);

    await setCondition(tester, 'Triglicéridos elevados', 'Sim, declaro');
    // The full condition list stays reachable in a scrolling form.
    await tester.scrollUntilVisible(
        find.widgetWithText(DropdownButtonFormField<bool?>, 'Doença celíaca'),
        250,
        scrollable: find.byType(Scrollable).last);
    expect(
        tester
            .widget<DropdownButtonFormField<bool?>>(find.widgetWithText(
                DropdownButtonFormField<bool?>, 'Doença celíaca'))
            .initialValue,
        isNull);
    await tapSaveDeclarations(tester, label: 'Guardar declarações');

    final saved = (await LocalWorkspace(db)
        .read('health-declaration', 'current'))!;
    expect(saved.data['goal'], 'loseWeight');
    expect((saved.data['conditions']! as Map<String, Object?>)
        ['highTriglycerides'], isTrue);
  });
}
