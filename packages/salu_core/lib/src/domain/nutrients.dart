/// Nutrient identities, values with an explicit epistemic state, and arithmetic
/// that never turns "unknown" into a number.
///
/// The governing rule from the product spec: unknown, measured zero, trace,
/// and estimated are four different things. Arithmetic preserves that.
library;

import 'dart:collection';
import 'nutrition_contract.dart';

/// A nutrient the app can store, total, and display.
///
/// [wire] is the stable identifier used in JSON payloads, database columns, and
/// export archives. Never rename it; add a new member instead.
enum NutrientKey {
  energyKcal('energy_kcal', 'kcal'),
  energyKj('energy_kj', 'kJ'),
  freeSugarsG('free_sugars_g', 'g'),
  ironMg('iron_mg', 'mg'),
  iodineUg('iodine_ug', 'µg'),
  calciumMg('calcium_mg', 'mg'),
  vitaminCMg('vitamin_c_mg', 'mg'),
  vitaminDUg('vitamin_d_ug', 'µg'),
  proteinG('protein_g', 'g'),
  fatG('fat_g', 'g'),
  saturatedFatG('saturated_fat_g', 'g'),
  carbohydrateG('carbohydrate_g', 'g'),
  fiberG('fiber_g', 'g'),
  sugarsG('sugars_g', 'g'),
  sodiumMg('sodium_mg', 'mg');

  const NutrientKey(this.wire, this.unit);

  /// Stable wire identifier.
  final String wire;

  /// Display unit for [wire] values.
  final String unit;

  /// Resolves a wire identifier, or `null` when unknown to this build.
  static NutrientKey? fromWire(String wire) {
    for (final key in NutrientKey.values) {
      if (key.wire == wire) return key;
    }
    return null;
  }
}

/// The epistemic state attached to a nutrient number.
sealed class NutrientValue {
  const NutrientValue();

  /// A value that is known to be unmeasured.
  static const NutrientValue unknown = NutrientUnknown();

  /// A value that is known to be below the reporting threshold.
  static const NutrientValue trace = NutrientTrace();

  /// The number to use in arithmetic, or `null` when no number may be inferred.
  double? get numericValue;

  /// Whether this value carries a usable number (including an explicit zero).
  bool get isKnown => numericValue != null;
  Exact? get exactValue =>
      numericValue == null ? null : Exact.parse(numericValue!.toString());

  /// Stable JSON form. Round-trips through [NutrientValue.fromJson].
  Map<String, Object?> toJson();

  /// Reads the form produced by [toJson]. Unknown shapes become
  /// [NutrientUnknown] rather than raising on old or foreign data.
  static NutrientValue fromJson(Object? json) {
    if (json is! Map) return unknown;
    final state = json['state'];
    final value = json['value'];
    final exact = json['exact'] == null
        ? null
        : Exact.fromJson(Map<String, Object?>.from(json['exact'] as Map));
    switch (state) {
      case 'reported':
      case 'reported_zero':
        return value is num
            ? NutrientReported.exact(exact ?? Exact.parse(value.toString()))
            : unknown;
      case 'measured':
        return value is num
            ? NutrientMeasured.exact(exact ?? Exact.parse(value.toString()))
            : NutrientUnknown();
      case 'estimated':
        return value is num
            ? NutrientEstimated.exact(
                exact ?? Exact.parse(value.toString()),
                basis: json['basis'] as String? ?? 'unspecified',
              )
            : NutrientUnknown();
      case 'trace':
        return trace;
      default:
        return unknown;
    }
  }
}

Exact _checkedNutrient(double value) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError('Nutrient must be finite and nonnegative');
  }
  return Exact.parse(value.toString());
}

/// No measurement or estimate exists.
final class NutrientUnknown extends NutrientValue {
  const NutrientUnknown();

  @override
  double? get numericValue => null;

  @override
  Map<String, Object?> toJson() => const {'state': 'unknown'};

  @override
  bool operator ==(Object other) => other is NutrientUnknown;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'NutrientUnknown()';
}

/// An actual measurement, including an explicit measured zero.
final class NutrientMeasured extends NutrientValue {
  /// Creates a measured value. Negative or non-finite input is a programming
  /// error: it cannot describe a nutrient amount.
  NutrientMeasured(double value) : exact = _checkedNutrient(value);
  NutrientMeasured.exact(this.exact) {
    if (exact.compareTo(Exact.zero) < 0) {
      throw ArgumentError('Negative nutrient');
    }
  }
  final Exact exact;
  @override
  Exact get exactValue => exact;

  /// Measured amount in [NutrientKey.unit].
  double get value => exact.toDouble();

  @override
  double? get numericValue => value;

  @override
  Map<String, Object?> toJson() =>
      {'state': 'measured', 'value': value, 'exact': exact.toJson()};

  @override
  bool operator ==(Object other) =>
      other is NutrientMeasured && other.exact == exact;

  @override
  int get hashCode => exact.hashCode;

  @override
  String toString() => 'NutrientMeasured($value)';
}

/// Label/user-reported amount. A printed zero is not analytical absence.
final class NutrientReported extends NutrientValue {
  NutrientReported(double value) : exact = _checkedNutrient(value);
  NutrientReported.exact(this.exact) {
    if (exact.compareTo(Exact.zero) < 0) {
      throw ArgumentError('Negative nutrient');
    }
  }
  final Exact exact;
  double get value => exact.toDouble();
  @override
  Exact get exactValue => exact;

  @override
  double get numericValue => value;
  @override
  Map<String, Object?> toJson() => {
        'state': value == 0 ? 'reported_zero' : 'reported',
        'value': value,
        'exact': exact.toJson()
      };
  @override
  bool operator ==(Object other) =>
      other is NutrientReported && other.exact == exact;
  @override
  int get hashCode => Object.hash('reported', exact);
}

/// Below the reporting threshold: no exact numeric contribution is known; not the
/// same as "measured zero", and is surfaced in the UI as such.
final class NutrientTrace extends NutrientValue {
  const NutrientTrace();

  @override
  double? get numericValue => null;

  @override
  Map<String, Object?> toJson() => const {'state': 'trace'};

  @override
  bool operator ==(Object other) => other is NutrientTrace;

  @override
  int get hashCode => 1;

  @override
  String toString() => 'NutrientTrace()';
}

/// A model- or heuristic-derived number. Carries the basis so the UI, export,
/// and audit trail can distinguish it from a measured value.
final class NutrientEstimated extends NutrientValue {
  /// Creates an estimated value; [basis] names where the estimate came from.
  NutrientEstimated(double value, {required this.basis})
      : exact = _checkedNutrient(value);
  NutrientEstimated.exact(this.exact, {required this.basis}) {
    if (exact.compareTo(Exact.zero) < 0) {
      throw ArgumentError('Negative nutrient');
    }
  }
  final Exact exact;
  @override
  Exact get exactValue => exact;

  /// Estimated amount in [NutrientKey.unit].
  double get value => exact.toDouble();

  /// Short provenance label, e.g. `photo-inference` or `recipe-yield`.
  final String basis;

  @override
  double? get numericValue => value;

  @override
  Map<String, Object?> toJson() => {
        'state': 'estimated',
        'value': value,
        'exact': exact.toJson(),
        'basis': basis,
      };

  @override
  bool operator ==(Object other) =>
      other is NutrientEstimated &&
      other.exact == exact &&
      other.basis == basis;

  @override
  int get hashCode => Object.hash(exact, basis);

  @override
  String toString() => 'NutrientEstimated($value, $basis)';
}

/// The result of adding nutrient values for one nutrient.
///
/// [value] sums the known numbers only. [isComplete] is false when any
/// contribution was unknown, which is what display code must reflect instead of
/// pretending a partial total is the whole.
final class NutrientSum {
  /// Creates a sum. Prefer [NutrientProfile.combine] over constructing directly.
  const NutrientSum({
    required this.value,
    required this.isComplete,
    required this.includesTrace,
    required this.includesEstimate,
    this.knownEntries = 0,
    this.exact,
  });

  final Exact? exact;
  Exact get exactValue => exact ?? Exact.parse(value.toString());
  final int knownEntries;
  double? get recordedValue => knownEntries == 0 ? null : value;

  /// Sum of the known contributions.
  final double value;

  /// True when no contribution was unknown.
  final bool isComplete;

  /// True when at least one contribution was a trace value.
  final bool includesTrace;

  /// True when at least one contribution was an estimate.
  final bool includesEstimate;

  /// Adds one more contribution.
  NutrientSum adding(NutrientValue next) {
    final numeric = next.numericValue;
    return NutrientSum(
      value: (exactValue + (next.exactValue ?? Exact.zero)).toDouble(),
      exact: exactValue + (next.exactValue ?? Exact.zero),
      knownEntries: knownEntries + (numeric == null ? 0 : 1),
      isComplete: isComplete && next.isKnown,
      includesTrace: includesTrace || next is NutrientTrace,
      includesEstimate: includesEstimate || next is NutrientEstimated,
    );
  }

  /// The additive identity: nothing contributed, and nothing is missing.
  static const NutrientSum zero = NutrientSum(
    value: 0,
    isComplete: true,
    includesTrace: false,
    includesEstimate: false,
  );

  /// No data at all: shows as unknown coverage rather than a verified zero.
  static const NutrientSum noData = NutrientSum(
    value: 0,
    isComplete: false,
    includesTrace: false,
    includesEstimate: false,
  );

  @override
  bool operator ==(Object other) =>
      other is NutrientSum &&
      other.exactValue == exactValue &&
      other.knownEntries == knownEntries &&
      other.isComplete == isComplete &&
      other.includesTrace == includesTrace &&
      other.includesEstimate == includesEstimate;

  @override
  int get hashCode => Object.hash(
      exactValue, knownEntries, isComplete, includesTrace, includesEstimate);

  @override
  String toString() =>
      'NutrientSum($value, complete: $isComplete, trace: $includesTrace, '
      'estimate: $includesEstimate)';
}

/// A set of nutrient values for a known quantity of food.
///
/// A profile is always expressed against a stated basis: per 100 g for
/// catalogue foods, as-consumed for logged items. Missing keys mean unknown;
/// they are never zero.
final class NutrientProfile {
  /// Wraps [values] immutably. Absent keys read as [NutrientUnknown].
  NutrientProfile(Map<NutrientKey, NutrientValue> values)
      : _values = Map<NutrientKey, NutrientValue>.unmodifiable(values);

  /// An empty profile: every nutrient unknown.
  const NutrientProfile.empty() : _values = const {};

  /// Reads [json] produced by [toJson], keeping unrecognised keys out.
  factory NutrientProfile.fromJson(Map<String, Object?> json) {
    final values = <NutrientKey, NutrientValue>{};
    for (final entry in json.entries) {
      final key = NutrientKey.fromWire(entry.key);
      if (key == null) continue;
      values[key] = NutrientValue.fromJson(entry.value);
    }
    return NutrientProfile(values);
  }

  final Map<NutrientKey, NutrientValue> _values;

  /// Read-only view of the stored values.
  Map<NutrientKey, NutrientValue> get values => UnmodifiableMapView(_values);

  /// The value for [key]; [NutrientUnknown] when the profile lacks it.
  NutrientValue operator [](NutrientKey key) =>
      _values[key] ?? const NutrientUnknown();

  /// Whether any nutrient carries a known number.
  bool get hasAnyKnownValue => _values.values.any((v) => v.isKnown);

  /// Keys that carry a known number, in enum order.
  Set<NutrientKey> get knownKeys => {
        for (final key in NutrientKey.values)
          if (this[key].isKnown) key,
      };

  /// Scales every measured or estimated value by [factor] (for example
  /// `grams / 100` when [this] is a per-100 g profile).
  ///
  /// Unknowns stay unknown and traces stay traces: scaling cannot manufacture
  /// knowledge about a nutrient that was never measured.
  NutrientProfile scaled(double factor) {
    if (!factor.isFinite || factor < 0) throw ArgumentError('Invalid factor');
    return scaledExact(Exact.parse(factor.toString()));
  }

  NutrientProfile scaledExact(Exact factor) {
    if (factor.compareTo(Exact.zero) < 0) throw ArgumentError('Invalid factor');
    if (factor == Exact.one) return this;
    final scaled = <NutrientKey, NutrientValue>{};
    for (final entry in _values.entries) {
      final value = entry.value;
      switch (value) {
        case NutrientUnknown():
        case NutrientTrace():
          scaled[entry.key] = value;
        case NutrientReported():
          scaled[entry.key] = NutrientReported.exact(value.exact * factor);
        case NutrientMeasured():
          scaled[entry.key] = NutrientMeasured.exact(value.exact * factor);
        case NutrientEstimated():
          scaled[entry.key] = NutrientEstimated.exact(
            value.exact * factor,
            basis: value.basis,
          );
      }
    }
    return NutrientProfile(scaled);
  }

  /// Adds [profiles] per nutrient, reporting completeness alongside the number.
  ///
  /// A nutrient absent from every profile stays unknown rather than showing a
  /// complete zero, because "nothing was recorded" and "nothing was consumed"
  /// are different claims.
  static Map<NutrientKey, NutrientSum> combine(
    Iterable<NutrientProfile> profiles,
  ) {
    final list = profiles.toList(growable: false);
    final keys = list.expand((p) => p.values.keys).toSet();
    return {
      for (final key in keys)
        key: list.fold<NutrientSum>(
            NutrientSum.zero, (sum, p) => sum.adding(p[key])),
    };
  }

  /// JSON form keyed by [NutrientKey.wire], suitable for a database column.
  Map<String, Object?> toJson() => {
        for (final entry in _values.entries)
          entry.key.wire: entry.value.toJson(),
      };

  @override
  String toString() => 'NutrientProfile(${toJson()})';
}
