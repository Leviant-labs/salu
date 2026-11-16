import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/app.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/ui_support.dart';
import 'package:salu_data/salu_data.dart';

void main() {
  testWidgets('Portuguese navigation reaches rewards at large text on a narrow viewport', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalWorkspace(db).put(
      requestId: 'navigation:preferences',
      collection: 'preferences',
      id: 'app',
      expectedRevision: 0,
      data: {'language': 'pt', 'onboardingVersion': 1},
    );
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(ProviderScope(overrides: [
      databaseProvider.overrideWithValue(db),
      initialSettingsProvider.overrideWithValue({'language': 'pt', 'onboardingVersion': 1}),
    ], child: const SaluApp()));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    for (final destination in {
      'nav-today': 'Hoje',
      'nav-plan': 'O meu plano',
      'nav-assistant': 'Assistente',
      'nav-progress': 'Progresso',
    }.entries) {
      expect(tester.widget<NavigationDestination>(
          find.byKey(Key(destination.key))).label, destination.value);
    }
    await tester.tap(find.byTooltip('Adicionar alimento manualmente'));
    await tester.pumpAndSettle();
    expect(find.text('Adicionar alimento'), findsWidgets);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Perfil e definições'));
    await tester.pumpAndSettle();
    expect(find.text('Definições'), findsWidgets);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-progress')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Recompensas'), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Recompensas'));
    await tester.pumpAndSettle();
    expect(find.text('Como funcionam as recompensas'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
