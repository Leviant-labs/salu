import 'dart:convert';

import 'package:salu_core/salu_core.dart';

import '../repositories/drift_food_repository.dart';

/// Import boundary for separately distributed, licensed, normalized datasets.
/// v1 declares per-100-g quantities only; unsupported bases are rejected rather
/// than reinterpreted. Photos and credentials are never accepted by this codec.
final class CataloguePack {
  CataloguePack._(this.dataset, this.edition, this.attribution, this.licence,
      this.foods, this.barcodes);
  final String dataset, edition, attribution, licence;
  final List<Food> foods;
  final Map<String, String> barcodes;

  static const maxBytes = 16 * 1024 * 1024;

  factory CataloguePack.parse(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Catalogue pack is empty or too large');
    }
    final root = jsonDecode(utf8.decode(bytes));
    if (root is! Map<String, dynamic> || root['format'] != 1) {
      throw const FormatException('Unsupported catalogue pack format');
    }
    final dataset = _text(root['dataset']);
    final edition = _text(root['edition']);
    final attribution = _text(root['attribution'], max: 500);
    final licence = _text(root['licence']);
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,60}$').hasMatch(dataset) ||
        dataset == 'usda-fdc-sr-legacy' ||
        dataset == 'dev-fixture') {
      throw const FormatException('Invalid or reserved catalogue source');
    }
    final rows = root['foods'];
    if (rows is! List || rows.isEmpty || rows.length > 25000) {
      throw const FormatException('Unsupported number of foods');
    }
    final byId = <String, Food>{};
    final barcodes = <String, String>{};
    for (final row in rows) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Invalid food');
      }
      final sourceId = _text(row['sourceId']);
      final id = '$dataset:$sourceId';
      if (byId.containsKey(id)) {
        throw const FormatException('Duplicate food ID');
      }
      final nutrients = row['per100g'];
      if (nutrients is! Map<String, dynamic>) {
        throw const FormatException('Food needs a per-100-g profile');
      }
      final values = <NutrientKey, NutrientValue>{};
      for (final item in nutrients.entries) {
        final key = NutrientKey.fromWire(item.key);
        final amount = item.value;
        if (key == null ||
            (amount != null &&
                (amount is! num || !amount.isFinite || amount < 0))) {
          throw const FormatException('Invalid nutrient or amount');
        }
        if (amount is num) values[key] = NutrientReported(amount.toDouble());
      }
      if (row['barcode'] case final Object raw?) {
        final barcode = _text(raw);
        if (!RegExp(r'^\d{8,14}$').hasMatch(barcode) ||
            barcodes.containsKey(barcode)) {
          throw const FormatException('Invalid or duplicate barcode');
        }
        barcodes[barcode] = id;
      }
      final prep = Preparation.values
          .where((value) => value.name == row['preparation'])
          .firstOrNull;
      if (row['preparation'] != null && prep == null) {
        throw const FormatException('Invalid preparation state');
      }
      byId[id] = Food(
          id: id,
          name: _text(row['name'], max: 180),
          source: FoodSource(
              dataset: dataset,
              datasetId: sourceId,
              datasetVersion: edition,
              licence: licence),
          preparation: prep ?? Preparation.unspecified,
          per100g: NutrientProfile(values));
    }
    return CataloguePack._(dataset, edition, attribution, licence,
        List.unmodifiable(byId.values), Map.unmodifiable(barcodes));
  }

  Future<void> install(DriftFoodRepository repository) =>
      repository.installEdition(dataset, edition, foods,
          barcodes: barcodes, attribution: attribution, licence: licence);

  static String _text(Object? raw, {int max = 100}) {
    if (raw is! String ||
        raw.trim().isEmpty ||
        raw.length > max ||
        raw.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('Invalid text in catalogue pack');
    }
    return raw.trim();
  }
}
