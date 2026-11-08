/// Quantities and their conversion to the canonical gram basis.
///
/// The app stores mass in grams. Volume needs a food-specific density and
/// piece counts need a recorded portion weight; without them the quantity is
/// unresolvable, and the caller must ask rather than guess.
library;

/// How a user expressed an amount.
enum QuantityKind { mass, volume, piece }

/// An amount as the user expressed it.
sealed class Quantity {
  const Quantity();

  /// The dimension of this quantity.
  QuantityKind get kind;
}

/// Checks that [value] can describe a physical amount.
double _checked(double value, String name) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError.value(value, name, 'must be finite and >= 0');
  }
  return value;
}

/// A mass, held canonically in grams.
final class MassQuantity extends Quantity {
  MassQuantity(double grams) : grams = _checked(grams, 'grams');

  /// Builds a mass from kilograms.
  factory MassQuantity.kilograms(double kilograms) =>
      MassQuantity(_checked(kilograms, 'kilograms') * 1000);

  /// Mass in grams.
  final double grams;

  @override
  QuantityKind get kind => QuantityKind.mass;

  @override
  bool operator ==(Object other) =>
      other is MassQuantity && other.grams == grams;

  @override
  int get hashCode => grams.hashCode;

  @override
  String toString() => 'MassQuantity(${grams}g)';
}

/// A volume, held in millilitres.
final class VolumeQuantity extends Quantity {
  VolumeQuantity(double millilitres)
      : millilitres = _checked(millilitres, 'millilitres');

  /// Builds a volume from litres.
  factory VolumeQuantity.litres(double litres) =>
      VolumeQuantity(_checked(litres, 'litres') * 1000);

  /// Volume in millilitres.
  final double millilitres;

  @override
  QuantityKind get kind => QuantityKind.volume;

  @override
  bool operator ==(Object other) =>
      other is VolumeQuantity && other.millilitres == millilitres;

  @override
  int get hashCode => millilitres.hashCode;

  @override
  String toString() => 'VolumeQuantity(${millilitres}ml)';
}

/// A count of discrete pieces.
final class PieceQuantity extends Quantity {
  PieceQuantity(double count) : count = _checked(count, 'count');

  /// Number of pieces.
  final double count;

  @override
  QuantityKind get kind => QuantityKind.piece;

  @override
  bool operator ==(Object other) =>
      other is PieceQuantity && other.count == count;

  @override
  int get hashCode => count.hashCode;

  @override
  String toString() => 'PieceQuantity(${count}x)';
}

/// The conversions a specific food declares.
///
/// A food that declares neither conversion can only be logged by mass.
final class PortionDefinition {
  /// Creates a portion definition. Both values are optional and independent.
  const PortionDefinition({
    this.portionGrams,
    this.densityGramsPerMillilitre,
  });

  /// No conversions declared: mass-only food.
  static const PortionDefinition massOnly = PortionDefinition();

  /// Mass of one piece, in grams, when the food declares a piece weight.
  final double? portionGrams;

  /// Density in g/ml, when the food declares one.
  final double? densityGramsPerMillilitre;

  /// Whether a piece count can be converted for this food.
  bool get supportsPieces => portionGrams != null;

  /// Whether a volume can be converted for this food.
  bool get supportsVolume => densityGramsPerMillilitre != null;
}

/// Outcome of converting a [Quantity] into grams.
sealed class QuantityResolution {
  const QuantityResolution();
}

/// The quantity resolved to a mass.
final class ResolvedMass extends QuantityResolution {
  const ResolvedMass(this.grams);

  /// Resolved mass in grams.
  final double grams;

  @override
  bool operator ==(Object other) =>
      other is ResolvedMass && other.grams == grams;

  @override
  int get hashCode => grams.hashCode;

  @override
  String toString() => 'ResolvedMass(${grams}g)';
}

/// The quantity cannot be converted for this food.
///
/// [reason] is user-facing and should say what is missing, e.g. `no portion
/// weight for this food`. Callers must ask for a mass or offer manual entry.
final class UnresolvableQuantity extends QuantityResolution {
  const UnresolvableQuantity(this.reason);

  /// Why the conversion is impossible.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is UnresolvableQuantity && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'UnresolvableQuantity($reason)';
}

/// Converts [quantity] to grams using [portions], without inventing a
/// conversion that the food did not declare.
QuantityResolution resolveQuantity(
  Quantity quantity,
  PortionDefinition portions,
) {
  switch (quantity) {
    case MassQuantity():
      return ResolvedMass(quantity.grams);
    case VolumeQuantity():
      final density = portions.densityGramsPerMillilitre;
      if (density == null) {
        return const UnresolvableQuantity(
          'no density recorded for this food; enter a mass instead',
        );
      }
      if (!density.isFinite || density <= 0) {
        return const UnresolvableQuantity(
          'the recorded density for this food is invalid; enter a mass instead',
        );
      }
      return ResolvedMass(quantity.millilitres * density);
    case PieceQuantity():
      final pieceGrams = portions.portionGrams;
      if (pieceGrams == null) {
        return const UnresolvableQuantity(
          'no portion weight recorded for this food; enter a mass instead',
        );
      }
      if (!pieceGrams.isFinite || pieceGrams <= 0) {
        return const UnresolvableQuantity(
          'the recorded portion weight for this food is invalid; enter a mass '
          'instead',
        );
      }
      return ResolvedMass(quantity.count * pieceGrams);
  }
}
