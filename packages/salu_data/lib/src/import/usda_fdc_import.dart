import 'dart:convert';

import 'package:salu_core/salu_core.dart';

import 'source_import.dart';

/// Normalizes USDA FoodData Central foods from the search/detail JSON schema.
///
/// Source facts used by this adapter:
/// * `POST /v1/foods` and `GET /v1/food/{fdcId}` return `foodNutrients` per
///   100 g of edible portion for Foundation, SR Legacy, Survey (FNDDS) and
///   Branded records.
/// * Branded records also return `labelNutrients` per labelled serving. They are
///   used only when `foodNutrients` is absent; otherwise the per-100 g values are
///   preferred and the label values stay in [FoodImportResult.sourceDetails].
/// * `nutrient.unitName` is authoritative for the amount's unit. Values with an
///   unsupported unit (for example IU for vitamin D) stay unmapped instead of
///   being converted with an invented factor.
/// * `derivationDescription`/`derivationCode` describe how a value was obtained.
///   "Assumed zero", "imputed", "less than" and "daily value percentage" are
///   estimated; only a supplied zero with no imputation/assumption derivation is
///   reported_zero. A trace claim is retained as a trace, not an exact zero.
///
/// Dataset version and licence are supplied by the caller; this adapter never
/// asserts a licence review or a dataset release date it was not given.
final class UsdaFdcFoodAdapter {
  UsdaFdcFoodAdapter({required String datasetVersion, required String licence})
      : datasetVersion = datasetVersion.trim(),
        licence = licence.trim() {
    if (this.datasetVersion.isEmpty) {
      throw ArgumentError('USDA dataset version is required');
    }
    if (this.licence.isEmpty) {
      throw ArgumentError('USDA licence identifier is required');
    }
  }

  /// Dataset name used in [FoodSource.dataset] and local food identifiers.
  static const String dataset = 'usda-fdc';

  /// Definition for the source's Atwater general-factor energy value.
  static const String atwaterGeneralDefinition =
      'usda_atwater_general_factors';

  /// Definition for the source's Atwater specific-factor energy value.
  static const String atwaterSpecificDefinition =
      'usda_atwater_specific_factors';

  final String datasetVersion, licence;

  /// Normalizes one decoded FoodData Central food object.
  ///
  /// Throws [FormatException] when the record has no `fdcId` or description.
  /// Nutrient-level problems are returned as issues so one bad value does not
  /// discard an otherwise usable record.
  FoodImportResult adapt(Map<String, Object?> record) {
    final sourceId = _sourceId(record['fdcId']);
    if (sourceId == null) {
      throw const FormatException('USDA record has no fdcId');
    }
    final name = _text(record['description']);
    if (name == null) {
      throw FormatException('USDA record $sourceId has no description');
    }

    final builder = ImportedFoodBuilder(
        dataset: dataset,
        datasetVersion: datasetVersion,
        licence: licence);

    builder.detail('dataType', _text(record['dataType']));
    builder.detail('ndbNumber', _text(record['ndbNumber']));
    builder.detail('foodCode', _text(record['foodCode']));
    builder.detail('publicationDate', _text(record['publicationDate']));
    builder.detail('foodCategory', _text(record['foodCategory']) ??
        _text(record['brandedFoodCategory']));
    builder.detail('brandName', _text(record['brandName']));
    builder.detail('brandOwner', _text(record['brandOwner']));
    builder.detail('marketCountry', _text(record['marketCountry']));
    builder.detail('scientificName', _text(record['scientificName']));
    builder.detail('ingredients', _text(record['ingredients']));
    builder.detail('householdServingFullText',
        _text(record['householdServingFullText']));
    builder.detail('servingSize', record['servingSize']);
    builder.detail('servingSizeUnit', _text(record['servingSizeUnit']));
    builder.detail('foodPortions', _portionDetails(record));
    builder.detail('labelNutrients', record['labelNutrients']);

    final nutrients = _parseFoodNutrients(record);
    final label = _map(record['labelNutrients']);
    var basisUnit = FoodUnit.g;
    var observationBasis = FoodAmount('100', FoodUnit.g);

    if (nutrients.isNotEmpty) {
      for (final nutrient in nutrients) {
        _addFoodNutrient(
            builder: builder,
            nutrient: nutrient,
            basis: observationBasis,
            sourceId: sourceId);
      }
    } else if (label.isNotEmpty) {
      final serving = _servingBasis(record);
      if (serving == null) {
        builder.issue(
            'missing-serving-basis',
            'labelNutrients are per labelled serving but servingSize is not '
            'a supported mass or volume',
            field: 'servingSize');
      } else {
        observationBasis = serving;
        basisUnit = serving.unit == FoodUnit.ml ? FoodUnit.ml : FoodUnit.g;
        _addLabelNutrients(
            label: label,
            basis: observationBasis,
            sourceId: sourceId,
            builder: builder);
      }
    }

    if (!builder.hasObservations) {
      final hasSourceNutrientData = nutrients.isNotEmpty || label.isNotEmpty;
      builder.issue(
          hasSourceNutrientData ? 'no-mapped-nutrients' : 'no-nutrition-data',
          hasSourceNutrientData
              ? 'No supplied nutrient has a reviewed mapping'
              : 'Record supplies no nutrient data');
    }

    final barcodes = <String>[];
    final gtin = _text(record['gtinUpc']);
    if (gtin != null) {
      try {
        barcodes.add(ProductBarcode(gtin).value);
      } on FormatException {
        builder.issue('invalid-barcode',
            'gtinUpc is not a valid GTIN-8/12/13/14 code',
            field: 'gtinUpc');
      }
    }

    final marketCountry = _text(record['marketCountry']);
    final regions = marketCountry == null
        ? const <String>[]
        : <String>[marketCountry];

    return builder.build(
        id: '$dataset:$sourceId',
        name: name,
        sourceId: sourceId,
        basisUnit: basisUnit,
        basisValue: '100',
        preparation: _preparation(name),
        aliases: _aliases(record, name),
        barcodes: barcodes,
        regions: regions,
        portionGrams: _portionGrams(record));
  }

  /// Normalizes a JSON object exactly as returned by the FoodData Central API.
  FoodImportResult adaptJson(String text) {
    final Object? decoded = jsonDecode(text);
    final record = _map(decoded);
    if (record.isEmpty) {
      throw const FormatException('USDA record must be a JSON object');
    }
    return adapt(record);
  }

  void _addFoodNutrient({
    required ImportedFoodBuilder builder,
    required _FdcNutrient nutrient,
    required FoodAmount basis,
    required String sourceId,
  }) {
    final rawUnit = nutrient.unit;
    final hasUnit = rawUnit != null && rawUnit.trim().isNotEmpty;
    final unit = hasUnit ? canonicalNutrientUnit(rawUnit) : null;

    if (_isEnergyLike(nutrient)) {
      if (nutrient.amount != null && unit == null) {
        builder.issue(
            hasUnit ? 'unsupported-unit' : 'missing-unit',
            hasUnit
                ? 'Unsupported energy unit "$rawUnit"'
                : 'Energy value has no unit',
            field: '${nutrient.originField}.unitName');
        builder.unmapped(_nutrientLabel(nutrient));
        return;
      }
      final mapping = _energyMapping(nutrient, unit, hasUnit);
      if (mapping == null) {
        builder.issue('unsupported-energy-unit',
            'Energy value is not a supported kcal/kJ combination',
            field: nutrient.originField);
        builder.unmapped(_nutrientLabel(nutrient));
        return;
      }
      final added = builder.addObservation(
          key: mapping.key,
          amount: nutrient.amount,
          sourceUnit: unit ?? '',
          basis: basis,
          sourceId: sourceId,
          origin: _origin(nutrient),
          definition: mapping.definition,
          qualifier: mapping.qualifier);
      if (!added) builder.unmapped(_nutrientLabel(nutrient));
      return;
    }

    final spec = _specFor(nutrient.id, nutrient.number);
    if (spec == null) {
      builder.unmapped(_nutrientLabel(nutrient));
      return;
    }
    if (nutrient.amount != null && unit == null) {
      builder.issue(
          hasUnit ? 'unsupported-unit' : 'missing-unit',
          hasUnit
              ? 'Unsupported nutrient unit "$rawUnit"'
              : 'Nutrient value has no unit',
          field: '${nutrient.originField}.unitName');
      builder.unmapped(_nutrientLabel(nutrient));
      return;
    }
    final added = builder.addObservation(
        key: spec.key,
        amount: nutrient.amount,
        sourceUnit: unit ?? '',
        basis: basis,
        sourceId: sourceId,
        origin: _origin(nutrient),
        definition: spec.definition,
        qualifier: _qualifier(nutrient));
    if (!added) builder.unmapped(_nutrientLabel(nutrient));
  }

  void _addLabelNutrients({
    required Map<String, Object?> label,
    required FoodAmount basis,
    required String sourceId,
    required ImportedFoodBuilder builder,
  }) {
    for (final entry in _labelSpecs.entries) {
      if (!label.containsKey(entry.key)) continue;
      final raw = label[entry.key];
      final value =
          raw is Map<Object?, Object?> ? _map(raw)['value'] : raw;
      final amount = parseSourceAmount(value);
      final qualifier = amount == null
          ? ObservationQualifier.unknown
          : amount == Exact.zero
              ? ObservationQualifier.reportedZero
              : ObservationQualifier.reported;
      final added = builder.addObservation(
          key: entry.value.key,
          amount: amount,
          sourceUnit: entry.value.sourceUnit,
          basis: basis,
          sourceId: sourceId,
          origin: 'usda-fdc:labelNutrients.${entry.key}',
          definition: entry.value.definition,
          qualifier: qualifier);
      if (!added) builder.unmapped(entry.key);
    }
    for (final key in label.keys) {
      if (!_labelSpecs.containsKey(key)) builder.unmapped(key);
    }
  }

  _EnergyMapping? _energyMapping(
      _FdcNutrient nutrient, String? unit, bool hasUnit) {
    if (hasUnit && unit == null) return null;
    final id = nutrient.id;
    if (id == 2047 || id == 2048) {
      final actual = unit ?? 'kcal';
      final key = actual == 'kcal'
          ? NutrientKey.energyKcal
          : actual == 'kJ'
              ? NutrientKey.energyKj
              : null;
      if (key == null) return null;
      return _EnergyMapping(
          key,
          id == 2048
              ? atwaterSpecificDefinition
              : atwaterGeneralDefinition,
          nutrient.amount == null
              ? ObservationQualifier.unknown
              : ObservationQualifier.estimated);
    }
    final expected = id == 1008
        ? 'kcal'
        : id == 1062
            ? 'kJ'
            : null;
    final name = (nutrient.name ?? '').toLowerCase().trim();
    if (expected == null && name != 'energy') return null;
    if (expected != null && unit != null && unit != expected) return null;
    final actual = unit ?? expected;
    if (actual == null) return null;
    final key = actual == 'kcal'
        ? NutrientKey.energyKcal
        : actual == 'kJ'
            ? NutrientKey.energyKj
            : null;
    if (key == null) return null;
    return _EnergyMapping(
        key, NutrientDefinitions.declaredEnergy, _qualifier(nutrient));
  }
}

final class _FdcNutrient {
  const _FdcNutrient({
    required this.id,
    required this.number,
    required this.name,
    required this.unit,
    required this.amount,
    required this.derivationCode,
    required this.derivationDescription,
    required this.originField,
  });

  final int? id;
  final String? number, name, unit;
  final Exact? amount;
  final String? derivationCode, derivationDescription;
  final String originField;
}

final class _FdcSpec {
  const _FdcSpec(this.key, {this.definition});

  final NutrientKey key;
  final String? definition;
}

final class _LabelSpec {
  const _LabelSpec(this.key, this.sourceUnit, {this.definition});

  final NutrientKey key;
  final String sourceUnit;
  final String? definition;
}

final class _EnergyMapping {
  const _EnergyMapping(this.key, this.definition, this.qualifier);

  final NutrientKey key;
  final String definition;
  final ObservationQualifier qualifier;
}

const Map<int, _FdcSpec> _fdcById = <int, _FdcSpec>{
  1003: _FdcSpec(NutrientKey.proteinG),
  1004: _FdcSpec(NutrientKey.fatG),
  1005: _FdcSpec(NutrientKey.carbohydrateG,
      definition: NutrientDefinitions.usTotalCarbohydrate),
  1079: _FdcSpec(NutrientKey.fiberG),
  2000: _FdcSpec(NutrientKey.sugarsG),
  1258: _FdcSpec(NutrientKey.saturatedFatG),
  1093: _FdcSpec(NutrientKey.sodiumMg),
  1087: _FdcSpec(NutrientKey.calciumMg),
  1089: _FdcSpec(NutrientKey.ironMg),
  1100: _FdcSpec(NutrientKey.iodineUg),
  1162: _FdcSpec(NutrientKey.vitaminCMg),
  1114: _FdcSpec(NutrientKey.vitaminDUg),
};

const Map<String, _FdcSpec> _fdcByNumber = <String, _FdcSpec>{
  '203': _FdcSpec(NutrientKey.proteinG),
  '204': _FdcSpec(NutrientKey.fatG),
  '205': _FdcSpec(NutrientKey.carbohydrateG,
      definition: NutrientDefinitions.usTotalCarbohydrate),
  '291': _FdcSpec(NutrientKey.fiberG),
  '269': _FdcSpec(NutrientKey.sugarsG),
  '606': _FdcSpec(NutrientKey.saturatedFatG),
  '307': _FdcSpec(NutrientKey.sodiumMg),
  '301': _FdcSpec(NutrientKey.calciumMg),
  '303': _FdcSpec(NutrientKey.ironMg),
  '314': _FdcSpec(NutrientKey.iodineUg),
  '401': _FdcSpec(NutrientKey.vitaminCMg),
  '328': _FdcSpec(NutrientKey.vitaminDUg),
};

const Map<String, _LabelSpec> _labelSpecs = <String, _LabelSpec>{
  'fat': _LabelSpec(NutrientKey.fatG, 'g'),
  'saturatedFat': _LabelSpec(NutrientKey.saturatedFatG, 'g'),
  'sodium': _LabelSpec(NutrientKey.sodiumMg, 'mg'),
  'carbohydrates': _LabelSpec(NutrientKey.carbohydrateG, 'g',
      definition: NutrientDefinitions.usTotalCarbohydrate),
  'fiber': _LabelSpec(NutrientKey.fiberG, 'g'),
  'sugars': _LabelSpec(NutrientKey.sugarsG, 'g'),
  'protein': _LabelSpec(NutrientKey.proteinG, 'g'),
  'calcium': _LabelSpec(NutrientKey.calciumMg, 'mg'),
  'iron': _LabelSpec(NutrientKey.ironMg, 'mg'),
  'calories': _LabelSpec(NutrientKey.energyKcal, 'kcal',
      definition: NutrientDefinitions.declaredEnergy),
};

const Set<String> _pieceUnits = <String>{
  'piece',
  'slice',
  'unit',
  'each',
  'item',
  'link',
  'patty',
  'strip',
  'wedge',
  'serving',
};

_FdcSpec? _specFor(int? id, String? number) =>
    (id == null ? null : _fdcById[id]) ??
    (number == null ? null : _fdcByNumber[number]);

bool _isEnergyLike(_FdcNutrient nutrient) {
  final name = (nutrient.name ?? '').toLowerCase().trim();
  return nutrient.id == 1008 ||
      nutrient.id == 1062 ||
      nutrient.id == 2047 ||
      nutrient.id == 2048 ||
      name == 'energy';
}

ObservationQualifier _qualifier(_FdcNutrient nutrient) {
  final amount = nutrient.amount;
  final description = (nutrient.derivationDescription ?? '').toLowerCase();
  final code = (nutrient.derivationCode ?? '').toUpperCase();
  if (description.contains('trace') || code == 'TR') {
    return ObservationQualifier.trace;
  }
  if (amount == null) return ObservationQualifier.unknown;
  // An assumed or imputed value is not a printed/analytical zero. The nutrition
  // contract requires it to stay estimated even when the supplied amount is 0.
  if (description.contains('assumed zero') ||
      code == 'Z' ||
      description.contains('imputed') ||
      description.contains('less than') ||
      description.contains('daily value') ||
      description.contains('estimated')) {
    return ObservationQualifier.estimated;
  }
  if (amount == Exact.zero) return ObservationQualifier.reportedZero;
  return ObservationQualifier.reported;
}

String _origin(_FdcNutrient nutrient) {
  final code = nutrient.derivationCode;
  return 'usda-fdc:${nutrient.originField}'
      '${code == null ? '' : ';derivation=$code'}';
}

String _nutrientLabel(_FdcNutrient nutrient) {
  final id = nutrient.id?.toString() ?? nutrient.number ?? '?';
  return '$id ${nutrient.name ?? 'unknown nutrient'}';
}

List<_FdcNutrient> _parseFoodNutrients(Map<String, Object?> record) {
  final raw = record['foodNutrients'];
  if (raw is! List<Object?>) return const <_FdcNutrient>[];
  final result = <_FdcNutrient>[];
  for (var index = 0; index < raw.length; index++) {
    final parsed =
        _parseFoodNutrient(_map(raw[index]), 'foodNutrients[$index]');
    if (parsed != null) result.add(parsed);
  }
  return result;
}

_FdcNutrient? _parseFoodNutrient(
    Map<String, Object?> entry, String originField) {
  final nested = _map(entry['nutrient']);
  final id = _integer(nested['id']) ?? _integer(entry['nutrientId']);
  final number =
      _text(nested['number']) ?? _text(entry['nutrientNumber']);
  final name = _text(nested['name']) ?? _text(entry['nutrientName']);
  final unit = _text(nested['unitName']) ?? _text(entry['unitName']);
  if (id == null && number == null && name == null && unit == null) {
    return null;
  }
  final amount = entry.containsKey('amount')
      ? parseSourceAmount(entry['amount'])
      : parseSourceAmount(entry['value']);
  final derivation = _map(entry['foodNutrientDerivation']);
  final derivationDescription =
      _text(derivation['description']) ??
          _text(entry['derivationDescription']);
  final derivationCode =
      _text(derivation['code']) ?? _text(entry['derivationCode']);
  return _FdcNutrient(
      id: id,
      number: number,
      name: name,
      unit: unit,
      amount: amount,
      derivationCode: derivationCode,
      derivationDescription: derivationDescription,
      originField: originField);
}

FoodAmount? _servingBasis(Map<String, Object?> record) {
  final size = parseSourceAmount(record['servingSize']);
  final rawUnit = _text(record['servingSizeUnit']);
  if (size == null || !size.positive || rawUnit == null) return null;
  final unit = canonicalFoodUnit(rawUnit);
  if (unit == null) return null;
  return FoodAmount.exact(size, unit);
}

double? _portionGrams(Map<String, Object?> record) {
  final size = parseSourceAmount(record['servingSize']);
  final rawUnit = _text(record['servingSizeUnit']);
  if (size != null && size.positive && rawUnit != null) {
    if (canonicalFoodUnit(rawUnit) == FoodUnit.g) {
      return size.toDouble();
    }
  }
  final portions = record['foodPortions'];
  if (portions is! List<Object?>) return null;
  final candidates = <double>{};
  for (final raw in portions) {
    final portion = _map(raw);
    final amount = parseSourceAmount(portion['amount']);
    final grams = parseSourceAmount(portion['gramWeight']);
    final measure = _map(portion['measureUnit']);
    final unit = (_text(measure['name']) ?? '').toLowerCase();
    if (amount == Exact.one &&
        grams != null &&
        grams.positive &&
        _pieceUnits.contains(unit)) {
      candidates.add(grams.toDouble());
    }
  }
  // Multiple different piece weights would make "one piece" order-dependent.
  return candidates.length == 1 ? candidates.single : null;
}

List<Map<String, Object?>>? _portionDetails(Map<String, Object?> record) {
  final portions = record['foodPortions'];
  if (portions is! List<Object?> || portions.isEmpty) return null;
  final result = <Map<String, Object?>>[];
  for (final raw in portions) {
    final portion = _map(raw);
    final measure = _map(portion['measureUnit']);
    result.add(<String, Object?>{
      'amount': portion['amount'],
      'gramWeight': portion['gramWeight'],
      'unit': _text(measure['name']),
      'description': _text(portion['portionDescription']),
    });
  }
  return List<Map<String, Object?>>.unmodifiable(result);
}

List<String> _aliases(Map<String, Object?> record, String name) {
  final aliases = <String>[];
  void add(String? value) {
    if (value != null && value != name && !aliases.contains(value)) {
      aliases.add(value);
    }
  }

  final common = _text(record['commonNames']);
  if (common != null) {
    for (final part in common.split(',')) {
      add(_text(part));
    }
  }
  add(_text(record['additionalDescriptions']));
  add(_text(record['brandName']));
  add(_text(record['brandOwner']));
  add(_text(record['scientificName']));
  return aliases;
}

Preparation _preparation(String description) {
  final lower = description.toLowerCase();
  final raw = RegExp(r'\braw\b');
  final cooked = RegExp(
      r'\b(cooked|boiled|roasted|baked|fried|grilled|steamed|toasted|'
      r'braised|stewed|poached|broiled|reheated|pasteurized)\b');
  if (cooked.hasMatch(lower)) return Preparation.cooked;
  if (raw.hasMatch(lower)) return Preparation.raw;
  return Preparation.unspecified;
}

String? _sourceId(Object? value) {
  final text = _text(value);
  return text == null || text.isEmpty ? null : text;
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

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
