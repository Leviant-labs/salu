import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/app.dart';
import 'package:salu/src/features/onboarding/onboarding_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu_data/salu_data.dart';

void main() {
  testWidgets('first-run questions have an overlay for navigation controls', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const SaluApp(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('What would you like to work towards?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unfinished display choices resume without changing committed settings', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalWorkspace(db).put(requestId:'partial', collection:'preferences',
      id:'onboarding-v2',expectedRevision:0,data:{'schemaVersion':2,'step':11,
        'answers':{'goal':'maintainWeight','wantNumbers':true}});
    Widget app() => ProviderScope(overrides:[databaseProvider.overrideWithValue(db)],
      child:const MaterialApp(home:OnboardingScreen()));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan without numbers'));
    await tester.pumpAndSettle();
    final settings = await LocalWorkspace(db).read('preferences','app');
    expect(settings?.data['hideCalorieNudges'], isNot(true));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Would you like starting calorie and macro estimates?'), findsOneWidget);
    expect(find.text('Build my plan'), findsOneWidget);
    final partial = await LocalWorkspace(db).read('preferences','onboarding-v2');
    expect((partial!.data['answers']! as Map)['wantNumbers'], isFalse);
    expect((partial.data['answers']! as Map)['hideCalorieNudges'], isTrue);
  });
}
