import 'dart:convert';

import 'package:salu_core/salu_core.dart';

import 'source_import.dart';

/// Normalizes Open Food Facts product JSON (API v2 or v3 envelopes).
///
/// Source facts used by this adapter:
/// * `nutriments` values suffixed `_100g` are amounts per 100 g in the original
///   unit declared by `<nutrient>_unit`; they are not normalized grams. `_serving`
///   values are documented as per-serving normalized amounts; mass nutrients are
///   normalized to grams there. `_value` is the entered amount and is not used
///   because its basis depends on `nutrition_data_per`.
/// * OFF stores non-energy nutrient amounts in grams by default, but the
///   `_unit` field is authoritative for `_100g`. Values are converted exactly
///   to the app's declared nutrient unit; no density is assumed.
/// * `energy-kj` and `energy-kcal` are distinct supplied quantities. A generic
///   `energy` value is used only when its `energy_unit` names kcal or kJ and no
///   specific value for that unit exists.
/// * `salt` is not converted to sodium: the sodium value is used only when OFF
///   supplies it directly. `added-sugars`, `polyols` and other nutrients without
///   a reviewed app identity remain unmapped.
/// * `nutriments_estimated` is OFF's own derived estimate, not a label value.
///   It is retained as a source-detail flag but is not imported without a
///   reviewed rule for its unit and provenance.
/// * `allergens_tags` are user-contributed and are not a verified complete
///   allergen declaration. Raw tags are retained in source details, but
///   [Food.allergens] stays `null` because the planner treats a non-null set as
///   complete and would otherwise certify an incomplete OFF record.
/// * `carbohydrates` has no single EU/US definition in OFF. The caller may pass
///   a reviewed definition; otherwise the observation is retained as
///   [sourceDefinedCarbohydrate] and the legacy profile keeps it unknown.
///
/// Dataset version and licence are supplied by the caller; this adapter never
/// asserts an ODbL review, database-content review or product image review.
final class OpenFoodFactsFoodAdapter {
  OpenFoodFactsFoodAdapter({
    required String datasetVersion,
    required String licence,
    String? carbohydrateDefinition,
  })  : datasetVersion = datasetVersion.trim(),
        licence = licence.trim(),
        carbohydrateDefinition =
            _validatedCarbohydrateDefinition(carbohydrateDefinition) {
    if (this.datasetVersion.isEmpty) {
      throw ArgumentError('Open Food Facts dataset version is required');
    }
    if (this.licence.isEmpty) {
      throw ArgumentError('Open Food Facts licence identifier is required');
    }
  }

  /// Dataset name used in [FoodSource.dataset] and local food identifiers.
  static const String dataset = 'open-food-facts';

  /// Definition retained when the caller has not chosen an EU/US reading.
  static const String sourceDefinedCarbohydrate =
      'open-food-facts:carbohydrates';

  final String datasetVersion, licence;

  /// Reviewed carbohydrate definition, or `null` to keep the source reading.
  final String? carbohydrateDefinition;

  static String? _validatedCarbohydrateDefinition(String? value) {
    if (value == null) return null;
    if (value != NutrientDefinitions.euAvailableCarbohydrate &&
        value != NutrientDefinitions.usTotalCarbohydrate) {
      throw ArgumentError(
          'Only EU available or US total carbohydrate definitions are '
          'supported for Open Food Facts imports');
    }
    return value;
  }

  /// Normalizes one decoded Open Food Facts product.
  FoodImportResult adapt(Map<String, Object?> record) {
    final nested = _map(record['product']);
    final product = nested.isEmpty ? record : nested;
    final sourceId = _text(product['code']) ?? _text(record['code']);
    if (sourceId == null) {
      throw const FormatException('Open Food Facts record has no code');
    }
    final name =
        _text(product['product_name']) ?? _text(product['generic_name']);
    if (name == null) {
      throw FormatException(
          'Open Food Facts record $sourceId has no product name');
    }

    final builder = ImportedFoodBuilder(
        dataset: dataset,
        datasetVersion: datasetVersion,
        licence: licence);

    builder.detail('nutrition_data_per',
        _text(product['nutrition_data_per']));
    builder.detail('nutrition_data_prepared_per',
        _text(product['nutrition_data_prepared_per']));
    builder.detail('serving_size', _text(product['serving_size']));
    builder.detail('serving_quantity', product['serving_quantity']);
    builder.detail('serving_quantity_unit',
        _text(product['serving_quantity_unit']));
    builder.detail('product_quantity', product['product_quantity']);
    builder.detail('product_quantity_unit',
        _text(product['product_quantity_unit']));
    builder.detail('categories', _tagSuffixes(product['categories_tags']));
    builder.detail('labels', _tagSuffixes(product['labels_tags']));
    builder.detail('countries', _tagSuffixes(product['countries_tags']));
    builder.detail('traces', _tagSuffixes(product['traces_tags']));
    builder.detail('ingredients_analysis',
        _tagSuffixes(product['ingredients_analysis_tags']));
    builder.detail('nova_group', product['nova_group']);
    builder.detail('nutriscore_grade', _text(product['nutriscore_grade']));
    builder.detail('ingredients_text', _text(product['ingredients_text']));
    if (_map(product['nutriments_estimated']).isNotEmpty) {
      builder.detail('hasEstimatedNutrients', true);
    }
    _recordAllergenTags(product, builder);

    final declaredBasis = _text(product['nutrition_data_per']);
    if (declaredBasis != null &&
        declaredBasis != '100g' &&
        declaredBasis != 'serving') {
      builder.issue('unexpected-nutrition-basis',
          'Expected nutrition_data_per to be "100g" or "serving"',
          field: 'nutrition_data_per');
    }

    final nutriments = _map(product['nutriments']);
    var suffix = _basisSuffix(nutriments);
    var basisUnit = FoodUnit.g;
    var observationBasis = FoodAmount('100', FoodUnit.g);

    if (suffix == null) {
      builder.issue('no-nutrition-data', 'Record supplies no nutriments');
    } else if (suffix == '_serving') {
      final quantity = parseSourceAmount(product['serving_quantity']);
      final rawUnit = _text(product['serving_quantity_unit']);
      final unit = rawUnit == null ? null : canonicalFoodUnit(rawUnit);
      if (quantity == null || !quantity.positive || unit == null) {
        builder.issue(
            'missing-serving-basis',
            '_serving values need a serving_quantity in grams or millilitres',
            field: 'serving_quantity');
        suffix = null;
      } else {
        observationBasis = FoodAmount.exact(quantity, unit);
        basisUnit = unit == FoodUnit.ml ? FoodUnit.ml : FoodUnit.g;
      }
    }

    if (suffix != null) {
      for (final entry in _offSpecs.entries) {
        _addNutrient(
            nutriments: nutriments,
            id: entry.key,
            spec: entry.value,
            suffix: suffix,
            basis: observationBasis,
            sourceId: sourceId,
            builder: builder);
      }
      _addNutrient(
          nutriments: nutriments,
          id: 'energy-kj',
          spec: const _OffSpec(NutrientKey.energyKj,
              fixedUnit: 'kJ',
              definition: NutrientDefinitions.declaredEnergy),
          suffix: suffix,
          basis: observationBasis,
          sourceId: sourceId,
          builder: builder);
      _addNutrient(
          nutriments: nutriments,
          id: 'energy-kcal',
          spec: const _OffSpec(NutrientKey.energyKcal,
              fixedUnit: 'kcal',
              definition: NutrientDefinitions.declaredEnergy),
          suffix: suffix,
          basis: observationBasis,
          sourceId: sourceId,
          builder: builder);
      _addGenericEnergy(
          nutriments: nutriments,
          suffix: suffix,
          basis: observationBasis,
          sourceId: sourceId,
          builder: builder);
      _collectUnmapped(nutriments, builder);
    }

    if (suffix != null && !builder.hasObservations) {
      builder.issue('no-mapped-nutrients',
          'No supplied nutrient has a reviewed mapping');
    }

    final servingQuantity = parseSourceAmount(product['serving_quantity']);
    final servingUnit =
        canonicalFoodUnit(_text(product['serving_quantity_unit']) ?? '');
    final portionGrams = servingUnit == FoodUnit.g &&
            servingQuantity != null &&
            servingQuantity.positive
        ? servingQuantity.toDouble()
        : null;

    final barcodes = <String>[];
    try {
      barcodes.add(ProductBarcode(sourceId).value);
    } on FormatException {
      builder.issue('invalid-barcode',
          'Product code is not a valid GTIN-8/12/13/14 code',
          field: 'code');
    }

    return builder.build(
        id: '$dataset:$sourceId',
        name: name,
        sourceId: sourceId,
        basisUnit: basisUnit,
        basisValue: '100',
        allergens: null,
        dietaryTags: _dietaryTags(product),
        aliases: _aliases(product, name),
        barcodes: barcodes,
        regions: _tagSuffixes(product['countries_tags']) ?? const <String>[],
        portionGrams: portionGrams);
  }

  /// Normalizes JSON exactly as returned by the OFF product endpoint.
  FoodImportResult adaptJson(String text) {
    final Object? decoded = jsonDecode(text);
    final record = _map(decoded);
    if (record.isEmpty) {
      throw const FormatException('Open Food Facts record must be an object');
    }
    return adapt(record);
  }

  void _addNutrient({
    required Map<String, Object?> nutriments,
    required String id,
    required _OffSpec spec,
    required String suffix,
    required FoodAmount basis,
    required String sourceId,
    required ImportedFoodBuilder builder,
  }) {
    final field = '$id$suffix';
    if (!nutriments.containsKey(field)) return;
    final amount = parseSourceAmount(nutriments[field]);
    final rawUnit = _text(nutriments['${id}_unit']);
    String? unit;
    final expected = spec.fixedUnit;
    if (expected != null) {
      if (rawUnit != null) {
        final declared = canonicalNutrientUnit(rawUnit);
        if (declared == null) {
          if (amount != null) {
            builder.issue('unsupported-unit',
                'Unsupported energy unit "$rawUnit"',
                field: '${id}_unit');
            builder.unmapped(id);
            return;
          }
        } else if (declared != expected) {
          builder.issue('conflicting-unit',
              'Field $field declares $expected but ${id}_unit is $declared',
              field: '${id}_unit');
          builder.unmapped(id);
          return;
        }
      }
      unit = expected;
    } else if (suffix == '_serving') {
      // OFF documents `_serving` as the amount per serving in the normalised
      // unit; mass nutrients are normalised to grams. `_unit` describes the
      // originally entered value and is authoritative only for `_100g`.
      unit = 'g';
    } else {
      unit = rawUnit == null ? null : canonicalNutrientUnit(rawUnit);
      if (unit == null && amount != null) {
        builder.issue(
            rawUnit == null ? 'missing-unit' : 'unsupported-unit',
            rawUnit == null
                ? 'Nutrient $id has no unit'
                : 'Unsupported nutrient unit "$rawUnit"',
            field: '${id}_unit');
        builder.unmapped(id);
        return;
      }
    }

    final modifier = _text(nutriments['${id}_modifier']);
    final qualifier = amount == null
        ? ObservationQualifier.unknown
        : amount == Exact.zero
            ? ObservationQualifier.reportedZero
            : modifier != null &&
                    (modifier.contains('<') ||
                        modifier.contains('>') ||
                        modifier.contains('~'))
                ? ObservationQualifier.estimated
                : ObservationQualifier.reported;
    final origin = 'open-food-facts:nutriments.$field'
        '${modifier == null ? '' : ';modifier=$modifier'}';
    final definition = spec.key == NutrientKey.carbohydrateG
        ? carbohydrateDefinition ?? sourceDefinedCarbohydrate
        : spec.definition;
    final added = builder.addObservation(
        key: spec.key,
        amount: amount,
        sourceUnit: unit ?? '',
        basis: basis,
        sourceId: sourceId,
        origin: origin,
        definition: definition,
        qualifier: qualifier);
    if (!added) builder.unmapped(id);
  }

  void _addGenericEnergy({
    required Map<String, Object?> nutriments,
    required String suffix,
    required FoodAmount basis,
    required String sourceId,
    required ImportedFoodBuilder builder,
  }) {
    final field = 'energy$suffix';
    if (!nutriments.containsKey(field)) return;
    final rawUnit = _text(nutriments['energy_unit']);
    final unit = rawUnit == null ? null : canonicalNutrientUnit(rawUnit);
    if (unit != 'kJ' && unit != 'kcal') {
      builder.issue('ambiguous-energy-unit',
          'energy is used only when energy_unit names kcal or kJ',
          field: 'energy_unit');
      builder.unmapped('energy');
      return;
    }
    final specific = unit == 'kJ' ? 'energy-kj$suffix' : 'energy-kcal$suffix';
    if (nutriments.containsKey(specific)) {
      // The specific field is authoritative; the generic duplicate is not
      // imported to avoid two values for one declared-energy identity.
      return;
    }
    _addNutrient(
        nutriments: nutriments,
        id: 'energy',
        spec: _OffSpec(unit == 'kJ'
            ? NutrientKey.energyKj
            : NutrientKey.energyKcal,
            fixedUnit: unit,
            definition: NutrientDefinitions.declaredEnergy),
        suffix: suffix,
        basis: basis,
        sourceId: sourceId,
        builder: builder);
  }
}

final class _OffSpec {
  const _OffSpec(this.key, {this.fixedUnit, this.definition});

  final NutrientKey key;
  final String? fixedUnit;
  final String? definition;
}

const Map<String, _OffSpec> _offSpecs = <String, _OffSpec>{
  'fat': _OffSpec(NutrientKey.fatG),
  'saturated-fat': _OffSpec(NutrientKey.saturatedFatG),
  'carbohydrates': _OffSpec(NutrientKey.carbohydrateG),
  'sugars': _OffSpec(NutrientKey.sugarsG),
  'fiber': _OffSpec(NutrientKey.fiberG),
  'proteins': _OffSpec(NutrientKey.proteinG),
  'sodium': _OffSpec(NutrientKey.sodiumMg),
  'calcium': _OffSpec(NutrientKey.calciumMg),
  'iron': _OffSpec(NutrientKey.ironMg),
  'iodine': _OffSpec(NutrientKey.iodineUg),
  'vitamin-c': _OffSpec(NutrientKey.vitaminCMg),
  'vitamin-d': _OffSpec(NutrientKey.vitaminDUg),
};

/// Keys in `nutriments` that are scores/estimates rather than nutrient amounts.
const Set<String> _nonNutrientIds = <String>{
  'nova-group',
  'fruits-vegetables-legumes-estimate-from-ingredients',
  'fruits-vegetables-nuts-estimate-from-ingredients',
  'ph',
};

const Map<String, String> _ingredientTagMap = <String, String>{
  'vegan': 'vegan',
  'vegetarian': 'vegetarian',
  'palm-oil-free': 'palm-oil-free',
};

const Map<String, String> _labelTagMap = <String, String>{
  'organic': 'organic',
  'gluten-free': 'gluten-free',
  'lactose-free': 'lactose-free',
  'vegan': 'vegan',
  'vegetarian': 'vegetarian',
};

String? _basisSuffix(Map<String, Object?> nutriments) {
  bool hasMapped(String suffix) =>
      _offSpecs.keys.any((id) => nutriments.containsKey('$id$suffix')) ||
      nutriments.containsKey('energy$suffix') ||
      nutriments.containsKey('energy-kj$suffix') ||
      nutriments.containsKey('energy-kcal$suffix');
  if (hasMapped('_100g')) return '_100g';
  if (hasMapped('_serving')) return '_serving';
  // A record may contain only nutrients this build cannot map. Keep a native
  // basis so the retained source details can still be reviewed.
  if (nutriments.keys.any((key) => key.endsWith('_100g'))) return '_100g';
  if (nutriments.keys.any((key) => key.endsWith('_serving'))) {
    return '_serving';
  }
  return null;
}

void _collectUnmapped(
    Map<String, Object?> nutriments, ImportedFoodBuilder builder) {
  final unmapped = <String>{};
  for (final key in nutriments.keys) {
    final String? base = key.endsWith('_100g')
        ? key.substring(0, key.length - 5)
        : key.endsWith('_serving')
            ? key.substring(0, key.length - 8)
            : null;
    if (base == null || base.isEmpty) continue;
    if (_offSpecs.containsKey(base) ||
        base == 'energy' ||
        base == 'energy-kj' ||
        base == 'energy-kcal') {
      continue;
    }
    if (_nonNutrientIds.contains(base)) continue;
    unmapped.add(base);
  }
  for (final id in unmapped) {
    builder.unmapped(id);
  }
}

/// OFF allergen tags are user-contributed and not a verified complete
/// declaration. Retain the raw list for review; [Food.allergens] remains null
/// because the planner treats a non-null set as complete.
void _recordAllergenTags(
    Map<String, Object?> product, ImportedFoodBuilder builder) {
  if (!product.containsKey('allergens_tags')) return;
  final raw = product['allergens_tags'];
  if (raw == null) return;
  if (raw is! List<Object?>) {
    builder.issue('invalid-allergens',
        'allergens_tags is not a list', field: 'allergens_tags');
    return;
  }
  builder.detail('allergens_tags', List<Object?>.unmodifiable(raw));
}

Set<String> _dietaryTags(Map<String, Object?> product) {
  final tags = <String>{};
  final ingredients = product['ingredients_analysis_tags'];
  if (ingredients is List<Object?>) {
    for (final value in ingredients) {
      final text = _text(value);
      if (text == null) continue;
      final mapped = _ingredientTagMap[_tagSuffix(text)];
      if (mapped != null) tags.add(mapped);
    }
  }
  final labels = product['labels_tags'];
  if (labels is List<Object?>) {
    for (final value in labels) {
      final text = _text(value);
      if (text == null) continue;
      final mapped = _labelTagMap[_tagSuffix(text)];
      if (mapped != null) tags.add(mapped);
    }
  }
  return tags;
}

List<String>? _tagSuffixes(Object? raw) {
  if (raw is! List<Object?>) return null;
  final tags = <String>[];
  for (final value in raw) {
    final text = _text(value);
    if (text == null) continue;
    final tag = _tagSuffix(text);
    if (tag.isNotEmpty && tag != 'none' && !tags.contains(tag)) tags.add(tag);
  }
  return List<String>.unmodifiable(tags);
}

String _tagSuffix(String tag) {
  final index = tag.indexOf(':');
  final value = index < 0 ? tag : tag.substring(index + 1);
  return value.trim().toLowerCase();
}

List<String> _aliases(Map<String, Object?> product, String name) {
  final aliases = <String>[];
  void add(String? value) {
    if (value != null && value != name && !aliases.contains(value)) {
      aliases.add(value);
    }
  }

  add(_text(product['generic_name']));
  final brands = _text(product['brands']);
  if (brands != null) {
    for (final part in brands.split(',')) {
      add(_text(part));
    }
  }
  return aliases;
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map<Object?, Object?>) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      result['${entry.key}'] = entry.value;
    }
    return result;
  }
  return const <String, Object?>{};
}

String? _text(Object? value) {
  if (value is String) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }
  if (value is num) return value.toString();
  return null;
}
