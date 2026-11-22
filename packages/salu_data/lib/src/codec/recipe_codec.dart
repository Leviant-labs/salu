import 'package:salu_core/salu_core.dart';

/// Current document format version for encoded [RecipeVersion] payloads.
///
/// Distinct from [RecipeVersion.version], which is the user-visible recipe
/// revision number.
const int recipeFormatVersion = 1;

/// Validates a persisted document's `'version'` tag.
///
/// Returns `true` when [data] already carries [expectedVersion], `false` when
/// `'version'` is absent (legacy unversioned document), and throws
/// [FormatException] for any unsupported or future value.
bool isCurrentDocumentVersion(
  Map<String, dynamic> data,
  int expectedVersion, {
  required String documentName,
}) {
  if (!data.containsKey('version')) return false;
  final version = data['version'];
  if (version == expectedVersion) return true;
  throw FormatException(
    'Unsupported $documentName version: $version',
    version,
  );
}

/// Encodes a [RecipeVersion] losslessly with `versionFormat: 1`.
Map<String, Object?> encodeRecipe(RecipeVersion recipe) => {
      'versionFormat': recipeFormatVersion,
      'id': recipe.id,
      'name': recipe.name,
      'version': recipe.version,
      'prepMinutes': recipe.prepMinutes,
      'servings': recipe.servings,
      if (recipe.finishedGrams != null) 'finishedGrams': recipe.finishedGrams,
      'method': recipe.method,
      'minServings': recipe.minServings,
      'maxServings': recipe.maxServings,
      if (recipe.allergens != null)
        'allergens': (recipe.allergens!.toList()..sort()),
      if (recipe.allergenSource != null)
        'allergenSource': recipe.allergenSource,
      'ingredients': [
        for (final ingredient in recipe.ingredients)
          encodeRecipeIngredient(ingredient),
      ],
    };

/// Decodes a [RecipeVersion] from either `versionFormat: 1` or legacy
/// unversioned form (`versionFormat` absent).
///
/// Throws [FormatException] for unsupported `versionFormat` values or malformed
/// persisted fields.
RecipeVersion decodeRecipe(Map<String, dynamic> row) {
  final hasFormat = row.containsKey('versionFormat');
  if (hasFormat && row['versionFormat'] != recipeFormatVersion) {
    throw FormatException(
      'Unsupported recipe format version: ${row['versionFormat']}',
      row['versionFormat'],
    );
  }
  final isLegacy = !hasFormat;

  final id = _requireNonEmptyString(
    row['id'],
    'id',
    allowWhitespaceOnly: true,
  );
  final name = _requireNonEmptyString(row['name'], 'name');
  final version = _requireInt(row['version'], 'version', min: 1);
  final prepMinutes = _requireInt(row['prepMinutes'], 'prepMinutes', min: 0);
  final servings = _requirePositiveDouble(row['servings'], 'servings');
  final finishedGrams =
      _optionalPositiveDouble(row['finishedGrams'], 'finishedGrams');
  final method = _optionalString(row['method'], 'method') ?? '';
  final minServings =
      _optionalPositiveDouble(row['minServings'], 'minServings') ?? 0.5;
  final maxServings =
      _optionalPositiveDouble(row['maxServings'], 'maxServings') ?? 3.0;
  if (maxServings < minServings) {
    throw FormatException(
      'maxServings ($maxServings) must be >= minServings ($minServings)',
    );
  }
  final allergens = _optionalStringList(row['allergens'], 'allergens')?.toSet();
  final allergenSource =
      _optionalString(row['allergenSource'], 'allergenSource');

  final rawIngredients = row['ingredients'];
  if (rawIngredients is! List || rawIngredients.isEmpty) {
    throw FormatException(
      'Recipe must contain a non-empty ingredients list',
      rawIngredients,
    );
  }
  final ingredients = <RecipeIngredient>[
    for (final raw in rawIngredients)
      if (raw is Map)
        decodeRecipeIngredient(
          Map<String, dynamic>.from(raw),
          allowLegacyFlatFood: isLegacy,
        )
      else
        throw FormatException('Invalid recipe ingredient entry', raw),
  ];

  return RecipeVersion(
    id: id,
    name: name,
    version: version,
    prepMinutes: prepMinutes,
    servings: servings,
    finishedGrams: finishedGrams,
    method: method,
    minServings: minServings,
    maxServings: maxServings,
    allergens: allergens,
    allergenSource: allergenSource,
    ingredients: ingredients,
  );
}

/// Encodes a [RecipeIngredient] with its full [Food] record and purchase info.
Map<String, Object?> encodeRecipeIngredient(RecipeIngredient ingredient) => {
      'food': encodeFood(ingredient.food),
      'edibleGrams': ingredient.edibleGrams,
      'purchaseName': ingredient.purchaseName,
      if (ingredient.purchaseGrams != null)
        'purchaseGrams': ingredient.purchaseGrams,
      if (ingredient.purchaseId != null) 'purchaseId': ingredient.purchaseId,
    };

/// Decodes a [RecipeIngredient] from v1 or legacy flat ingredient rows.
RecipeIngredient decodeRecipeIngredient(
  Map<String, dynamic> row, {
  bool allowLegacyFlatFood = false,
}) {
  final Food food;
  if (row.containsKey('food')) {
    final rawFood = row['food'];
    if (rawFood is! Map) {
      throw FormatException('Invalid food map in recipe ingredient', rawFood);
    }
    food = decodeFood(Map<String, dynamic>.from(rawFood));
  } else if (allowLegacyFlatFood) {
    food = _decodeLegacyFlatFood(row);
  } else {
    throw const FormatException('Recipe ingredient is missing food');
  }

  final edibleGrams = _requirePositiveDouble(row['edibleGrams'], 'edibleGrams');
  final purchaseName =
      _requireNonEmptyString(row['purchaseName'], 'purchaseName');
  final purchaseGrams =
      _optionalPositiveDouble(row['purchaseGrams'], 'purchaseGrams');
  final purchaseId = _optionalString(row['purchaseId'], 'purchaseId');

  return RecipeIngredient(
    food: food,
    edibleGrams: edibleGrams,
    purchaseName: purchaseName,
    purchaseGrams: purchaseGrams,
    purchaseId: purchaseId,
  );
}

/// Encodes every field of a [Food] record losslessly.
Map<String, Object?> encodeFood(Food food) => {
      'id': food.id,
      'name': food.name,
      'per100g': food.per100g.toJson(),
      'source': {
        'dataset': food.source.dataset,
        'datasetId': food.source.datasetId,
        if (food.source.datasetVersion != null)
          'datasetVersion': food.source.datasetVersion,
        if (food.source.licence != null) 'licence': food.source.licence,
      },
      if (food.portions.portionGrams != null ||
          food.portions.densityGramsPerMillilitre != null)
        'portions': {
          if (food.portions.portionGrams != null)
            'portionGrams': food.portions.portionGrams,
          if (food.portions.densityGramsPerMillilitre != null)
            'densityGramsPerMillilitre':
                food.portions.densityGramsPerMillilitre,
        },
      'quality': food.quality.name,
      'preparation': food.preparation.name,
      if (food.allergens != null)
        'allergens': (food.allergens!.toList()..sort()),
      if (food.dietaryTags.isNotEmpty)
        'dietaryTags': (food.dietaryTags.toList()..sort()),
      'isComposite': food.isComposite,
    };

/// Decodes a [Food] record encoded by [encodeFood].
Food decodeFood(Map<String, dynamic> row) {
  final id = _requireNonEmptyString(
    row['id'],
    'food.id',
    allowWhitespaceOnly: true,
  );
  final name = _requireNonEmptyString(row['name'], 'food.name');
  final per100g = decodeNutrientProfile(row['per100g']);

  final rawSource = row['source'];
  if (rawSource is! Map) {
    throw FormatException('Invalid food source', rawSource);
  }
  final sourceMap = Map<String, dynamic>.from(rawSource);
  final source = FoodSource(
    dataset: _requireNonEmptyString(sourceMap['dataset'], 'source.dataset'),
    datasetId: _requireNonEmptyString(
      sourceMap['datasetId'],
      'source.datasetId',
      allowWhitespaceOnly: true,
    ),
    datasetVersion:
        _optionalString(sourceMap['datasetVersion'], 'source.datasetVersion'),
    licence: _optionalString(sourceMap['licence'], 'source.licence'),
  );

  final PortionDefinition portions;
  final rawPortions = row['portions'];
  if (rawPortions == null) {
    portions = PortionDefinition.massOnly;
  } else if (rawPortions is Map) {
    final portionMap = Map<String, dynamic>.from(rawPortions);
    portions = PortionDefinition(
      portionGrams: _optionalPositiveDouble(
        portionMap['portionGrams'],
        'portions.portionGrams',
      ),
      densityGramsPerMillilitre: _optionalPositiveDouble(
        portionMap['densityGramsPerMillilitre'],
        'portions.densityGramsPerMillilitre',
      ),
    );
  } else {
    throw FormatException('Invalid food portions', rawPortions);
  }

  final quality = row['quality'] == null
      ? DataQuality.imported
      : _enumByName(DataQuality.values, row['quality'], 'food.quality');
  final preparation = row['preparation'] == null
      ? Preparation.unspecified
      : _enumByName(Preparation.values, row['preparation'], 'food.preparation');
  final allergens =
      _optionalStringList(row['allergens'], 'food.allergens')?.toSet();
  final dietaryTags =
      _optionalStringList(row['dietaryTags'], 'food.dietaryTags')?.toSet() ??
          const <String>{};
  final isComposite =
      _optionalBool(row['isComposite'], 'food.isComposite') ?? false;

  return Food(
    id: id,
    name: name,
    per100g: per100g,
    source: source,
    portions: portions,
    quality: quality,
    preparation: preparation,
    allergens: allergens,
    dietaryTags: dietaryTags,
    isComposite: isComposite,
  );
}

Food _decodeLegacyFlatFood(Map<String, dynamic> row) {
  final id = _requireNonEmptyString(
    row['id'],
    'id',
    allowWhitespaceOnly: true,
  );
  final name = _requireNonEmptyString(row['name'], 'name');
  final per100g = decodeNutrientProfile(row['nutrients']);
  final source = FoodSource(
    dataset: _requireNonEmptyString(row['source'], 'source'),
    datasetId: _requireNonEmptyString(
      row['sourceId'],
      'sourceId',
      allowWhitespaceOnly: true,
    ),
    datasetVersion: _optionalString(row['sourceVersion'], 'sourceVersion'),
    licence: _optionalString(row['licence'], 'licence'),
  );
  final portions = PortionDefinition(
    portionGrams: _optionalPositiveDouble(row['portionGrams'], 'portionGrams'),
    densityGramsPerMillilitre: _optionalPositiveDouble(
      row['densityGramsPerMillilitre'],
      'densityGramsPerMillilitre',
    ),
  );
  final quality = row['quality'] == null
      ? DataQuality.imported
      : _enumByName(DataQuality.values, row['quality'], 'quality');
  final preparation = row['preparation'] == null
      ? Preparation.unspecified
      : _enumByName(Preparation.values, row['preparation'], 'preparation');
  final allergens = _optionalStringList(row['allergens'], 'allergens')?.toSet();
  final dietaryTags =
      _optionalStringList(row['dietaryTags'], 'dietaryTags')?.toSet() ??
          const <String>{};
  final isComposite = _optionalBool(row['isComposite'], 'isComposite') ?? false;

  return Food(
    id: id,
    name: name,
    per100g: per100g,
    source: source,
    portions: portions,
    quality: quality,
    preparation: preparation,
    allergens: allergens,
    dietaryTags: dietaryTags,
    isComposite: isComposite,
  );
}

/// Validates and decodes a [NutrientProfile] from JSON.
///
/// When [strict] is `true`, malformed entries (non-map payloads, invalid states,
/// negative or non-finite values) throw [FormatException]. Unknown nutrient wire
/// keys are ignored for forward compatibility.
NutrientProfile decodeNutrientProfile(Object? raw, {bool strict = true}) {
  if (raw == null && !strict) return const NutrientProfile.empty();
  if (raw is! Map) {
    throw FormatException('Expected map for nutrients', raw);
  }
  final values = <NutrientKey, NutrientValue>{};
  for (final entry in raw.entries) {
    final rawKey = entry.key;
    if (rawKey is! String) {
      throw FormatException('Expected string nutrient key', rawKey);
    }
    final key = NutrientKey.fromWire(rawKey);
    if (key == null) continue;
    if (!strict) {
      values[key] = NutrientValue.fromJson(entry.value);
      continue;
    }
    final rawValue = entry.value;
    if (rawValue is! Map) {
      throw FormatException('Expected map for nutrient $rawKey', rawValue);
    }
    final state = rawValue['state'];
    switch (state) {
      case 'unknown':
        values[key] = const NutrientUnknown();
      case 'trace':
        values[key] = const NutrientTrace();
      case 'measured':
        values[key] = NutrientMeasured(
          _requireNonNegativeDouble(rawValue['value'], '$rawKey.value'),
        );
      case 'reported':
        values[key] = NutrientReported(
          _requireNonNegativeDouble(rawValue['value'], '$rawKey.value'),
        );
      case 'estimated':
        values[key] = NutrientEstimated(
          _requireNonNegativeDouble(rawValue['value'], '$rawKey.value'),
          basis: _optionalString(rawValue['basis'], '$rawKey.basis') ??
              'unspecified',
        );
      default:
        throw FormatException(
          'Unsupported nutrient state for $rawKey: $state',
          state,
        );
    }
  }
  return NutrientProfile(values);
}

/// Shared JSON serializer for [PhotoMealItem] across diary and saved-meal stores.
Map<String, Object?> encodePhotoMealItem(PhotoMealItem item) => {
      if (item.id != null) 'id': item.id,
      'name': item.name,
      if (item.portion case final portion?) ...{
        'amount': portion.amount,
        'unit': portion.unit.name,
      },
      'nutrients': item.nutrients.toJson(),
      if (item.source != null) 'source': item.source,
      if (item.labelPaths.isNotEmpty) 'labelPaths': item.labelPaths,
      if (item.reviewIssues.isNotEmpty)
        'reviewIssues': [
          for (final issue in item.reviewIssues) issue.toJson(),
        ],
    };

/// Shared JSON deserializer for [PhotoMealItem] across diary and saved-meal
/// stores.
PhotoMealItem decodePhotoMealItem(
  Object? raw, {
  String? fallbackId,
  bool strict = true,
}) {
  if (raw is! Map) {
    throw FormatException('Invalid PhotoMealItem payload', raw);
  }
  final row = Map<String, dynamic>.from(raw);
  final name = _requireNonEmptyString(row['name'], 'name');
  final id = _optionalString(row['id'], 'id') ?? fallbackId;

  final rawAmount = row['amount'];
  final rawUnit = row['unit'];
  final MealPortion? portion;
  if (rawAmount == null && rawUnit == null) {
    portion = null;
  } else if (rawAmount == null || rawUnit == null) {
    throw FormatException('Incomplete portion on PhotoMealItem', row);
  } else {
    portion = MealPortion(
      _requirePositiveDouble(rawAmount, 'amount'),
      _enumByName(MealUnit.values, rawUnit, 'unit'),
    );
  }

  final nutrients = decodeNutrientProfile(row['nutrients'], strict: strict);
  final labelPath = _optionalString(row['labelPath'], 'labelPath');
  final labelPaths =
      _optionalStringList(row['labelPaths'], 'labelPaths') ?? const [];
  final source = _optionalString(row['source'], 'source');
  final reviewIssues = _decodeIssues(row['reviewIssues'], strict: strict);

  return PhotoMealItem(
    name: name,
    id: id,
    portion: portion,
    nutrients: nutrients,
    labelPath: labelPath,
    labelPaths: labelPaths,
    source: source,
    reviewIssues: reviewIssues,
  );
}

List<NutritionIssue> _decodeIssues(Object? raw, {required bool strict}) {
  if (raw == null) return const [];
  if (raw is! List) {
    if (strict) {
      throw FormatException('Expected list for reviewIssues', raw);
    }
    return const [];
  }
  final issues = <NutritionIssue>[];
  for (final entry in raw) {
    if (entry is! Map) {
      if (strict) {
        throw FormatException('Invalid NutritionIssue entry', entry);
      }
      continue;
    }
    try {
      issues.add(NutritionIssue.fromJson(Map<String, Object?>.from(entry)));
    } on FormatException {
      if (strict) rethrow;
    }
  }
  return issues;
}

T _enumByName<T extends Enum>(List<T> values, Object? raw, String field) {
  if (raw is! String) {
    throw FormatException('Expected string for $field', raw);
  }
  for (final value in values) {
    if (value.name == raw) return value;
  }
  throw FormatException('Invalid $field: $raw', raw);
}

String _requireNonEmptyString(
  Object? raw,
  String field, {
  bool allowWhitespaceOnly = false,
}) {
  if (raw is! String) {
    throw FormatException('Expected string for $field', raw);
  }
  final empty = allowWhitespaceOnly ? raw.isEmpty : raw.trim().isEmpty;
  if (empty) {
    throw FormatException('Expected non-empty string for $field', raw);
  }
  return raw;
}

String? _optionalString(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! String) {
    throw FormatException('Expected string for $field', raw);
  }
  return raw;
}

int _requireInt(Object? raw, String field, {int min = 0}) {
  if (raw is! int) {
    throw FormatException('Expected integer for $field', raw);
  }
  if (raw < min) {
    throw FormatException('Expected integer >= $min for $field', raw);
  }
  return raw;
}

double _requirePositiveDouble(Object? raw, String field) {
  if (raw is! num) {
    throw FormatException('Expected number for $field', raw);
  }
  final value = raw.toDouble();
  if (!value.isFinite || value <= 0) {
    throw FormatException('Expected finite positive number for $field', raw);
  }
  return value;
}

double? _optionalPositiveDouble(Object? raw, String field) {
  if (raw == null) return null;
  return _requirePositiveDouble(raw, field);
}

double _requireNonNegativeDouble(Object? raw, String field) {
  if (raw is! num) {
    throw FormatException('Expected number for $field', raw);
  }
  final value = raw.toDouble();
  if (!value.isFinite || value < 0) {
    throw FormatException(
      'Expected finite non-negative number for $field',
      raw,
    );
  }
  return value;
}

bool? _optionalBool(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! bool) {
    throw FormatException('Expected bool for $field', raw);
  }
  return raw;
}

List<String>? _optionalStringList(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! List) {
    throw FormatException('Expected list for $field', raw);
  }
  return [
    for (final item in raw)
      if (item is String)
        item
      else
        throw FormatException('Expected string element in $field', item),
  ];
}
