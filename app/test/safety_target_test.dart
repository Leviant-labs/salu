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

Future<void> putProfile(LocalWorkspace w, SafetyProfile profile,
    {int revision = 0}) async {
  await w.put(
      requestId: 'profile-$revision',
      collection: 'profile',
      id: 'safety',
      expectedRevision: revision,
      data: profile.toJson());
}

void main() {
  testWidgets('restrictive declaration suspends existing target',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await putProfile(workspace, eligible);
    await workspace.put(
        requestId: 'initial-target',
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
    await harness.pump(tester, db, const SettingsScreen());
    await tester.tap(find.text('Safety declarations'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Symptoms or unexplained changes needing advice'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester
        .tap(find.text('Symptoms or unexplained changes needing advice'));
    await tester.scrollUntilVisible(find.text('Save declarations'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Save declarations'));
    await tester.pumpAndSettle();
    final profile = await workspace.read('profile', 'safety');
    final target = await workspace.read('target', 'current');
    expect(profile!.data['symptoms'], true);
    expect(target!.data['active'], false);
    expect(target.revision, 2);
  });

  testWidgets('changed safety declarations invalidate target confirmation',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await putProfile(workspace, eligible);
    await harness.pump(tester, db, const SettingsScreen());
    await tester.tap(find.text('Declared target'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Declared daily energy (kcal)'), '2000');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Save your declared target?'), findsOneWidget);
    await putProfile(workspace, const SafetyProfile(symptoms: true),
        revision: 1);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(await workspace.read('target', 'current'), isNull);
    expect(find.textContaining('SAFETY_DECLARATIONS_CHANGED'), findsOneWidget);
  });
  testWidgets('concurrent safety edit cannot be overwritten', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await putProfile(workspace, eligible);
    await harness.pump(tester, db, const SettingsScreen());
    await tester.tap(find.text('Safety declarations'));
    await tester.pumpAndSettle();
    await putProfile(workspace, const SafetyProfile(symptoms: true),
        revision: 1);
    await tester.scrollUntilVisible(find.text('Save declarations'), 300,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Save declarations'));
    await tester.pumpAndSettle();
    expect((await workspace.read('profile', 'safety'))!.data['symptoms'], true);
    expect(find.textContaining('SAFETY_DECLARATIONS_CHANGED'), findsOneWidget);
  });

  testWidgets('failed target suspension rolls back the safety update',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await putProfile(workspace, eligible);
    await workspace.put(
        requestId: 'initial-target',
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
    await db.customStatement(
        "CREATE TRIGGER test_abort_target BEFORE UPDATE ON user_documents WHEN OLD.collection = 'target' BEGIN SELECT RAISE(ABORT, 'test target failure'); END");
    await harness.pump(tester, db, const SettingsScreen());
    await tester.tap(find.text('Safety declarations'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Symptoms or unexplained changes needing advice'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester
        .tap(find.text('Symptoms or unexplained changes needing advice'));
    await tester.scrollUntilVisible(find.text('Save declarations'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Save declarations'));
    await tester.pumpAndSettle();
    expect(
        (await workspace.read('profile', 'safety'))!.data['symptoms'], false);
    expect((await workspace.read('target', 'current'))!.data['active'], true);
    expect(find.textContaining('test target failure'), findsOneWidget);
  });
  testWidgets('failed support preference rolls back safety declaration',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await putProfile(workspace, eligible);
    await db.customStatement(
        "CREATE TRIGGER test_abort_preferences BEFORE INSERT ON user_documents WHEN NEW.collection = 'preferences' BEGIN SELECT RAISE(ABORT, 'test preferences failure'); END");
    await harness.pump(tester, db, const SettingsScreen());
    await tester.tap(find.text('Safety declarations'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Eating-related concerns / request support'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.widgetWithText(DropdownButtonFormField<bool?>,
        'Eating-related concerns / request support'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yes').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Save declarations'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Save declarations'));
    await tester.pumpAndSettle();
    expect((await workspace.read('profile', 'safety'))!.data['eatingConcern'],
        false);
    expect(find.textContaining('test preferences failure'), findsOneWidget);
  });
}
