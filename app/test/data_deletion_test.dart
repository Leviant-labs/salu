import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/settings/settings_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as harness;

void main() {
  testWidgets('deletion invalidates cached favourite foods', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await DriftFoodRepository(db).replaceCatalogueBatch([
      Food(id: 'apple', name: 'Apple', per100g: NutrientProfile({}),
          source: const FoodSource(dataset: 'custom', datasetId: 'apple'))
    ]);
    await harness.pump(tester, db, const SettingsScreen());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsScreen)));
    await container.read(foodLibraryProvider).setFavorite(
        SetFavoriteFoodCommand(requestId: 'fav', foodId: 'apple', favorite: true));
    expect(await container.read(favoriteFoodsProvider.future), hasLength(1));
    await tester.scrollUntilVisible(find.text('Delete local data'), 300, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete local data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(await container.read(favoriteFoodsProvider.future), isEmpty);
  });
}
