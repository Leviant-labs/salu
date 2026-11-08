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

/// State that must be persisted by an outbox implementation across restarts.
enum HealthOutboxState {
  pending,
  synced,
  externallyDeleted,
  externallyEdited,

  /// Restored backup: remote state and authorization must be reviewed.
  restoreReviewRequired,
}

/// A confirmed nutrition export and its reconciliation state.
final class HealthOutboxItem {
  const HealthOutboxItem(this.write, this.state);
  final NutritionWrite write;
  final HealthOutboxState state;
}

/// Durable storage for one item per stable app-side export identifier.
///
/// The caller must serialize access to the same identifier. Implementations must
/// persist an item before returning, and enumerate pending items on restart.
abstract interface class HealthOutboxStore {
  Future<HealthOutboxItem?> get(String id);
  Future<void> put(HealthOutboxItem item);
}

/// An explicit deletion or edit reported by a platform change feed.
enum HealthExternalChange { deleted, edited }

/// Outcome of attempting one queued export.
enum HealthDispatchResult {
  sent,
  alreadySynced,
  permissionDenied,
  unsupported,
  retryLater,
  needsReview,
  notQueued,
}

/// Coordinates confirmed exports with a durable, caller-provided outbox.
///
/// Run a single worker per export ID. Platform adapters must implement
/// idempotent writes and report external changes before retrying a previously
/// attempted export. A missing record alone is not proof of external deletion.
final class HealthOutbox {
  const HealthOutbox(this.port, this.store);
  final HealthPort port;
  final HealthOutboxStore store;

  /// Queue an explicit user-confirmed record. An ID cannot be reused for
  /// different content; retries preserve both content and reconciliation state.
  Future<void> enqueueConfirmed(NutritionWrite write) async {
    if (write.externalId.trim().isEmpty) {
      throw ArgumentError.value(write.externalId, 'externalId');
    }
    for (final amount in [
      write.energyKcal,
      write.proteinG,
      write.carbohydrateG,
      write.fatG,
    ]) {
      if (amount != null && (!amount.isFinite || amount < 0)) {
        throw ArgumentError(
            'Exported nutrient amounts must be finite and non-negative');
      }
    }
    final previous = await store.get(write.externalId);
    if (previous != null) {
      if (!_sameWrite(previous.write, write)) {
        throw StateError('Export ID is already bound to different data');
      }
      return;
    }
    await store.put(HealthOutboxItem(write, HealthOutboxState.pending));
  }

  /// Apply a change from the platform's change feed before dispatching retries.
  /// Neither edits nor deletions are automatically overwritten or resurrected.
  Future<void> recordExternalChange(
      String id, HealthExternalChange change) async {
    final item = await store.get(id);
    if (item == null) return;
    final next = switch (change) {
      HealthExternalChange.deleted => HealthOutboxState.externallyDeleted,
      HealthExternalChange.edited => HealthOutboxState.externallyEdited,
    };
    // Once deleted, a late edit notification cannot undo the deletion marker.
    if (item.state == HealthOutboxState.externallyDeleted) return;
    await store.put(HealthOutboxItem(item.write, next));
  }

  /// Check support and authorization again for each dispatch, including retries.
  /// Permission changes and offline failures leave the queued item untouched.
  Future<HealthDispatchResult> dispatch(String id) async {
    final item = await store.get(id);
    if (item == null) return HealthDispatchResult.notQueued;
    if (item.state == HealthOutboxState.synced) {
      return HealthDispatchResult.alreadySynced;
    }
    if (item.state != HealthOutboxState.pending) {
      return HealthDispatchResult.needsReview;
    }
    final required = <HealthDataType>{
      HealthDataType.dietaryEnergy,
      if (item.write.proteinG != null) HealthDataType.dietaryProtein,
      if (item.write.carbohydrateG != null) HealthDataType.dietaryCarbohydrate,
      if (item.write.fatG != null) HealthDataType.dietaryFat,
    };
    try {
      final available = await port.availableTypes();
      if (!available.containsAll(required)) {
        return HealthDispatchResult.unsupported;
      }
      final access = await port.authorization(required);
      if (access == HealthAccess.unavailable) {
        return HealthDispatchResult.unsupported;
      }
      if (access != HealthAccess.granted) {
        return HealthDispatchResult.permissionDenied;
      }
      await port.writeNutrition(item.write);
      await store.put(HealthOutboxItem(item.write, HealthOutboxState.synced));
      return HealthDispatchResult.sent;
    } catch (_) {
      return HealthDispatchResult.retryLater;
    }
  }

  static bool _sameWrite(NutritionWrite a, NutritionWrite b) =>
      a.externalId == b.externalId &&
      a.startedAt == b.startedAt &&
      a.energyKcal == b.energyKcal &&
      a.proteinG == b.proteinG &&
      a.carbohydrateG == b.carbohydrateG &&
      a.fatG == b.fatG;
}
