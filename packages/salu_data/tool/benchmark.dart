import 'dart:convert';
import 'dart:io';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

/// Host-only smoke profiling. Never substitutes for named-device release budgets.
Future<void> main() async {
  final db = AppDatabase.memory();
  final repo = DriftFoodRepository(db);
  try {
    final catalogue = List.generate(
        10000,
        (i) => Food(
            id: 'synthetic-$i',
            name: 'Synthetic search food $i',
            per100g: const NutrientProfile.empty(),
            source: const FoodSource(
                dataset: 'benchmark-synthetic-no-nutrition',
                datasetId: 'fixture')));
    final install = Stopwatch()..start();
    await repo.replaceCatalogueBatch(catalogue);
    install.stop();
    final timings = <int>[];
    for (var i = 0; i < 100; i++) {
      final watch = Stopwatch()..start();
      await repo.search('food ${i % 20}');
      watch.stop();
      timings.add(watch.elapsedMicroseconds);
    }
    timings.sort();
    final recipe = RecipeVersion(
        id: 'r',
        revision: 1,
        name: 'Synthetic recipe',
        ingredients: [RecipeIngredient(catalogue.first, Exact.parse('100'))],
        servings: Exact.one,
        minutes: 10);
    final plannerTimings = <int>[];
    final context = PlannerContext(
        slots: List.generate(7, (i) => MealSlot('s$i', 'day$i', 'Dinner')),
        recipes: [recipe],
        seed: 7);
    for (var i = 0; i < 100; i++) {
      final watch = Stopwatch()..start();
      const PlannerService().plan(context);
      watch.stop();
      plannerTimings.add(watch.elapsedMicroseconds);
    }
    plannerTimings.sort();
    print(const JsonEncoder.withIndent('  ').convert({
      'scope': 'Linux host only; no device performance claim',
      'runtime': Platform.version,
      'os': Platform.operatingSystem,
      'catalogueRows': 10000,
      'catalogueInstallMs': install.elapsedMilliseconds,
      'searchWarmMicroseconds': {'p50': timings[49], 'p95': timings[94]},
      'plannerWarmMicroseconds': {
        'p50': plannerTimings[49],
        'p95': plannerTimings[94]
      },
      'conditions':
          'in-memory SQLite, synthetic names, unknown nutrients, single dinner recipe, 100 iterations',
      'deviceGates':
          'cold start, disk DB footprint, peak RAM, camera/image tokens, correction effort and named Android/iOS devices remain pending'
    }));
  } finally {
    await db.close();
  }
}
