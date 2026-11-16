import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/settings/settings_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/ui_support.dart';
import 'package:salu_data/salu_data.dart';

Future<void> pumpSettings(WidgetTester tester, AppDatabase db,
    Map<String, Object?> settings,
    {bool pt = false}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        initialSettingsProvider.overrideWithValue(settings)
      ],
      child: MaterialApp(
          locale: pt ? const Locale('pt', 'PT') : const Locale('en'),
          supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const Scaffold(body: SettingsScreen()))));
  await tester.pumpAndSettle();
}

Future<void> seedPreferences(
    AppDatabase db, Map<String, Object?> data) async {
  await LocalWorkspace(db).put(
      requestId: 'seed-preferences',
      collection: 'preferences',
      id: 'app',
      expectedRevision: 0,
      data: data);
}

bool switchValue(WidgetTester tester, String title) => tester
    .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
    .value;

void main() {
  testWidgets('nudge switches persist independently and preserve other keys',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final initial = <String, Object?>{
      'language': 'en',
      'support': false,
      'onboarded': true,
      'rewardCosmetic': 'everyday',
    };
    await seedPreferences(db, initial);
    await pumpSettings(tester, db, initial);

    expect(switchValue(tester, 'Hide calorie nudges'), isFalse);
    expect(switchValue(tester, 'Hide weight nudges'), isFalse);
    expect(switchValue(tester, 'Hide fasting nudges'), isFalse);
    expect(find.textContaining('No fasting notifications exist today'),
        findsOneWidget);

    await tester.tap(find.text('Hide calorie nudges'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide fasting nudges'));
    await tester.pumpAndSettle();

    expect(switchValue(tester, 'Hide calorie nudges'), isTrue);
    expect(switchValue(tester, 'Hide weight nudges'), isFalse);
    expect(switchValue(tester, 'Hide fasting nudges'), isTrue);

    final saved = await LocalWorkspace(db).read('preferences', 'app');
    expect(saved!.data['hideCalorieNudges'], isTrue);
    expect(saved.data['hideFastingNudges'], isTrue);
    expect(saved.data['hideWeightNudges'], isNot(true));
    expect(saved.data['rewardCosmetic'], 'everyday');
    expect(saved.data['language'], 'en');
    expect(saved.data['support'], false);
    expect(saved.data['onboarded'], true);

    // A fresh app start seeded from the stored document retains the choices.
    await tester.pumpWidget(const SizedBox());
    await pumpSettings(tester, db, saved.data);
    expect(switchValue(tester, 'Hide calorie nudges'), isTrue);
    expect(switchValue(tester, 'Hide weight nudges'), isFalse);
    expect(switchValue(tester, 'Hide fasting nudges'), isTrue);
  });

  testWidgets('supportive mode overrides without clearing nudge choices',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final initial = <String, Object?>{
      'language': 'en',
      'support': false,
      'hideCalorieNudges': true,
      'hideWeightNudges': false,
      'hideFastingNudges': true,
    };
    await seedPreferences(db, initial);
    await pumpSettings(tester, db, initial);

    expect(switchValue(tester, 'Supportive mode'), isFalse);
    expect(switchValue(tester, 'Hide calorie nudges'), isTrue);
    expect(switchValue(tester, 'Hide weight nudges'), isFalse);
    expect(switchValue(tester, 'Hide fasting nudges'), isTrue);
    expect(
        find.textContaining(
            'Supportive mode hides all three regardless of these choices'),
        findsOneWidget);

    await tester.tap(find.text('Supportive mode'));
    await tester.pumpAndSettle();
    expect(switchValue(tester, 'Supportive mode'), isTrue);
    expect(switchValue(tester, 'Hide calorie nudges'), isTrue);
    expect(switchValue(tester, 'Hide weight nudges'), isFalse);
    expect(switchValue(tester, 'Hide fasting nudges'), isTrue);

    var saved = await LocalWorkspace(db).read('preferences', 'app');
    expect(saved!.data['support'], true);
    expect(saved.data['hideCalorieNudges'], isTrue);
    expect(saved.data['hideWeightNudges'], false);
    expect(saved.data['hideFastingNudges'], isTrue);

    // A choice made while supportive mode is on is retained independently.
    await tester.tap(find.text('Hide weight nudges'));
    await tester.pumpAndSettle();
    expect(switchValue(tester, 'Supportive mode'), isTrue);
    expect(switchValue(tester, 'Hide weight nudges'), isTrue);

    saved = await LocalWorkspace(db).read('preferences', 'app');
    expect(saved!.data['support'], true);
    expect(saved.data['hideWeightNudges'], true);

    await tester.tap(find.text('Supportive mode'));
    await tester.pumpAndSettle();
    expect(switchValue(tester, 'Supportive mode'), isFalse);
    expect(switchValue(tester, 'Hide calorie nudges'), isTrue);
    expect(switchValue(tester, 'Hide weight nudges'), isTrue);
    expect(switchValue(tester, 'Hide fasting nudges'), isTrue);

    saved = await LocalWorkspace(db).read('preferences', 'app');
    expect(saved!.data['support'], false);
    expect(saved.data['hideCalorieNudges'], isTrue);
    expect(saved.data['hideWeightNudges'], true);
    expect(saved.data['hideFastingNudges'], isTrue);
  });

  testWidgets('master switch leaves individual nudge keys untouched',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final initial = <String, Object?>{
      'language': 'en',
      'support': false,
      'onboarded': true,
    };
    await seedPreferences(db, initial);
    await pumpSettings(tester, db, initial);

    await tester.tap(find.text('Supportive mode'));
    await tester.pumpAndSettle();
    var saved = await LocalWorkspace(db).read('preferences', 'app');
    expect(saved!.data['support'], true);
    expect(saved.data.containsKey('hideCalorieNudges'), isFalse);
    expect(saved.data.containsKey('hideWeightNudges'), isFalse);
    expect(saved.data.containsKey('hideFastingNudges'), isFalse);

    await tester.tap(find.text('Supportive mode'));
    await tester.pumpAndSettle();
    saved = await LocalWorkspace(db).read('preferences', 'app');
    expect(saved!.data['support'], false);
    expect(saved.data.containsKey('hideCalorieNudges'), isFalse);
    expect(saved.data.containsKey('hideWeightNudges'), isFalse);
    expect(saved.data.containsKey('hideFastingNudges'), isFalse);
  });

  testWidgets('pt-PT labels state nudge scope without promising messages',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final initial = <String, Object?>{'language': 'pt', 'support': false};
    await seedPreferences(db, initial);
    await pumpSettings(tester, db, initial, pt: true);

    expect(find.text('Ocultar lembretes de calorias'), findsOneWidget);
    expect(find.text('Ocultar lembretes de peso'), findsOneWidget);
    expect(find.text('Ocultar lembretes de jejum'), findsOneWidget);
    expect(find.textContaining('Ainda não existem notificações de jejum'),
        findsOneWidget);
    expect(find.textContaining('não agenda nem envia notificações'),
        findsOneWidget);

    await tester.tap(find.text('Ocultar lembretes de calorias'));
    await tester.pumpAndSettle();
    expect(switchValue(tester, 'Ocultar lembretes de calorias'), isTrue);

    final saved = await LocalWorkspace(db).read('preferences', 'app');
    expect(saved!.data['hideCalorieNudges'], true);
    expect(saved.data['language'], 'pt');
  });
}
