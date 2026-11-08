import 'package:salu_core/salu_core.dart';

/// Catalogue fake that only serves the foods it was given.
final class FakeFoodRepository implements FoodRepository {
  FakeFoodRepository([Iterable<Food> foods = const <Food>[]]) {
    for (final food in foods) {
      _foods[food.id] = food;
    }
  }

  final Map<String, Food> _foods = <String, Food>{};

  @override
  Future<Food?> findById(String id) async => _foods[id];

  @override
  Future<List<Food>> search(String query, {int limit = 20}) async {
    final needle = query.toLowerCase();
    return _foods.values
        .where((food) => food.name.toLowerCase().contains(needle))
        .take(limit)
        .toList(growable: false);
  }
}

/// Diary fake that records appends in call order.
final class FakeEntryRepository implements EntryRepository {
  /// Entries appended so far.
  final List<LoggedEntry> written = <LoggedEntry>[];

  @override
  Future<LoggedEntry?> findByRequestId(String requestId) async {
    for (final entry in written) {
      if (entry.requestId == requestId) return entry;
    }
    return null;
  }

  @override
  Future<void> append(LoggedEntry entry) async => written.add(entry);

  @override
  Future<List<LoggedEntry>> entriesFor(DiaryDate date) async =>
      written.where((entry) => entry.diaryDate == date).toList(growable: false);
}

/// Clock pinned to one instant.
final class FixedClock implements Clock {
  FixedClock(this.instant);

  /// The instant this clock always returns.
  final DateTime instant;

  @override
  DateTime nowUtc() => instant.toUtc();
}

/// A chicken breast per 100 g, with a declared 120 g piece weight.
Food chickenBreast() => Food(
      id: 'food-chicken',
      name: 'Chicken breast, cooked',
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(165),
        NutrientKey.proteinG: NutrientMeasured(31),
        NutrientKey.fatG: NutrientMeasured(3.6),
        NutrientKey.carbohydrateG: NutrientMeasured(0),
        NutrientKey.fiberG: const NutrientUnknown(),
      }),
      source: const FoodSource(
        dataset: 'test',
        datasetId: 'chicken-1',
        datasetVersion: 'fixture',
      ),
      portions: const PortionDefinition(portionGrams: 120),
      quality: DataQuality.curated,
      allergens: const <String>{},
    );

/// A milk-like food that declares a density and no piece weight.
Food milk() => Food(
      id: 'food-milk',
      name: 'Milk, semi-skimmed',
      per100g: NutrientProfile({
        NutrientKey.energyKcal: NutrientMeasured(46),
        NutrientKey.proteinG: NutrientMeasured(3.4),
        NutrientKey.carbohydrateG: NutrientMeasured(4.8),
      }),
      source: const FoodSource(dataset: 'test', datasetId: 'milk-1'),
      portions: const PortionDefinition(densityGramsPerMillilitre: 1.03),
    );
