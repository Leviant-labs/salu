/// Source-aware, dimensionally explicit arithmetic. No floating-point decisions.
library;

/// An exact rational parsed from a finite decimal. Division retains precision
/// until a presentation boundary; wire values retain the original decimal input.
final class Exact implements Comparable<Exact> {
  Exact._(BigInt n, BigInt d)
      : numerator = n ~/ n.gcd(d),
        denominator = d ~/ n.gcd(d);
  factory Exact.parse(String input) {
    if (input.length > 1024) {
      throw const FormatException('Decimal exceeds storage limit');
    }
    final match =
        RegExp(r'^(-?\d+(?:\.\d+)?)(?:[eE]([+-]?\d+))?$').firstMatch(input);
    if (match == null) {
      throw FormatException('Expected a finite decimal', input);
    }
    final coefficient = match.group(1)!;
    final exponent = int.parse(match.group(2) ?? '0');
    if (exponent.abs() > 300) {
      throw const FormatException('Decimal exponent exceeds storage limit');
    }
    final parts = coefficient.split('.');
    final scale = (parts.length == 2 ? parts[1].length : 0) - exponent;
    final n = BigInt.parse(coefficient.replaceAll('.', ''));
    return scale >= 0
        ? Exact._(n, BigInt.from(10).pow(scale))
        : Exact._(n * BigInt.from(10).pow(-scale), BigInt.one);
  }

  final BigInt numerator;
  final BigInt denominator;
  static final zero = Exact.parse('0');
  static final one = Exact.parse('1');
  Exact operator +(Exact b) => Exact._(
      numerator * b.denominator + b.numerator * denominator,
      denominator * b.denominator);
  Exact operator -(Exact b) => Exact._(
      numerator * b.denominator - b.numerator * denominator,
      denominator * b.denominator);
  Exact operator *(Exact b) =>
      Exact._(numerator * b.numerator, denominator * b.denominator);
  Exact operator /(Exact b) {
    if (b.numerator == BigInt.zero) throw ArgumentError('Division by zero');
    final negative = b.numerator.isNegative;
    return Exact._(
        numerator * b.denominator * (negative ? -BigInt.one : BigInt.one),
        denominator * b.numerator.abs());
  }

  bool get positive => numerator > BigInt.zero;
  double toDouble() => numerator.toDouble() / denominator.toDouble();
  @override
  int compareTo(Exact other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);
  @override
  bool operator ==(Object other) => other is Exact && compareTo(other) == 0;
  @override
  int get hashCode => Object.hash(numerator, denominator);

  /// Exact fraction serialization avoids rounding a repeating recipe allocation.
  Map<String, Object?> toJson() => {'n': '$numerator', 'd': '$denominator'};
  factory Exact.fromJson(Map<String, Object?> json) {
    if ((json['d']! as String).length > 4096 ||
        (json['n']! as String).length > 4096) {
      throw const FormatException('Exact number exceeds storage limit');
    }
    final d = BigInt.parse(json['d']! as String);
    if (d <= BigInt.zero) throw const FormatException('Invalid denominator');
    return Exact._(BigInt.parse(json['n']! as String), d);
  }
  @override
  String toString() => toDouble().toString();
}

enum FoodUnit { g, ml, item, serving }

enum ObservationQualifier {
  reported,
  reportedZero,
  belowDetection,
  trace,
  estimated,
  unknown
}

enum DiaryCompleteness {
  unknown,
  partial,
  userDeclaredComplete,
  confirmedNoIntake
}

enum RecordCompleteness { completeForRecord, partial, noData }

final class FoodAmount {
  FoodAmount(String value, this.unit, {this.measureId})
      : value = Exact.parse(value) {
    if (this.value.compareTo(Exact.zero) < 0) {
      throw ArgumentError('Negative quantity');
    }
    if ((unit == FoodUnit.item || unit == FoodUnit.serving) &&
        (measureId?.isEmpty ?? true)) {
      throw ArgumentError('Count/serving needs a measure identity');
    }
  }
  FoodAmount.exact(this.value, this.unit, {this.measureId}) {
    if ((unit == FoodUnit.item || unit == FoodUnit.serving) &&
        (measureId?.isEmpty ?? true)) {
      throw ArgumentError('Count/serving needs a measure identity');
    }
    if (value.compareTo(Exact.zero) < 0) {
      throw ArgumentError('Negative quantity');
    }
  }
  final Exact value;
  final FoodUnit unit;
  final String? measureId;
  Map<String, Object?> toJson() =>
      {'value': value.toJson(), 'unit': unit.name, 'measureId': measureId};
  factory FoodAmount.fromJson(Map<String, Object?> j) => FoodAmount.exact(
      Exact.fromJson(Map<String, Object?>.from(j['value']! as Map)),
      FoodUnit.values.byName(j['unit']! as String),
      measureId: j['measureId'] as String?);
}

/// Whether [a] and [b] share a unit and measure identity, so their values can be
/// ratioed without any food-specific conversion.
bool sameDimension(FoodAmount a, FoodAmount b) =>
    a.unit == b.unit && a.measureId == b.measureId;

/// Exact factors between unit names of one physical quantity, canonicalised to
/// grams for mass and kilojoules for energy.
///
/// Returns `null` when the names are not measures of the same quantity, so an
/// unsupported or unknown unit is never converted silently. `mcg` and `ug` are
/// accepted spellings of `µg` because imported labels use all three. The energy
/// relation is the declared `1 kcal = 4.184 kJ` conversion, not a measurement.
Exact? nutrientUnitFactor(String from, String to) {
  const mass = <String, String>{
    'kg': '1000',
    'g': '1',
    'mg': '0.001',
    'µg': '0.000001',
    // The micro sign and the Greek mu are different code points; imported
    // labels use both, so both spellings name the same mass unit.
    'μg': '0.000001',
    'ug': '0.000001',
    'mcg': '0.000001',
  };
  const energy = <String, String>{'kJ': '1', 'kcal': '4.184'};
  final fromMass = mass[from];
  final toMass = mass[to];
  if (fromMass != null && toMass != null) {
    return Exact.parse(fromMass) / Exact.parse(toMass);
  }
  final fromEnergy = energy[from];
  final toEnergy = energy[to];
  if (fromEnergy != null && toEnergy != null) {
    return Exact.parse(fromEnergy) / Exact.parse(toEnergy);
  }
  return null;
}

final class QuantityConversion {
  QuantityConversion(
      {required this.from, required this.to, required this.source}) {
    if (!from.value.positive || !to.value.positive || source.isEmpty) {
      throw ArgumentError('Invalid conversion');
    }
  }
  final FoodAmount from, to;
  final String source;
}

/// Returns a same-dimension ratio or follows one explicit food-specific conversion.
/// A conversion supplied for one food must never be reused as universal density.
///
/// Two conversions that both apply but disagree would make the result depend on
/// list order, so conflicting conversions are an error rather than a silent
/// first match. The caller must ask for clarification instead.
Exact quantityRatio(
    FoodAmount amount, FoodAmount basis, List<QuantityConversion> conversions) {
  if (!basis.value.positive) throw ArgumentError('Basis must be positive');
  if (sameDimension(amount, basis)) return amount.value / basis.value;
  final ratios = <Exact>{};
  for (final c in conversions) {
    if (sameDimension(amount, c.from) && sameDimension(basis, c.to)) {
      ratios.add(amount.value / c.from.value * c.to.value / basis.value);
    } else if (sameDimension(amount, c.to) && sameDimension(basis, c.from)) {
      ratios.add(amount.value / c.to.value * c.from.value / basis.value);
    }
  }
  if (ratios.isEmpty) {
    throw StateError(
        'Quantity needs a food-specific conversion or clarification');
  }
  if (ratios.length > 1) {
    throw StateError('Conflicting food-specific conversions');
  }
  return ratios.single;
}

/// Definition identifiers this build understands. They are code constants, not
/// a dataset: an import adapter that maps a source's wording must produce one of
/// these values, and an unrecognised definition is preserved but never merged
/// with a different one.
abstract final class NutrientDefinitions {
  /// EU available carbohydrate, which includes polyols and excludes fibre.
  static const euAvailableCarbohydrate = 'eu_available_including_polyols';

  /// US total carbohydrate, which includes fibre.
  static const usTotalCarbohydrate = 'us_total_including_fibre';

  /// Energy as declared by the source, in whichever unit it printed.
  static const declaredEnergy = 'declared_energy';

  /// Vitamin A expressed as retinol equivalents: retinoids plus the
  /// provitamin A carotenoids converted to their retinol equivalent.
  static const retinolEquivalents = 'retinol_equivalents';
}

/// Nutrient identity includes its definition, substance form and intake scope.
/// Separate total/free sugars or EU/US carbohydrate cannot accidentally combine.
final class NutrientIdentity {
  const NutrientIdentity(this.id, this.unit, this.definition,
      {this.scope = 'food'});
  final String id, unit, definition, scope;

  /// Unambiguous identity string. Every free-form field is length-prefixed so a
  /// delimiter inside an id or definition cannot make two identities collide.
  String get key => '${id.length}:$id|${unit.length}:$unit|'
      '${definition.length}:$definition|$scope';
  Map<String, Object?> toJson() =>
      {'id': id, 'unit': unit, 'definition': definition, 'scope': scope};
  factory NutrientIdentity.fromJson(Map<String, Object?> j) => NutrientIdentity(
      j['id']! as String, j['unit']! as String, j['definition']! as String,
      scope: j['scope']! as String);
}

/// An interval the source itself documented for one observation, with the scope
/// it applies to and the method that produced it.
///
/// Bounds are exact values in the owning observation's nutrient unit and on its
/// basis; an inclusive flag is meaningful only for a bound that exists. This is
/// source metadata, not a statement about actual intake: the engine never turns
/// a supplied interval into an intake bound, a confidence interval, or a day
/// total. A source that documents no interval leaves it absent rather than
/// inventing one.
final class SourceInterval {
  SourceInterval(
      {this.lower,
      this.upper,
      required this.lowerInclusive,
      required this.upperInclusive,
      required this.scope,
      required this.method}) {
    final lowerBound = lower;
    final upperBound = upper;
    if (lowerBound == null && upperBound == null) {
      throw ArgumentError('Interval needs at least one bound');
    }
    if ((lowerBound != null && lowerBound.compareTo(Exact.zero) < 0) ||
        (upperBound != null && upperBound.compareTo(Exact.zero) < 0)) {
      throw ArgumentError('Negative interval bound');
    }
    if (lowerBound != null && upperBound != null) {
      final order = lowerBound.compareTo(upperBound);
      if (order > 0) {
        throw ArgumentError('Lower bound exceeds upper bound');
      }
      // Equal bounds bound a single value, which is only non-empty when both
      // sides include it.
      if (order == 0 && !(lowerInclusive && upperInclusive)) {
        throw ArgumentError('Empty interval');
      }
    }
    if (lowerBound == null && lowerInclusive) {
      throw ArgumentError('Lower inclusion without a lower bound');
    }
    if (upperBound == null && upperInclusive) {
      throw ArgumentError('Upper inclusion without an upper bound');
    }
    if (scope.trim().isEmpty || method.trim().isEmpty) {
      throw ArgumentError('Interval needs a documented scope and method');
    }
  }
  final Exact? lower, upper;
  final bool lowerInclusive, upperInclusive;
  final String scope, method;

  Map<String, Object?> toJson() => {
        'lower': lower?.toJson(),
        'upper': upper?.toJson(),
        'lowerInclusive': lowerInclusive,
        'upperInclusive': upperInclusive,
        'scope': scope,
        'method': method
      };
  factory SourceInterval.fromJson(Map<String, Object?> j) => SourceInterval(
      lower: j['lower'] == null
          ? null
          : Exact.fromJson(Map<String, Object?>.from(j['lower']! as Map)),
      upper: j['upper'] == null
          ? null
          : Exact.fromJson(Map<String, Object?>.from(j['upper']! as Map)),
      lowerInclusive: j['lowerInclusive']! as bool,
      upperInclusive: j['upperInclusive']! as bool,
      scope: j['scope']! as String,
      method: j['method']! as String);
}

final RegExp _isoCalendarDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Whether [value] is a real calendar date in ISO 8601 `YYYY-MM-DD` form.
///
/// The date is evidence metadata about the source, so it stays the printed
/// calendar value instead of being converted through a timestamp. Out-of-range
/// days are rejected rather than rolled over the way [DateTime.parse] does.
bool _isIsoCalendarDate(String value) {
  if (!_isoCalendarDate.hasMatch(value)) return false;
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  if (month < 1 || month > 12 || day < 1) return false;
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day;
}

final class NutrientObservation {
  NutrientObservation(
      {required this.nutrient,
      required this.basis,
      required this.qualifier,
      required this.sourceId,
      required this.sourceVersion,
      required this.origin,
      String? amount,
      Exact? exactAmount,
      this.suppliedInterval,
      this.evidenceDate})
      : amount = exactAmount ?? (amount == null ? null : Exact.parse(amount)) {
    if (this.amount != null && this.amount!.compareTo(Exact.zero) < 0) {
      throw ArgumentError('Negative nutrient');
    }
    if ((qualifier == ObservationQualifier.reported ||
            qualifier == ObservationQualifier.reportedZero ||
            qualifier == ObservationQualifier.estimated) &&
        this.amount == null) {
      throw ArgumentError('Qualifier requires an amount');
    }
    if (qualifier == ObservationQualifier.reportedZero &&
        this.amount != Exact.zero) {
      throw ArgumentError('Reported zero must be zero');
    }
    if ((qualifier == ObservationQualifier.unknown ||
            qualifier == ObservationQualifier.trace ||
            qualifier == ObservationQualifier.belowDetection) &&
        this.amount != null) {
      throw ArgumentError('Non-numeric qualifier cannot imply an exact amount');
    }
    if (!basis.value.positive ||
        sourceId.isEmpty ||
        sourceVersion.isEmpty ||
        origin.isEmpty) {
      throw ArgumentError('Missing basis/provenance');
    }
    final suppliedDate = evidenceDate;
    if (suppliedDate != null && !_isIsoCalendarDate(suppliedDate)) {
      throw ArgumentError('Evidence date must be an ISO 8601 calendar date');
    }
  }
  final NutrientIdentity nutrient;
  final FoodAmount basis;
  final ObservationQualifier qualifier;
  final String sourceId, sourceVersion, origin;
  final Exact? amount;

  /// The interval the source documented for [amount], in this observation's
  /// nutrient unit and on its basis. Absent when the source documented none.
  final SourceInterval? suppliedInterval;

  /// The source's printed evidence date as `YYYY-MM-DD`, when it gives one.
  final String? evidenceDate;
  Map<String, Object?> toJson() => {
        'nutrient': nutrient.toJson(),
        'basis': basis.toJson(),
        'qualifier': qualifier.name,
        'sourceId': sourceId,
        'sourceVersion': sourceVersion,
        'origin': origin,
        'amount': amount?.toJson(),
        // Metadata keys are omitted when absent so an observation recorded
        // before these fields existed encodes exactly as it did then.
        if (suppliedInterval != null)
          'suppliedInterval': suppliedInterval!.toJson(),
        if (evidenceDate != null) 'evidenceDate': evidenceDate
      };
  factory NutrientObservation.fromJson(Map<String, Object?> j) {
    final a = j['amount'];
    final interval = j['suppliedInterval'];
    final result = NutrientObservation(
        nutrient: NutrientIdentity.fromJson(
            Map<String, Object?>.from(j['nutrient']! as Map)),
        basis:
            FoodAmount.fromJson(Map<String, Object?>.from(j['basis']! as Map)),
        qualifier:
            ObservationQualifier.values.byName(j['qualifier']! as String),
        sourceId: j['sourceId']! as String,
        sourceVersion: j['sourceVersion']! as String,
        origin: j['origin']! as String,
        exactAmount: a == null
            ? null
            : Exact.fromJson(Map<String, Object?>.from(a as Map)),
        suppliedInterval: interval == null
            ? null
            : SourceInterval.fromJson(
                Map<String, Object?>.from(interval as Map)),
        evidenceDate: j['evidenceDate'] as String?);
    return result;
  }
}

final class ObservedFood {
  ObservedFood(
      {required this.id,
      required this.quantity,
      required List<NutrientObservation> observations,
      List<QuantityConversion> conversions = const []})
      : observations = List.unmodifiable(observations),
        conversions = List.unmodifiable(conversions) {
    final identities = this.observations.map((o) => o.nutrient.key).toSet();
    if (identities.length != this.observations.length) {
      throw ArgumentError('Duplicate nutrient observations');
    }
  }
  final String id;
  final FoodAmount quantity;
  final List<NutrientObservation> observations;
  final List<QuantityConversion> conversions;
}

/// One source-supplied interval on its original observation and food basis.
///
/// This is evidence about that source record, not an interval for actual
/// intake or an automatically aggregated daily bound.
final class RecordedSourceInterval {
  const RecordedSourceInterval(this.foodId, this.observation);
  final String foodId;
  final NutrientObservation observation;
}

final class RecordedSummary {
  RecordedSummary(
      {required this.nutrient,
      required this.recordedSum,
      required this.known,
      required List<String> missing,
      required this.estimated,
      required this.diaryCompleteness,
      List<String> needsClarification = const [],
      List<RecordedSourceInterval> sourceIntervals = const [],
      this.estimatedContribution})
      : missing = List.unmodifiable(missing),
        needsClarification = List.unmodifiable(needsClarification),
        sourceIntervals = sourceIntervals.isEmpty
            ? const []
            : List.unmodifiable(sourceIntervals);
  final NutrientIdentity nutrient;
  final Exact? recordedSum;

  /// Sum of the numeric contributions that came from an estimated observation,
  /// or `null` when none contributed. Informational only: any estimate blocks an
  /// unqualified comparison.
  final Exact? estimatedContribution;
  final int known, estimated;
  final List<String> missing;

  /// Foods whose observation exists but cannot be placed on [nutrient]'s basis
  /// without a food-specific conversion or a supported unit conversion.
  final List<String> needsClarification;
  final DiaryCompleteness diaryCompleteness;

  /// Source intervals with their original units, bases and provenance.
  /// They are not summed or interpreted as bounds on actual intake.
  final List<RecordedSourceInterval> sourceIntervals;

  /// Completeness of the record itself. Diary completeness is separate so a
  /// declared no-intake day is not read as "no data": nothing was recorded
  /// because nothing was eaten, which is a complete record of that day.
  RecordCompleteness get completeness {
    if (known > 0) {
      return missing.isEmpty && needsClarification.isEmpty
          ? RecordCompleteness.completeForRecord
          : RecordCompleteness.partial;
    }
    if (missing.isEmpty &&
        needsClarification.isEmpty &&
        diaryCompleteness == DiaryCompleteness.confirmedNoIntake) {
      return RecordCompleteness.completeForRecord;
    }
    return RecordCompleteness.noData;
  }

  /// Whether an unqualified recorded comparison is allowed: nothing decisive is
  /// missing, clarified or estimated, and the diary itself was declared.
  ///
  /// A declared no-intake day is a recorded zero, not missing data, so it may be
  /// compared against a reference; [recordedSum] stays absent because no
  /// observation produced it.
  bool get permitsComparison {
    if (missing.isNotEmpty || needsClarification.isNotEmpty || estimated > 0) {
      return false;
    }
    if (diaryCompleteness != DiaryCompleteness.userDeclaredComplete &&
        diaryCompleteness != DiaryCompleteness.confirmedNoIntake) {
      return false;
    }
    return known > 0 || diaryCompleteness == DiaryCompleteness.confirmedNoIntake;
  }
}

final class FoodCalculationService {
  const FoodCalculationService();

  /// Totals [foods] for [nutrient] on the foods' own quantities.
  ///
  /// Observations match on nutrient id, definition and scope; their unit may
  /// differ when an exact unit factor exists (for example `µg` against `mg`).
  /// A food whose quantity or basis cannot be placed on this nutrient's
  /// dimension is reported through [RecordedSummary.needsClarification] instead
  /// of aborting the whole day: an unresolved food never becomes a number.
  RecordedSummary summarize(NutrientIdentity nutrient, List<ObservedFood> foods,
      DiaryCompleteness diary) {
    Exact? total;
    Exact? estimatedTotal;
    var known = 0, estimated = 0;
    final missing = <String>[];
    final clarify = <String>[];
    List<RecordedSourceInterval>? sourceIntervals;
    for (final food in foods) {
      final candidates = food.observations
          .where((o) =>
              o.nutrient.id == nutrient.id &&
              o.nutrient.definition == nutrient.definition &&
              o.nutrient.scope == nutrient.scope)
          .toList();
      for (final observation in candidates) {
        if (observation.suppliedInterval != null) {
          (sourceIntervals ??= []).add(RecordedSourceInterval(food.id, observation));
        }
      }
      if (candidates.isEmpty) {
        missing.add(food.id);
        continue;
      }
      if (candidates.length > 1) {
        // Two representations of one nutrient (for example the same amount in g
        // and mg) would double count. Ask which one is authoritative.
        clarify.add(food.id);
        continue;
      }
      final o = candidates.single;
      if (o.amount == null) {
        missing.add(food.id);
        continue;
      }
      final unitFactor = o.nutrient.unit == nutrient.unit
          ? Exact.one
          : nutrientUnitFactor(o.nutrient.unit, nutrient.unit);
      if (unitFactor == null) {
        clarify.add(food.id);
        continue;
      }
      Exact contribution;
      try {
        contribution = o.amount! *
            unitFactor *
            quantityRatio(food.quantity, o.basis, food.conversions);
      } on StateError {
        clarify.add(food.id);
        continue;
      }
      total = (total ?? Exact.zero) + contribution;
      known++;
      if (o.qualifier == ObservationQualifier.estimated) {
        estimated++;
        estimatedTotal = (estimatedTotal ?? Exact.zero) + contribution;
      }
    }
    return RecordedSummary(
        nutrient: nutrient,
        recordedSum: total,
        known: known,
        missing: missing,
        needsClarification: clarify,
        sourceIntervals: sourceIntervals ?? const [],
        estimated: estimated,
        estimatedContribution: estimatedTotal,
        diaryCompleteness: diary);
  }
}

enum ReferenceKind {
  pri,
  ai,
  ar,
  riRange,
  maximumGuidance,
  ul,
  safeIntakeLevel,
  userTarget
}

enum ComparisonStatus {
  recordedBelowReference,
  recordedAtOrAboveReference,
  recordedWithinRange,
  recordedOutsideRange,
  recordedAboveGuidance,
  recordedNotAboveGuidance,

  /// Reported items alone exceed a maximum; the total remains incomplete.
  recordedItemsAlreadyExceedGuidance,
  insufficientData,
  referenceNotApplicable
}

final class ReferencePolicy {
  ReferencePolicy(
      {required this.id,
      required this.nutrient,
      required this.kind,
      required this.source,
      required this.edition,
      required this.temporalBasis,
      required this.approved,
      required this.populationMatches,
      this.lower,
      this.upper});
  final String id, source, edition, temporalBasis;
  final NutrientIdentity nutrient;
  final ReferenceKind kind;
  final bool approved, populationMatches;
  final Exact? lower, upper;
}

final class ReferenceComparisonService {
  const ReferenceComparisonService();

  /// Compares a recorded summary with [reference] on the reference's own unit.
  ///
  /// The nutrient identity must match id, definition and scope; a different unit
  /// is accepted only when an exact unit factor exists. A declared no-intake day
  /// is a recorded zero; anything missing, clarified or estimated on a decisive
  /// nutrient stays insufficient data. The result never rewrites a record.
  ComparisonStatus compare(RecordedSummary summary, ReferencePolicy reference,
      {String temporalBasis = 'day'}) {
    final identityMatches = summary.nutrient.id == reference.nutrient.id &&
        summary.nutrient.definition == reference.nutrient.definition &&
        summary.nutrient.scope == reference.nutrient.scope;
    final Exact? unitFactor = !identityMatches
        ? null
        : summary.nutrient.unit == reference.nutrient.unit
            ? Exact.one
            : nutrientUnitFactor(
                summary.nutrient.unit, reference.nutrient.unit);
    if (!reference.approved ||
        !reference.populationMatches ||
        !identityMatches ||
        temporalBasis != reference.temporalBasis) {
      return ComparisonStatus.referenceNotApplicable;
    }
    if (unitFactor == null) {
      return ComparisonStatus.referenceNotApplicable;
    }
    final declaredZero = summary.known == 0 &&
        summary.diaryCompleteness == DiaryCompleteness.confirmedNoIntake;
    final raw = summary.recordedSum ?? (declaredZero ? Exact.zero : null);
    final value = raw == null ? null : raw * unitFactor;
    if (reference.kind == ReferenceKind.maximumGuidance ||
        reference.kind == ReferenceKind.ul) {
      final upper = reference.upper;
      if (upper == null || upper.compareTo(Exact.zero) < 0) {
        return ComparisonStatus.referenceNotApplicable;
      }
      if (!summary.permitsComparison) {
        if (summary.known > 0 &&
            summary.estimated == 0 &&
            value != null &&
            value.compareTo(upper) > 0) {
          return ComparisonStatus.recordedItemsAlreadyExceedGuidance;
        }
        return ComparisonStatus.insufficientData;
      }
      if (value == null) return ComparisonStatus.insufficientData;
      return value.compareTo(upper) > 0
          ? ComparisonStatus.recordedAboveGuidance
          : ComparisonStatus.recordedNotAboveGuidance;
    }
    if (reference.kind == ReferenceKind.safeIntakeLevel ||
        reference.kind == ReferenceKind.ar) {
      return ComparisonStatus.referenceNotApplicable;
    }
    if (reference.kind == ReferenceKind.riRange) {
      final lower = reference.lower;
      final upper = reference.upper;
      if (lower == null ||
          upper == null ||
          lower.compareTo(Exact.zero) < 0 ||
          lower.compareTo(upper) > 0) {
        return ComparisonStatus.referenceNotApplicable;
      }
      if (!summary.permitsComparison || value == null) {
        return ComparisonStatus.insufficientData;
      }
      return (value.compareTo(lower) >= 0 && value.compareTo(upper) <= 0)
          ? ComparisonStatus.recordedWithinRange
          : ComparisonStatus.recordedOutsideRange;
    }
    final lower = reference.lower;
    if (lower == null || lower.compareTo(Exact.zero) < 0) {
      return ComparisonStatus.referenceNotApplicable;
    }
    if (!summary.permitsComparison || value == null) {
      return ComparisonStatus.insufficientData;
    }
    return value.compareTo(lower) < 0
        ? ComparisonStatus.recordedBelowReference
        : ComparisonStatus.recordedAtOrAboveReference;
  }
}
