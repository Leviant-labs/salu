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
  testWidgets('safety choices remain separated at large text on a narrow screen',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await harness.pump(tester, db, const SettingsScreen(), pt: true, scale: 2);
    await tester.scrollUntilVisible(find.text('Declarações de segurança'), 200,
        scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(
        tester.element(find.text('Declarações de segurança')), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Declarações de segurança'));
    await tester.pumpAndSettle();
    final adult = find.widgetWithText(DropdownButtonFormField<bool?>, 'Pessoa adulta');
    final pregnant = find.widgetWithText(DropdownButtonFormField<bool?>, 'Grávida');
    expect(tester.getRect(adult).bottom, lessThan(tester.getRect(pregnant).top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('declarations persist atomically without target suspension',
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
    expect(target!.data['active'], true);
    expect(target.revision, 1);
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

  testWidgets('eating concern does not enable supportive mode automatically',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    await putProfile(workspace, eligible);
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
        true);
    expect(await workspace.read('preferences', 'app'), isNull);
  });
}
