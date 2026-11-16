import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/today/today_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu_data/salu_data.dart';

void main() {
  testWidgets('empty guided home leads to a plan at narrow width and large text', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(overrides:[databaseProvider.overrideWithValue(db)],
      child:MaterialApp(builder:(context,child) => MediaQuery(
        data:MediaQuery.of(context).copyWith(textScaler:const TextScaler.linear(2)),
        child:child!),home:const Scaffold(body:TodayScreen()))));
    await tester.pumpAndSettle();
    expect(find.text('Create my plan'), findsOneWidget);
    expect(find.text('Search the Food tab or add your own food.'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
