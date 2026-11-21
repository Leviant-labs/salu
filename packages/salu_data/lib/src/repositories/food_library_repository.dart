import 'package:salu_core/salu_core.dart';

import '../codec/recipe_codec.dart';
import 'local_document_store.dart';

/// A user-saved reusable food with bounded nutrition.
typedef SavedFood = ({
  String id,
  String name,
  String? barcode,
  BoundedNutrition nutrition,
});

/// A user-saved reusable meal template.
typedef SavedMeal = ({
  String id,
  String name,
  List<PhotoMealItem> items,
});

/// Pure-Dart persistence adapter for user-saved foods, meals, and favorites.
final class FoodLibraryRepository {
  const FoodLibraryRepository(this.documents, {this.runWrite});

  final LocalDocumentStore documents;
  final Future<T> Function<T>(Future<T> Function() work)? runWrite;

  static const _key = 'food-library';
  static const int currentVersion = 1;

  Future<T> _write<T>(Future<T> Function() work) =>
      runWrite != null ? runWrite!(work) : work();

  Future<List<SavedFood>> foods() async =>
      (await _loadValidated())?.foods ?? const [];

  Future<List<SavedMeal>> meals() async =>
      (await _loadValidated())?.meals ?? const [];

  Future<Set<String>> favorites() async =>
      (await _loadValidated())?.favorites ?? const <String>{};

  Future<void> toggleFavorite(String id) => _update((json) {
        final ids = _decodeFavorites(json['favorites']).toSet();
        if (!ids.remove(id)) ids.add(id);
        return {...json, 'favorites': ids.toList()};
      });

  Future<void> saveFood(SavedFood food) => _update((json) {
        final existingRows = _rawList(json['foods'], 'foods');
        final rows =
            existingRows.where((row) => (row as Map)['id'] != food.id).toList();
        if (food.barcode != null &&
            rows.any((row) => (row as Map)['barcode'] == food.barcode)) {
          throw StateError('Barcode is already saved');
        }
        return {
          ...json,
          'foods': [
            ...rows,
            {
              'id': food.id,
              'name': food.name,
              'barcode': food.barcode,
              'amount': food.nutrition.basis.amount,
              'unit': food.nutrition.basis.unit.name,
              'nutrients': food.nutrition.nutrients.toJson(),
            },
          ],
        };
      });

  Future<void> saveMeal(SavedMeal meal) => _update((json) => {
        ...json,
        'meals': [
          ..._rawList(json['meals'], 'meals')
              .where((row) => (row as Map)['id'] != meal.id),
          {
            'id': meal.id,
            'name': meal.name,
            'items': [
              for (final item in meal.items) encodePhotoMealItem(item),
            ],
          },
        ],
      });

  Future<
      ({
        int revision,
        Map<String, dynamic> data,
        List<SavedFood> foods,
        List<SavedMeal> meals,
        Set<String> favorites,
      })?> _loadValidated() async {
    final record = await documents.read(_key);
    if (record == null) return null;
    final parsed = _parseDocument(record.data);
    if (!isCurrentDocumentVersion(
      record.data,
      currentVersion,
      documentName: _key,
    )) {
      final migrated = <String, Object?>{
        ...record.data,
        'version': currentVersion,
      };
      if (await _write(() => documents.put(_key, record.revision, migrated))) {
        return (
          revision: record.revision + 1,
          data: Map<String, dynamic>.from(migrated),
          foods: parsed.foods,
          meals: parsed.meals,
          favorites: parsed.favorites,
        );
      }
      final latest = await documents.read(_key);
      if (latest == null) return null;
      final latestParsed = _parseDocument(latest.data);
      return (
        revision: latest.revision,
        data: latest.data,
        foods: latestParsed.foods,
        meals: latestParsed.meals,
        favorites: latestParsed.favorites,
      );
    }
    return (
      revision: record.revision,
      data: record.data,
      foods: parsed.foods,
      meals: parsed.meals,
      favorites: parsed.favorites,
    );
  }

  ({
    List<SavedFood> foods,
    List<SavedMeal> meals,
    Set<String> favorites,
  }) _parseDocument(Map<String, dynamic> data) {
    isCurrentDocumentVersion(data, currentVersion, documentName: _key);
    final foods = [
      for (final raw in _rawList(data['foods'], 'foods')) _decodeFood(raw),
    ];
    final meals = [
      for (final raw in _rawList(data['meals'], 'meals')) _decodeMeal(raw),
    ];
    final favorites = _decodeFavorites(data['favorites']);
    return (foods: foods, meals: meals, favorites: favorites);
  }

  static List<Object?> _rawList(Object? raw, String field) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw FormatException('Expected list for $field in $_key', raw);
    }
    return raw;
  }

  static Set<String> _decodeFavorites(Object? raw) {
    if (raw == null) return const <String>{};
    if (raw is! List) {
      throw FormatException('Expected list for favorites in $_key', raw);
    }
    return {
      for (final item in raw)
        if (item is String)
          item
        else
          throw FormatException('Expected string favorite id in $_key', item),
    };
  }

  static SavedFood _decodeFood(Object? raw) {
    if (raw is! Map) {
      throw FormatException('Invalid saved food entry in $_key', raw);
    }
    final map = Map<String, dynamic>.from(raw);
    final id = map['id'];
    if (id is! String || id.trim().isEmpty) {
      throw FormatException('Invalid saved food id', id);
    }
    final name = map['name'];
    if (name is! String || name.trim().isEmpty) {
      throw FormatException('Invalid saved food name', name);
    }
    final barcode = map['barcode'];
    if (barcode != null && barcode is! String) {
      throw FormatException('Invalid saved food barcode', barcode);
    }
    final amount = map['amount'];
    if (amount is! num || !amount.isFinite || amount <= 0) {
      throw FormatException('Invalid saved food amount', amount);
    }
    final rawUnit = map['unit'];
    if (rawUnit is! String) {
      throw FormatException('Invalid saved food unit', rawUnit);
    }
    MealUnit? unit;
    for (final value in MealUnit.values) {
      if (value.name == rawUnit) {
        unit = value;
        break;
      }
    }
    if (unit == null) {
      throw FormatException('Unknown saved food unit: $rawUnit', rawUnit);
    }
    final nutrients = decodeNutrientProfile(map['nutrients']);
    return (
      id: id,
      name: name,
      barcode: barcode as String?,
      nutrition: BoundedNutrition(
        MealPortion(amount.toDouble(), unit),
        nutrients,
      ),
    );
  }

  static SavedMeal _decodeMeal(Object? raw) {
    if (raw is! Map) {
      throw FormatException('Invalid saved meal entry in $_key', raw);
    }
    final map = Map<String, dynamic>.from(raw);
    final id = map['id'];
    if (id is! String || id.trim().isEmpty) {
      throw FormatException('Invalid saved meal id', id);
    }
    final name = map['name'];
    if (name is! String || name.trim().isEmpty) {
      throw FormatException('Invalid saved meal name', name);
    }
    final rawItems = map['items'];
    if (rawItems is! List) {
      throw FormatException('Invalid saved meal items', rawItems);
    }
    return (
      id: id,
      name: name,
      items: [
        for (final item in rawItems) decodePhotoMealItem(item),
      ],
    );
  }

  Future<void> _update(
    Map<String, Object?> Function(Map<String, dynamic>) change,
  ) async {
    final old = await _loadValidated();
    final base = old?.data ?? const <String, dynamic>{};
    if (!await _write(() => documents.put(_key, old?.revision ?? 0, {
          ...base,
          ...change(base),
          'version': currentVersion,
        }))) {
      throw StateError('Food library changed');
    }
  }
}
