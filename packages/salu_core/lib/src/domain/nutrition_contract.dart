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
Exact quantityRatio(
    FoodAmount amount, FoodAmount basis, List<QuantityConversion> conversions) {
  if (!basis.value.positive) throw ArgumentError('Basis must be positive');
  bool compatible(FoodAmount a, FoodAmount b) =>
      a.unit == b.unit && a.measureId == b.measureId;
  if (compatible(amount, basis)) return amount.value / basis.value;
  for (final c in conversions) {
    if (compatible(amount, c.from) && compatible(basis, c.to)) {
      return amount.value / c.from.value * c.to.value / basis.value;
    }
    if (compatible(amount, c.to) && compatible(basis, c.from)) {
      return amount.value / c.to.value * c.from.value / basis.value;
    }
  }
  throw StateError(
      'Quantity needs a food-specific conversion or clarification');
}

/// Nutrient identity includes its definition, substance form and intake scope.
/// Separate total/free sugars or EU/US carbohydrate cannot accidentally combine.
final class NutrientIdentity {
  const NutrientIdentity(this.id, this.unit, this.definition,
      {this.scope = 'food'});
  final String id, unit, definition, scope;
  String get key => '$id|$unit|$definition|$scope';
  Map<String, Object?> toJson() =>
      {'id': id, 'unit': unit, 'definition': definition, 'scope': scope};
  factory NutrientIdentity.fromJson(Map<String, Object?> j) => NutrientIdentity(
      j['id']! as String, j['unit']! as String, j['definition']! as String,
      scope: j['scope']! as String);
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
      Exact? exactAmount})
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
    if (!basis.value.positive || sourceId.isEmpty || sourceVersion.isEmpty) {
      throw ArgumentError('Missing basis/provenance');
    }
  }
  final NutrientIdentity nutrient;
  final FoodAmount basis;
  final ObservationQualifier qualifier;
  final String sourceId, sourceVersion, origin;
  final Exact? amount;
  Map<String, Object?> toJson() => {
        'nutrient': nutrient.toJson(),
        'basis': basis.toJson(),
        'qualifier': qualifier.name,
        'sourceId': sourceId,
        'sourceVersion': sourceVersion,
        'origin': origin,
        'amount': amount?.toJson()
      };
  factory NutrientObservation.fromJson(Map<String, Object?> j) {
    final a = j['amount'];
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
            : Exact.fromJson(Map<String, Object?>.from(a as Map)));
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

final class RecordedSummary {
  RecordedSummary(
      {required this.nutrient,
      required this.recordedSum,
      required this.known,
      required List<String> missing,
      required this.estimated,
      required this.diaryCompleteness})
      : missing = List.unmodifiable(missing);
  final NutrientIdentity nutrient;
  final Exact? recordedSum;
  final int known, estimated;
  final List<String> missing;
  final DiaryCompleteness diaryCompleteness;
  RecordCompleteness get completeness => known == 0
      ? RecordCompleteness.noData
      : missing.isEmpty
          ? RecordCompleteness.completeForRecord
          : RecordCompleteness.partial;
  bool get permitsComparison =>
      missing.isEmpty &&
      known > 0 &&
      estimated == 0 &&
      (diaryCompleteness == DiaryCompleteness.userDeclaredComplete ||
          diaryCompleteness == DiaryCompleteness.confirmedNoIntake);
}

final class FoodCalculationService {
  const FoodCalculationService();
  RecordedSummary summarize(NutrientIdentity nutrient, List<ObservedFood> foods,
      DiaryCompleteness diary) {
    Exact? total;
    var known = 0, estimated = 0;
    final missing = <String>[];
    for (final food in foods) {
      final matches =
          food.observations.where((o) => o.nutrient.key == nutrient.key);
      final observation = matches.isEmpty ? null : matches.single;
      if (observation?.amount == null) {
        missing.add(food.id);
        continue;
      }
      final o = observation!;
      final contribution =
          o.amount! * quantityRatio(food.quantity, o.basis, food.conversions);
      total = (total ?? Exact.zero) + contribution;
      known++;
      if (o.qualifier == ObservationQualifier.estimated) estimated++;
    }
    return RecordedSummary(
        nutrient: nutrient,
        recordedSum: total,
        known: known,
        missing: missing,
        estimated: estimated,
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
  ComparisonStatus compare(RecordedSummary summary, ReferencePolicy reference,
      {String temporalBasis = 'day'}) {
    if (!reference.approved ||
        !reference.populationMatches ||
        summary.nutrient.key != reference.nutrient.key ||
        temporalBasis != reference.temporalBasis) {
      return ComparisonStatus.referenceNotApplicable;
    }
    if (reference.kind == ReferenceKind.maximumGuidance ||
        reference.kind == ReferenceKind.ul) {
      if (reference.upper == null ||
          reference.upper!.compareTo(Exact.zero) < 0) {
        return ComparisonStatus.referenceNotApplicable;
      }
      if (!summary.permitsComparison) {
        if (summary.known > 0 &&
            summary.estimated == 0 &&
            summary.recordedSum != null &&
            summary.recordedSum!.compareTo(reference.upper!) > 0) {
          return ComparisonStatus.recordedItemsAlreadyExceedGuidance;
        }
        return ComparisonStatus.insufficientData;
      }
      final value = summary.recordedSum!;
      return value.compareTo(reference.upper!) > 0
          ? ComparisonStatus.recordedAboveGuidance
          : ComparisonStatus.recordedNotAboveGuidance;
    }
    if (reference.kind == ReferenceKind.safeIntakeLevel ||
        reference.kind == ReferenceKind.ar) {
      return ComparisonStatus.referenceNotApplicable;
    }
    if (reference.kind == ReferenceKind.riRange) {
      if (reference.lower == null ||
          reference.upper == null ||
          reference.lower!.compareTo(Exact.zero) < 0 ||
          reference.lower!.compareTo(reference.upper!) > 0) {
        return ComparisonStatus.referenceNotApplicable;
      }
      if (!summary.permitsComparison) return ComparisonStatus.insufficientData;
      final value = summary.recordedSum!;
      return (value.compareTo(reference.lower!) >= 0 &&
              value.compareTo(reference.upper!) <= 0)
          ? ComparisonStatus.recordedWithinRange
          : ComparisonStatus.recordedOutsideRange;
    }
    if (reference.lower == null || reference.lower!.compareTo(Exact.zero) < 0) {
      return ComparisonStatus.referenceNotApplicable;
    }
    if (!summary.permitsComparison) return ComparisonStatus.insufficientData;
    final value = summary.recordedSum!;
    return value.compareTo(reference.lower!) < 0
        ? ComparisonStatus.recordedBelowReference
        : ComparisonStatus.recordedAtOrAboveReference;
  }
}
