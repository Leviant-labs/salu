/// The platform health-store boundary (HealthKit / Health Connect).
///
/// Declared as a port so the core carries no plugin dependency and so the app can
/// fake it in tests. Platform symmetry is not assumed: callers must query which
/// types are actually available.
library;

/// Health data the app may read or write.
enum HealthDataType {
  /// Body mass.
  bodyMass,

  /// Dietary energy.
  dietaryEnergy,

  /// Dietary protein.
  dietaryProtein,

  /// Dietary carbohydrate.
  dietaryCarbohydrate,

  /// Dietary fat.
  dietaryFat,

  /// Step count.
  steps,

  /// Active energy burned.
  activeEnergy,

  /// Exercise sessions.
  exerciseSession,
}

/// Result of asking for access.
enum HealthAccess {
  /// Granted for at least the requested types.
  granted,

  /// Denied, or revoked after being granted.
  denied,

  /// Not present on this device or platform.
  unavailable,
}

/// A body-mass reading read from the platform store.
final class WeightSample {
  /// Creates a reading. [externalId] prevents write-back loops.
  const WeightSample({
    required this.kilograms,
    required this.startedAt,
    required this.source,
    required this.externalId,
  });

  /// Mass in kilograms.
  final double kilograms;

  /// When the reading applies.
  final DateTime startedAt;

  /// Platform-specific source description.
  final String source;

  /// Identifier in the platform store.
  final String externalId;
}

/// A nutrition write the user confirmed.
final class NutritionWrite {
  /// Creates a write for one logged entry.
  const NutritionWrite({
    required this.externalId,
    required this.startedAt,
    required this.energyKcal,
    this.proteinG,
    this.carbohydrateG,
    this.fatG,
  });

  /// App-side identifier, reused on retry so the platform does not duplicate.
  final String externalId;

  /// When the nutrition applies.
  final DateTime startedAt;

  /// Energy in kcal.
  final double energyKcal;

  /// Protein in grams, when known.
  final double? proteinG;

  /// Carbohydrate in grams, when known.
  final double? carbohydrateG;

  /// Fat in grams, when known.
  final double? fatG;
}

/// Platform health exchange.
///
/// Write paths must be idempotent per [NutritionWrite.externalId] and must not
/// resurrect records the user deleted in the platform app.
abstract interface class HealthPort {
  /// Which of [types] this device can serve at all.
  Future<Set<HealthDataType>> availableTypes();

  /// Current authorization state for [types].
  Future<HealthAccess> authorization(Set<HealthDataType> types);

  /// Requests access to [types].
  Future<HealthAccess> request(Set<HealthDataType> types);

  /// Reads body-mass samples in `[from, to)`.
  Future<List<WeightSample>> readBodyMass(DateTime from, DateTime to);

  /// Writes one confirmed nutrition record.
  Future<void> writeNutrition(NutritionWrite write);

  /// Deletes the record previously written for [externalId], if present.
  Future<void> deleteNutrition(String externalId);
}
