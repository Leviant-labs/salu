import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/settings/settings_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as harness;

void main() {
  testWidgets('target supports explicit macros and clinician ownership',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await harness.pump(t, db, const SettingsScreen());
    await t.tap(find.text('Declared target'));
    await t.pumpAndSettle();
    await t.enterText(
        find.widgetWithText(TextField, 'Declared daily energy (kcal)'), '2000');
    await t.enterText(find.widgetWithText(TextField, 'Protein (g)'), '90,5');
    await t.enterText(find.widgetWithText(TextField, 'Fat (g)'), '70');
    await t.enterText(
        find.widgetWithText(TextField, 'Carbohydrate (g)'), '200');
    await t.tap(find.text('My target'));
    await t.pumpAndSettle();
    await t.tap(find.text('Clinician-provided').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    await t.tap(find.text('Confirm'));
    await t.pumpAndSettle();
    final row = (await LocalWorkspace(db).read('target', 'current'))!;
    final target = DeclaredTarget.fromJson(row.data);
    expect(target.origin, TargetOrigin.clinicianProvided);
    expect(target.proteinG, Exact.parse('90.5'));
    expect(target.fatG, Exact.parse('70'));
    expect(target.carbohydrateG, Exact.parse('200'));
    expect(target.active, isFalse);
  });
  testWidgets('target rejects conflicting macros before confirmation',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await harness.pump(t, db, const SettingsScreen());
    await t.tap(find.text('Declared target'));
    await t.pumpAndSettle();
    await t.enterText(
        find.widgetWithText(TextField, 'Declared daily energy (kcal)'), '100');
    await t.enterText(find.widgetWithText(TextField, 'Protein (g)'), '100');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(find.textContaining('Macro energy exceeds'), findsOneWidget);
    expect(await LocalWorkspace(db).read('target', 'current'), isNull);
  });
  testWidgets('editing retains exact existing macros and source', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final workspace = LocalWorkspace(db);
    final fraction = Exact.one / Exact.parse('3');
    await workspace.put(
        requestId: 'first',
        collection: 'target',
        id: 'current',
        expectedRevision: 0,
        data: DeclaredTarget(
                id: 'current',
                revision: 1,
                origin: TargetOrigin.clinicianProvided,
                effectiveDate: '2026-01-01',
                policyVersion: 'clinician-provided-v1',
                energyKcal: Exact.parse('2000'),
                proteinG: fraction)
            .toJson());
    await harness.pump(t, db, const SettingsScreen());
    await t.tap(find.text('Declared target'));
    await t.pumpAndSettle();
    await t.enterText(
        find.widgetWithText(TextField, 'Declared daily energy (kcal)'), '2100');
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    await t.tap(find.text('Confirm'));
    await t.pumpAndSettle();
    final target = DeclaredTarget.fromJson(
        (await workspace.read('target', 'current'))!.data);
    expect(target.origin, TargetOrigin.clinicianProvided);
    expect(target.proteinG, fraction);
    expect(target.revision, 2);
  });
}
