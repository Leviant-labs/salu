import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/plan/grocery_labels.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import 'plan_test_support.dart';

void main() {
  testWidgets('starter shopping labels and cooked rice note are localized', (tester) async {
    Future<void> show(Locale locale) async {
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('pt')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: Builder(builder: (context) => ListView(children: [
          for (final id in ['395', '1', '680', '403', '402'])
            Text(groceryShoppingName(context, 'insa-bdca:$id', 'source')),
          Text(groceryShoppingName(context, 'custom:395', 'My olive oil')),
          Text(groceryPreparationNote(context, 'insa-bdca:403')!),
        ]))),
      ));
    }
    await show(const Locale('en'));
    expect(find.text('Olive oil'), findsOneWidget);
    expect(find.text('Drinking water'), findsOneWidget);
    expect(find.text('Pears'), findsOneWidget);
    expect(find.text('Ready-cooked plain rice'), findsOneWidget);
    expect(find.text('Long-grain rice (dry)'), findsOneWidget);
    expect(find.text('My olive oil'), findsOneWidget);
    expect(find.textContaining('No dry weight is estimated'), findsOneWidget);
    await show(const Locale('pt'));
    expect(find.text('Azeite'), findsOneWidget);
    expect(find.text('Água potável'), findsOneWidget);
    expect(find.text('Peras'), findsOneWidget);
    expect(find.text('Arroz branco já cozido'), findsOneWidget);
    expect(find.textContaining('Não é estimado o peso em cru'), findsOneWidget);
  });

  test('fold retains exact quantities, identity, and explicit name overrides', () {
    final recipe = planRecipe(servings: '1', ingredients: [
      RecipeIngredient(planFood('rice', name: 'Source cooked rice',
          preparation: Preparation.cooked), Exact.parse('250')),
    ]);
    final meals = [PlannedMeal(const MealSlot('lunch:0', '2026-01-01', 'lunch'), recipe, Exact.one)];
    final key = GroceryService.groceryKey('custom:rice', Preparation.cooked);
    final list = GroceryService.foldForPlan(
      planDocumentId: 'week:2026-01-01', meals: meals,
      planDocument: {'guided': {'householdServings': 2}},
      overlay: {key: {'name': 'My rice', 'checked': true}},
    );
    final entry = list.visible.single.entry;
    expect(entry.key, key);
    expect(entry.grams, Exact.parse('500'));
    expect(entry.name, 'My rice');
    expect(entry.hasNameOverride, isTrue);
    expect(entry.checked, isTrue);
    expect(recipe.ingredients.single.food.name, 'Source cooked rice');
    final plain = GroceryService.fold(planDocumentId: 'current', meals: meals,
        overlay: {key: {'name': '  '}}).visible.single.entry;
    expect(plain.hasNameOverride, isFalse);
    expect(plain.grams, Exact.parse('250'));
  });
}
