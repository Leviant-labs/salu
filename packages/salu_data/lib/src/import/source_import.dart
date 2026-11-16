import 'package:salu_core/salu_core.dart';

/// A problem encountered while normalizing one source record.
///
/// Issues are diagnostics for import review; they never replace valid source
/// values and never grant dataset or licence approval.
final class FoodImportIssue {
  const FoodImportIssue(this.code, this.message, {this.field});

  /// Stable machine-readable category, e.g. `unsupported-unit`.
  final String code;

  /// Human-readable explanation.
  final String message;

  /// Source field or record path the issue refers to, when known.
  final String? field;

  @override
  String toString() =>
      field == null ? '$code: $message' : '$code ($field): $message';
}

/// One normalized source record, ready to be staged for catalogue activation.
final class FoodImportResult {
  FoodImportResult({
    required this.food,
    required List<FoodImportIssue> issues,
    required List<String> unmappedNutrients,
    required Map<String, Object?> sourceDetails,
  })  : issues = List<FoodImportIssue>.unmodifiable(issues),
        unmappedNutrients = List<String>.unmodifiable(unmappedNutrients),
        sourceDetails = Map<String, Object?>.unmodifiable(sourceDetails);

  final Food food;

  /// Normalization problems, including unsupported units and invalid barcodes.
  final List<FoodImportIssue> issues;

  /// Source nutrient identifiers that have no reviewed mapping in this build.
  final List<String> unmappedNutrients;

  /// Source fields that [Food] does not model, retained for import review.
  final Map<String, Object?> sourceDetails;
}

/// Canonical spelling of a nutrient unit this package can convert.
///
/// Source schemas spell the same unit differently (`UG`, `µg`, `mcg`), so
/// callers must canonicalize before asking for a conversion factor. An
/// unrecognised unit returns `null` and must not be guessed.
String? canonicalNutrientUnit(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'g':
    case 'gram':
    case 'grams':
      return 'g';
    case 'mg':
    case 'milligram':
    case 'milligrams':
      return 'mg';
    case 'ug':
    case 'mcg':
    case 'µg':
    case 'μg':
      return 'µg';
    case 'kcal':
    case 'kilocalorie':
    case 'kilocalories':
      return 'kcal';
    case 'kj':
    case 'kilojoule':
    case 'kilojoules':
      return 'kJ';
    default:
      return null;
  }
}

/// Canonical mass or volume unit for a source food quantity, or `null`.
///
/// This is deliberately separate from [canonicalNutrientUnit]: a food basis may
/// be grams or millilitres, while a nutrient amount is grams, milligrams,
/// micrograms, kcal or kJ. A density is never assumed between the two.
FoodUnit? canonicalFoodUnit(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'g':
    case 'gram':
    case 'grams':
      return FoodUnit.g;
    case 'ml':
    case 'milliliter':
    case 'millilitre':
    case 'milliliters':
    case 'millilitres':
      return FoodUnit.ml;
    default:
      return null;
  }
}

/// Parses a source number without turning an absent or unknown marker into zero.
///
/// JSON numbers arrive as [num]; some bulk exports use strings. Negative values
/// are returned unchanged so callers can distinguish a bad record from an
/// omitted nutrient. `-`, `n/a`, `unknown` and an empty string are missing.
Exact? parseSourceAmount(Object? value) {
  if (value is num) {
    if (!value.isFinite) return null;
    try {
      return Exact.parse(value.toString());
    } on FormatException {
      return null;
    }
  }
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();
    if (lower == '-' ||
        lower == 'n/a' ||
        lower == 'na' ||
        lower == 'null' ||
        lower == 'unknown') {
      return null;
    }
    try {
      return Exact.parse(text);
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// Measure identity the food basis uses for count units.
String? measureIdForUnit(FoodUnit unit) {
  if (unit == FoodUnit.item) return 'piece';
  if (unit == FoodUnit.serving) return 'serving';
  return null;
}

final RegExp _isoCalendarDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Whether [value] is a real calendar date in ISO 8601 `YYYY-MM-DD` form.
///
/// Evidence dates stay as printed calendar values; out-of-range days are
/// rejected instead of being rolled over by [DateTime].
bool _isIsoCalendarDate(String value) {
  if (!_isoCalendarDate.hasMatch(value)) return false;
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  if (month < 1 || month > 12 || day < 1) return false;
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day;
}

/// Collects observations for one source record, rejecting duplicates and
/// unsupported units before a [Food] is constructed.
///
/// This is deliberately not a dataset loader: it only adds nutrient values the
/// caller has already read from a named source field with a named definition.
final class ImportedFoodBuilder {
  ImportedFoodBuilder({
    required this.dataset,
    required this.datasetVersion,
    required this.licence,
  }) {
    if (dataset.trim().isEmpty ||
        datasetVersion.trim().isEmpty ||
        licence.trim().isEmpty) {
      throw ArgumentError('Source provenance cannot be empty');
    }
  }

  final String dataset, datasetVersion, licence;
  final List<NutrientObservation> _observations = <NutrientObservation>[];
  final Set<String> _identities = <String>{};
  final List<FoodImportIssue> _issues = <FoodImportIssue>[];
  final Set<String> _unmapped = <String>{};
  final Map<String, Object?> _details = <String, Object?>{};

  /// Whether this record has at least one retained observation.
  bool get hasObservations => _observations.isNotEmpty;

  void issue(String code, String message, {String? field}) {
    _issues.add(FoodImportIssue(code, message, field: field));
  }

  /// Records a source nutrient that this build cannot map without inventing a
  /// definition or unit.
  void unmapped(String nutrient) {
    final text = nutrient.trim();
    if (text.isNotEmpty) _unmapped.add(text);
  }

  /// Retains a source field for review when [Food] has no matching property.
  void detail(String key, Object? value) {
    if (value != null) _details[key] = value;
  }

  /// Adds one observation. Returns `false` when it cannot be represented.
  ///
  /// [amount] is in [sourceUnit]. It is converted exactly to [key]'s declared
  /// unit. Qualifiers that carry no number (`unknown`, `trace`, `belowDetection`)
  /// intentionally discard a supplied number rather than asserting an exact
  /// amount the source did not claim.
  ///
  /// [suppliedInterval] carries only an interval the source itself documents
  /// for this value. Its bounds are read in [sourceUnit], converted exactly with
  /// the same factor as [amount], and retained in [key]'s unit on [basis]; they
  /// are not widened, rounded or treated as intake bounds. Leave it null when
  /// the source gives only sample statistics (for example a minimum and maximum
  /// of analysed samples) without a documented interval definition.
  ///
  /// [evidenceDate] must be the source's printed ISO 8601 `YYYY-MM-DD`
  /// calendar date when it states one. Absent stays absent; it is never
  /// inferred from the dataset version. A value that is not a real calendar
  /// date is reported and omitted without discarding the nutrient value.
  bool addObservation({
    required NutrientKey key,
    required Exact? amount,
    required String sourceUnit,
    required FoodAmount basis,
    required String sourceId,
    required String origin,
    required ObservationQualifier qualifier,
    String? definition,
    SourceInterval? suppliedInterval,
    String? evidenceDate,
  }) {
    if (sourceId.trim().isEmpty || origin.trim().isEmpty) {
      issue('missing-provenance', 'Observation has no source identity',
          field: origin);
      return false;
    }
    final numeric = (qualifier == ObservationQualifier.reported ||
            qualifier == ObservationQualifier.reportedZero ||
            qualifier == ObservationQualifier.estimated)
        ? amount
        : null;
    if (numeric == null &&
        (qualifier == ObservationQualifier.reported ||
            qualifier == ObservationQualifier.reportedZero ||
            qualifier == ObservationQualifier.estimated)) {
      issue('missing-amount', 'A numeric qualifier has no amount',
          field: origin);
      return false;
    }
    if (numeric != null && numeric.compareTo(Exact.zero) < 0) {
      issue('negative-amount', 'Source amount is negative', field: origin);
      return false;
    }

    Exact? converted;
    SourceInterval? convertedInterval;
    var convertedOrigin = origin;
    if (numeric != null || suppliedInterval != null) {
      final unit = canonicalNutrientUnit(sourceUnit);
      if (unit == null) {
        issue('unsupported-unit', 'Unsupported nutrient unit "$sourceUnit"',
            field: origin);
        return false;
      }
      final factor = nutrientUnitFactor(unit, key.unit);
      if (factor == null) {
        issue('unsupported-unit',
            'Cannot convert $unit to the declared ${key.unit} basis',
            field: origin);
        return false;
      }
      if (factor != Exact.one) {
        convertedOrigin = '$origin;unit=$unit->${key.unit}';
      }
      if (numeric != null) {
        converted = numeric * factor;
      }
      if (suppliedInterval != null) {
        convertedInterval = SourceInterval(
            lower: suppliedInterval.lower == null
                ? null
                : suppliedInterval.lower! * factor,
            upper: suppliedInterval.upper == null
                ? null
                : suppliedInterval.upper! * factor,
            lowerInclusive: suppliedInterval.lowerInclusive,
            upperInclusive: suppliedInterval.upperInclusive,
            scope: suppliedInterval.scope,
            method: suppliedInterval.method);
      }
    }

    final identity =
        NutrientIdentity(key.wire, key.unit, definition ?? key.wire);
    if (!_identities.add(identity.key)) {
      issue('duplicate-nutrient',
          'Two source values map to ${key.wire} with the same definition',
          field: origin);
      return false;
    }
    final trimmedEvidenceDate = evidenceDate?.trim();
    final normalizedEvidenceDate =
        trimmedEvidenceDate == null || trimmedEvidenceDate.isEmpty
            ? null
            : trimmedEvidenceDate;
    final validEvidenceDate = normalizedEvidenceDate != null &&
        _isIsoCalendarDate(normalizedEvidenceDate);
    if (normalizedEvidenceDate != null && !validEvidenceDate) {
      issue('invalid-evidence-date',
          'Evidence date is not an ISO 8601 calendar date',
          field: origin);
    }
    _observations.add(NutrientObservation(
        nutrient: identity,
        basis: basis,
        qualifier: qualifier,
        sourceId: sourceId,
        sourceVersion: datasetVersion,
        origin: convertedOrigin,
        exactAmount: converted,
        suppliedInterval: convertedInterval,
        evidenceDate: validEvidenceDate ? normalizedEvidenceDate : null));
    return true;
  }

  /// Builds the immutable food record and its import diagnostics.
  ///
  /// The legacy [Food.per100g] profile is the exact projection of the retained
  /// observations onto [basisValue] [basisUnit], so repository validation can
  /// compare the two without a second normalization path.
  FoodImportResult build({
    required String id,
    required String name,
    required String sourceId,
    required FoodUnit basisUnit,
    required String basisValue,
    Preparation preparation = Preparation.unspecified,
    Set<String>? allergens,
    Set<String> dietaryTags = const <String>{},
    List<String> aliases = const <String>[],
    List<String> barcodes = const <String>[],
    List<String> regions = const <String>[],
    double? portionGrams,
    double? densityGramsPerMillilitre,
  }) {
    final basis = FoodAmount(basisValue, basisUnit,
        measureId: measureIdForUnit(basisUnit));
    final observations = List<NutrientObservation>.unmodifiable(_observations);
    final profile = observations.isEmpty
        ? const NutrientProfile.empty()
        : projectObservations(observations, basis: basis);
    final food = Food(
        id: id,
        name: name,
        per100g: profile,
        source: FoodSource(
            dataset: dataset,
            datasetId: sourceId,
            datasetVersion: datasetVersion,
            licence: licence),
        portions: PortionDefinition(
            portionGrams: portionGrams,
            densityGramsPerMillilitre: densityGramsPerMillilitre),
        quality: DataQuality.imported,
        preparation: preparation,
        allergens:
            allergens == null ? null : Set<String>.unmodifiable(allergens),
        dietaryTags: Set<String>.unmodifiable(dietaryTags),
        basisUnit: basisUnit,
        basisValue: basisValue,
        aliases: List<String>.unmodifiable(aliases),
        barcodes: List<String>.unmodifiable(barcodes),
        regions: List<String>.unmodifiable(regions),
        observations: observations);
    return FoodImportResult(
        food: food,
        issues: _issues,
        unmappedNutrients: _unmapped.toList(),
        sourceDetails: _details);
  }
}
