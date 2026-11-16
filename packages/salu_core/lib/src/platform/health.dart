/// The platform health-store boundary (HealthKit / Health Connect).
///
/// Declared as a port so the core carries no plugin dependency and so the app can
/// fake it in tests. Platform symmetry is not assumed: callers must query which
/// types are actually available.
library;

import 'dart:async';

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
  /// Creates a reading.
  ///
  /// [externalId] is the platform record identity; [appRecordId] is the writing
  /// app's identity when the platform exposes one. Both participate in
  /// read-write loop and duplicate detection.
  const WeightSample({
    required this.kilograms,
    required this.startedAt,
    required this.source,
    required this.externalId,
    this.appRecordId,
  });

  /// Mass in kilograms.
  final double kilograms;

  /// When the reading applies.
  final DateTime startedAt;

  /// Platform-specific source description.
  final String source;

  /// Identifier in the platform store.
  final String externalId;

  /// Identifier the writing app assigned, when the platform exposes it
  /// (HealthKit sync identifier, Health Connect client record ID).
  ///
  /// Used to recognise this app's own exports and prevent read-write loops.
  final String? appRecordId;
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

/// Thrown by a platform adapter when the user denied or revoked the access
/// needed for a read or write. Callers must not retry it as a transient error.
final class HealthPermissionException implements Exception {
  const HealthPermissionException([this.message = 'Health access denied']);
  final String message;

  @override
  String toString() => 'HealthPermissionException: $message';
}

/// Support and authorization state for a requested set of health types.
///
/// Availability is reported before authorization because a type the platform
/// cannot serve is unsupported, not denied; the two need different UI copy and
/// must never be collapsed into "permission missing".
final class HealthCapability {
  HealthCapability({
    required Set<HealthDataType> requested,
    required Set<HealthDataType> available,
    required this.access,
  })  : requested = Set<HealthDataType>.unmodifiable(requested),
        available = Set<HealthDataType>.unmodifiable(available);

  /// Types the caller asked about.
  final Set<HealthDataType> requested;

  /// Types the device and platform can serve at all.
  final Set<HealthDataType> available;

  /// Authorization reported for [requested], after availability is checked.
  final HealthAccess access;

  /// Requested types this platform cannot serve.
  Set<HealthDataType> get unsupported =>
      Set<HealthDataType>.unmodifiable(requested.difference(available));

  /// True only when every requested type exists and access is granted.
  bool get granted => unsupported.isEmpty && access == HealthAccess.granted;
}

/// Combined support and authorization check.
extension HealthPortCapabilityCheck on HealthPort {
  /// Queries support before authorization. Adapters must not prompt for a type
  /// the platform cannot serve; if a required type is unavailable the result is
  /// [HealthAccess.unavailable] with the exact [HealthCapability.unsupported]
  /// types, regardless of current grants for the remaining types.
  Future<HealthCapability> capabilityFor(Set<HealthDataType> types) async {
    final requested = Set<HealthDataType>.of(types);
    final available = await availableTypes();
    if (requested.difference(available).isNotEmpty) {
      return HealthCapability(
          requested: requested,
          available: available,
          access: HealthAccess.unavailable);
    }
    return HealthCapability(
        requested: requested,
        available: available,
        access: await authorization(requested));
  }
}

/// Minimum platform types needed to export [write] without dropping a supplied
/// nutrient. Callers request exactly these types for a confirmed export rather
/// than asking for unrelated health data.
Set<HealthDataType> requiredHealthTypes(NutritionWrite write) => {
      HealthDataType.dietaryEnergy,
      if (write.proteinG != null) HealthDataType.dietaryProtein,
      if (write.carbohydrateG != null) HealthDataType.dietaryCarbohydrate,
      if (write.fatG != null) HealthDataType.dietaryFat,
    };

/// Platform health exchange.
///
/// Write paths must be idempotent per [NutritionWrite.externalId] and must not
/// resurrect records the user deleted in the platform app.
///
/// Implementations report denial or revocation with [HealthPermissionException].
/// [request] may show a platform permission prompt, so callers only invoke it
/// from an explicit user action and never as part of retrying a queued export.
///
/// Native support is established per platform, not assumed from Flutter: iOS
/// needs HealthKit entitlements and usage descriptions, Android needs the
/// Health Connect package, manifest permissions and a device/OS that supports
/// the requested record types. Until an adapter exists and reports a type in
/// [availableTypes], callers must treat it as unavailable.
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

/// One read-side import decision for platform weight samples.
///
/// Planning never writes to the platform store or the local database.
final class WeightImportPlan {
  WeightImportPlan({
    required Iterable<WeightSample> importable,
    required Iterable<WeightSample> ownWrites,
    required Iterable<WeightSample> duplicates,
    required Iterable<WeightSample> conflicts,
    required Iterable<WeightSample> invalid,
  })  : importable = List<WeightSample>.unmodifiable(importable),
        ownWrites = List<WeightSample>.unmodifiable(ownWrites),
        duplicates = List<WeightSample>.unmodifiable(duplicates),
        conflicts = List<WeightSample>.unmodifiable(conflicts),
        invalid = List<WeightSample>.unmodifiable(invalid);

  /// New readings this app did not write, one per platform record.
  final List<WeightSample> importable;

  /// Readings written by this app; importing them would close a read-write loop.
  final List<WeightSample> ownWrites;

  /// Exact repeats of an already accepted platform record.
  final List<WeightSample> duplicates;

  /// Records whose shared external ID carries inconsistent content. None of
  /// these are importable until the caller resolves the conflict.
  final List<WeightSample> conflicts;

  /// Records with a non-positive/non-finite mass or a blank external ID.
  final List<WeightSample> invalid;

  /// True when at least one external identity had inconsistent content.
  bool get hasConflicts => conflicts.isNotEmpty;
}

/// Plans a weight import without writing anything.
///
/// Loop and duplicate rules:
/// - a sample whose [WeightSample.source] is in [ownSources], or whose
///   [WeightSample.externalId] or [WeightSample.appRecordId] is in
///   [ownRecordIds], is this app's own export and is skipped rather than
///   re-imported;
/// - repeated identical content under one external ID is a duplicate;
/// - differing content under one external ID is a conflict and none of that
///   identity is importable, because choosing one would silently discard data;
/// - different external IDs (for example two scales) remain separate readings.
///
/// The accepted list is ordered by time, then external ID, so the same read
/// produces the same plan.
WeightImportPlan planWeightImport(
  Iterable<WeightSample> samples, {
  Set<String> ownSources = const <String>{},
  Set<String> ownRecordIds = const <String>{},
}) {
  final ordered = samples.toList()
    ..sort((a, b) {
      final time = a.startedAt.compareTo(b.startedAt);
      if (time != 0) return time;
      final id = a.externalId.compareTo(b.externalId);
      if (id != 0) return id;
      final source = a.source.compareTo(b.source);
      if (source != 0) return source;
      final mass = a.kilograms.compareTo(b.kilograms);
      if (mass != 0) return mass;
      return (a.appRecordId ?? '').compareTo(b.appRecordId ?? '');
    });
  final importable = <WeightSample>[];
  final ownWrites = <WeightSample>[];
  final duplicates = <WeightSample>[];
  final conflicts = <WeightSample>[];
  final invalid = <WeightSample>[];
  final accepted = <String, WeightSample>{};
  final conflicted = <String>{};
  for (final sample in ordered) {
    if (sample.externalId.trim().isEmpty ||
        !sample.kilograms.isFinite ||
        sample.kilograms <= 0) {
      invalid.add(sample);
      continue;
    }
    if (ownSources.contains(sample.source) ||
        ownRecordIds.contains(sample.externalId) ||
        (sample.appRecordId != null &&
            ownRecordIds.contains(sample.appRecordId))) {
      ownWrites.add(sample);
      continue;
    }
    if (conflicted.contains(sample.externalId)) {
      conflicts.add(sample);
      continue;
    }
    final previous = accepted[sample.externalId];
    if (previous == null) {
      accepted[sample.externalId] = sample;
      importable.add(sample);
      continue;
    }
    if (previous.kilograms == sample.kilograms &&
        previous.startedAt.isAtSameMomentAs(sample.startedAt) &&
        previous.source == sample.source) {
      duplicates.add(sample);
      continue;
    }
    conflicted.add(sample.externalId);
    importable.removeWhere((s) => s.externalId == sample.externalId);
    conflicts
      ..add(previous)
      ..add(sample);
  }
  return WeightImportPlan(
      importable: importable,
      ownWrites: ownWrites,
      duplicates: duplicates,
      conflicts: conflicts,
      invalid: invalid);
}

/// State that must be persisted by an outbox implementation across restarts.
enum HealthOutboxState {
  /// Confirmed locally and awaiting an external write.
  pending,

  /// The external write was acknowledged; retries report already synced.
  synced,

  /// The user deleted the record in the platform app. This export ID is
  /// terminal: retries require review and a replacement needs a new ID.
  externallyDeleted,

  /// The user edited the record in the platform app. Automatic writes stop
  /// until the difference is reviewed.
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

  /// Items still awaiting dispatch, in a deterministic order.
  ///
  /// Recovery after a restart enumerates this instead of scanning the database
  /// directly. Synced and review-blocked items are never returned.
  Future<List<HealthOutboxItem>> pending();
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
/// Operations for one export ID are serialized within this instance, so a
/// dispatch cannot interleave with an external-change marker or a second
/// enqueue. Separate workers or isolates must still serialize per ID; the store
/// transition guards and idempotent platform adapter remain the safety net.
///
/// Platform adapters must implement idempotent writes and report external
/// changes before retrying a previously attempted export. A missing record alone
/// is not proof of external deletion.
final class HealthOutbox {
  const HealthOutbox(this.port, this.store);
  final HealthPort port;
  final HealthOutboxStore store;

  static final Expando<Map<String, Future<void>>> _queuesByInstance =
      Expando<Map<String, Future<void>>>('health-outbox-queues');
  Map<String, Future<void>> get _queues =>
      _queuesByInstance[this] ??= <String, Future<void>>{};

  /// Recover pending exports after a restart. The platform change feed must be
  /// reconciled before these are dispatched.
  Future<List<HealthOutboxItem>> pending() => store.pending();

  /// Dispatch every pending item once, sequentially, and report the outcome per
  /// export ID. Items queued while this runs wait for the next pass.
  Future<Map<String, HealthDispatchResult>> dispatchPending() async {
    final outcomes = <String, HealthDispatchResult>{};
    for (final item in await store.pending()) {
      final id = item.write.externalId;
      outcomes[id] = await dispatch(id);
    }
    return outcomes;
  }

  /// Queue an explicit user-confirmed record. An ID cannot be reused for
  /// different content; retries preserve both content and reconciliation state.
  Future<void> enqueueConfirmed(NutritionWrite write) async {
    _validate(write);
    return _serialize(write.externalId, () async {
      final previous = await store.get(write.externalId);
      if (previous != null) {
        if (!_sameWrite(previous.write, write)) {
          throw StateError('Export ID is already bound to different data');
        }
        return;
      }
      await store.put(HealthOutboxItem(write, HealthOutboxState.pending));
    });
  }

  /// Apply a change from the platform's change feed before dispatching retries.
  /// Neither edits nor deletions are automatically overwritten or resurrected;
  /// a deleted export ID is terminal and a replacement export needs a new ID.
  Future<void> recordExternalChange(
      String id, HealthExternalChange change) async {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
    return _serialize(id, () async {
      final item = await store.get(id);
      if (item == null) return;
      final next = switch (change) {
        HealthExternalChange.deleted => HealthOutboxState.externallyDeleted,
        HealthExternalChange.edited => HealthOutboxState.externallyEdited,
      };
      // Once deleted, a late edit notification cannot undo the deletion marker.
      if (item.state == HealthOutboxState.externallyDeleted) return;
      await store.put(HealthOutboxItem(item.write, next));
    });
  }

  /// Check support and authorization again for each dispatch, including retries.
  /// Permission changes and offline failures leave the queued item untouched.
  Future<HealthDispatchResult> dispatch(String id) {
    if (id.trim().isEmpty) return Future.value(HealthDispatchResult.notQueued);
    return _serialize(id, () => _dispatchLocked(id));
  }

  Future<HealthDispatchResult> _dispatchLocked(String id) async {
    final item = await store.get(id);
    if (item == null) return HealthDispatchResult.notQueued;
    if (item.state == HealthOutboxState.synced) {
      return HealthDispatchResult.alreadySynced;
    }
    if (item.state != HealthOutboxState.pending) {
      return HealthDispatchResult.needsReview;
    }
    final required = requiredHealthTypes(item.write);
    final HealthCapability capability;
    try {
      capability = await port.capabilityFor(required);
    } on HealthPermissionException {
      return HealthDispatchResult.permissionDenied;
    } catch (_) {
      return HealthDispatchResult.retryLater;
    }
    if (capability.unsupported.isNotEmpty ||
        capability.access == HealthAccess.unavailable) {
      return HealthDispatchResult.unsupported;
    }
    if (capability.access != HealthAccess.granted) {
      return HealthDispatchResult.permissionDenied;
    }
    try {
      await port.writeNutrition(item.write);
    } on HealthPermissionException {
      return HealthDispatchResult.permissionDenied;
    } catch (_) {
      return HealthDispatchResult.retryLater;
    }
    try {
      await store.put(HealthOutboxItem(item.write, HealthOutboxState.synced));
      return HealthDispatchResult.sent;
    } catch (_) {
      // The platform write may have succeeded even though local state could not
      // be updated. Never report synced without durable state: a concurrent
      // external change is a review case, anything else is retried (the adapter
      // must deduplicate by export ID).
      try {
        final current = await store.get(id);
        if (current != null) {
          if (current.state == HealthOutboxState.synced) {
            return HealthDispatchResult.alreadySynced;
          }
          if (current.state != HealthOutboxState.pending) {
            return HealthDispatchResult.needsReview;
          }
        }
      } catch (_) {
        return HealthDispatchResult.retryLater;
      }
      return HealthDispatchResult.retryLater;
    }
  }

  Future<T> _serialize<T>(String id, Future<T> Function() action) async {
    final queues = _queues;
    final previous = queues[id] ?? Future<void>.value();
    final gate = Completer<void>();
    queues[id] = gate.future;
    // Gates complete without an error even when the guarded action fails, so a
    // failed predecessor never poisons the next operation for the same ID.
    await previous;
    try {
      return await action();
    } finally {
      gate.complete();
      if (identical(queues[id], gate.future)) {
        unawaited(queues.remove(id));
      }
    }
  }

  static void _validate(NutritionWrite write) {
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
  }

  static bool _sameWrite(NutritionWrite a, NutritionWrite b) =>
      a.externalId == b.externalId &&
      a.startedAt.isAtSameMomentAs(b.startedAt) &&
      a.energyKcal == b.energyKcal &&
      a.proteinG == b.proteinG &&
      a.carbohydrateG == b.carbohydrateG &&
      a.fatG == b.fatG;
}
