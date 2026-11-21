import 'dart:convert';

import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

/// Quotes a CSV text cell and neutralizes spreadsheet formula injection.
///
/// Always wraps in double quotes `"..."`, doubles internal `"` to `""`, and
/// prefixes a single quote `'` when the first non-whitespace character
/// (ignoring ASCII control characters and spaces `<= 0x20`) is `=`, `+`, `-`,
/// or `@`.
String csvCell(String value) {
  final neutralized = _needsFormulaPrefix(value) ? "'$value" : value;
  final escaped = neutralized.replaceAll('"', '""');
  return '"$escaped"';
}

bool _needsFormulaPrefix(String value) {
  for (var i = 0; i < value.length; i++) {
    final code = value.codeUnitAt(i);
    if (code <= 0x20) continue;
    return code == 0x3D /* = */ ||
        code == 0x2B /* + */ ||
        code == 0x2D /* - */ ||
        code == 0x40 /* @ */;
  }
  return false;
}

/// Formats a numeric value for a CSV numeric column without formula prefixing.
///
/// Returns an empty string when [value] is `null` or non-finite so unknown
/// values are never coerced to `0`.
String _csvNumber(num? value) {
  if (value == null) return '';
  final d = value.toDouble();
  if (!d.isFinite) return '';
  if (d == d.truncateToDouble()) {
    return d.truncate().toString();
  }
  return d.toString();
}

String _nutrientState(NutrientValue value) => switch (value) {
      NutrientMeasured() => 'measured',
      NutrientEstimated() => 'estimated',
      NutrientReported() => 'reported',
      NutrientTrace() => 'trace',
      NutrientUnknown() => 'unknown',
    };

String _mealUnitLabel(MealUnit unit) => switch (unit) {
      MealUnit.grams => 'g',
      MealUnit.millilitres => 'ml',
      MealUnit.servings => 'serving',
      MealUnit.pieces => 'piece',
    };

/// Exports all diary records from [snapshot] (both `photo_meals` and legacy
/// `log_entries` + `log_entry_items`) to RFC 4180 CSV with formula-injection
/// neutralization on all text columns.
///
/// Columns:
/// `date,meal_id,slot,food_name,portion_amount,portion_unit,nutrient_key,value,state,provenance`
String exportDiaryCsv(UserDataSnapshot snapshot) {
  final buffer = StringBuffer()
    ..writeln(
      'date,meal_id,slot,food_name,portion_amount,portion_unit,nutrient_key,value,state,provenance',
    );

  // 1. Photo meals
  for (final meal in snapshot.meals) {
    final date = (meal['diaryDate'] as String?) ?? '';
    final mealId = (meal['id'] as String?) ?? '';
    final slot = (meal['slot'] as String?) ?? '';
    final itemsJson = meal['itemsJson'];
    if (itemsJson is! String || itemsJson.isEmpty) continue;
    final decoded = jsonDecode(itemsJson);
    if (decoded is! List) continue;

    for (var i = 0; i < decoded.length; i++) {
      final item = decodePhotoMealItem(
        decoded[i],
        fallbackId: '$mealId:$i',
        strict: false,
      );
      final portionAmount = item.portion?.amount;
      final portionUnit =
          item.portion != null ? _mealUnitLabel(item.portion!.unit) : '';
      final provenance = item.source ?? '';

      for (final entry in item.nutrients.values.entries) {
        final key = entry.key;
        final val = entry.value;
        final state = _nutrientState(val);
        final numCell = val is NutrientUnknown || val is NutrientTrace
            ? ''
            : _csvNumber(val.numericValue);
        buffer.writeln([
          csvCell(date),
          csvCell(mealId),
          csvCell(slot),
          csvCell(item.name),
          _csvNumber(portionAmount),
          csvCell(portionUnit),
          csvCell(key.wire),
          numCell,
          csvCell(state),
          csvCell(provenance),
        ].join(','));
      }
    }
  }

  // 2. Legacy log_entries + log_entry_items
  final entriesById = <String, Map<String, Object?>>{
    for (final entry in snapshot.entries)
      if (entry['id'] is String) entry['id']! as String: entry,
  };

  for (final itemRow in snapshot.entryItems) {
    final entryId = (itemRow['entryId'] as String?) ?? '';
    final entry = entriesById[entryId];
    final date = (entry?['diaryDate'] as String?) ?? '';
    final channel = (entry?['channel'] as String?) ?? '';
    final foodName = (itemRow['name'] as String?) ?? '';
    final grams = itemRow['grams'] is num ? (itemRow['grams']! as num) : null;
    final nutrientsRaw = itemRow['nutrientsJson'];
    if (nutrientsRaw is! String || nutrientsRaw.isEmpty) continue;
    final decoded = jsonDecode(nutrientsRaw);
    if (decoded is! Map) continue;
    final profile = NutrientProfile.fromJson(decoded.cast<String, Object?>());

    for (final nutrientEntry in profile.values.entries) {
      final key = nutrientEntry.key;
      final val = nutrientEntry.value;
      final state = _nutrientState(val);
      final numCell = val is NutrientUnknown || val is NutrientTrace
          ? ''
          : _csvNumber(val.numericValue);
      buffer.writeln([
        csvCell(date),
        csvCell(entryId),
        csvCell(''),
        csvCell(foodName),
        _csvNumber(grams),
        csvCell('g'),
        csvCell(key.wire),
        numCell,
        csvCell(state),
        csvCell(channel),
      ].join(','));
    }
  }

  return buffer.toString();
}
