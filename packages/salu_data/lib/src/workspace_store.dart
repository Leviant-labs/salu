import 'dart:convert';
import 'package:drift/drift.dart';
import 'database/app_database.dart';
import 'document_validation.dart';

/// Positive behaviours that may earn a reward.
///
/// Intake, weight and fasting outcomes are deliberately absent: lowering
/// intake, losing weight faster or fasting longer is never rewarded, and a
/// missed day can at most decline to add a reward. It never removes or
/// downgrades one already recorded. `day-review` and `checkin` are the
/// existing engagement rewards; the others are the behaviours named by the
/// product contract.
const rewardEventKinds = {
  'engagement',
  'planning',
  'learning',
  'return',
  'day-review',
  'checkin',
};

const userCollections = {
  'preferences',
  'favorite-food',
  'saved-meal',
  'profile',
  'health-declaration',
  'nutrition-profile-v1',
  'meal-content-v1',
  'plan-meal-state-v1',
  'target',
  'recipe',
  'batch',
  'plan',
  'groceries',
  'draft',
  'meal-draft-v1',
  'day',
  'water',
  'weight',
  'activity',
  'fast',
  'reward',
  'entry-revision',
  'checkin',
  'health-outbox'
};

final class StoredDocument {
  StoredDocument(
      this.collection, this.id, this.revision, Map<String, Object?> data)
      : data = Map.unmodifiable(data);
  final String collection, id;
  final int revision;
  final Map<String, Object?> data;
}

/// Rejects new reward events that would reinforce eating restriction or
/// punishment.
///
/// The event id is `<kind>` or `<kind>:<subject>`. [LocalWorkspace.reward]
/// returns an existing event before calling this, so policy changes never
/// invalidate history; this only guards events that would create a new row.
/// A stable id makes a retry resolve to the same stored event. Unknown kinds
/// are rejected rather than guessed: adding a reward kind is a visible policy
/// decision.
void _validateRewardEvent(String eventId) {
  if (eventId.isEmpty || eventId.trim() != eventId) {
    throw ArgumentError.value(eventId, 'eventId', 'Invalid reward event');
  }
  final separator = eventId.indexOf(':');
  final kind = separator == -1 ? eventId : eventId.substring(0, separator);
  final subject = separator == -1 ? null : eventId.substring(separator + 1);
  if (!rewardEventKinds.contains(kind)) {
    throw ArgumentError.value(
        eventId,
        'eventId',
        'Rewards are limited to engagement, planning, learning, returning '
            'after breaks, daily review and check-ins; intake, weight and '
            'fasting outcomes are never rewarded');
  }
  if (subject != null &&
      (subject.isEmpty ||
          subject.trim() != subject ||
          subject.contains(':'))) {
    throw ArgumentError.value(eventId, 'eventId', 'Invalid reward event');
  }
}

final class LocalWorkspace {
  LocalWorkspace(this.db);
  final AppDatabase db;
  Future<StoredDocument?> read(String collection, String id) async {
    final row = await (db.select(db.userDocuments)
          ..where((t) => t.collection.equals(collection) & t.id.equals(id)))
        .getSingleOrNull();
    return row == null
        ? null
        : StoredDocument(row.collection, row.id, row.revision,
            Map<String, Object?>.from(jsonDecode(row.payload) as Map));
  }

  Future<List<StoredDocument>> list(String collection) async =>
      (await (db.select(db.userDocuments)
                ..where((t) => t.collection.equals(collection))
                ..orderBy([(t) => OrderingTerm.asc(t.id)]))
              .get())
          .map((r) => StoredDocument(r.collection, r.id, r.revision,
              Map<String, Object?>.from(jsonDecode(r.payload) as Map)))
          .toList();

  /// Optimistic revision check and idempotency share the data transaction.
  ///
  /// Reward documents are immutable through this method after creation: a
  /// fresh reward row is checked against the same allowlist as [reward] and
  /// must record engagement, while an existing reward row only accepts a
  /// receipt replay of the request that created it. Use [reward] to record
  /// events; historical rows remain readable and retryable there.
  Future<int> put(
      {required String requestId,
      required String collection,
      required String id,
      required int expectedRevision,
      required Map<String, Object?> data}) async {
    if (requestId.isEmpty ||
        id.isEmpty ||
        !userCollections.contains(collection)) {
      throw ArgumentError('Invalid write');
    }
    validateUserDocument(collection, data);
    final payload = jsonEncode(data);
    final rewardWrite = collection == 'reward';
    return db.transaction(() async {
      final prior = await (db.select(db.appliedCommands)
            ..where((t) => t.requestId.equals(requestId)))
          .getSingleOrNull();
      if (prior != null) {
        final r =
            Map<String, Object?>.from(jsonDecode(prior.resultJson) as Map);
        if (r['collection'] != collection ||
            r['id'] != id ||
            r['payload'] != payload) {
          throw StateError('REQUEST_ID_REUSED');
        }
        return r['revision']! as int;
      }
      final previous = await read(collection, id);
      if ((previous?.revision ?? 0) != expectedRevision) {
        throw StateError('STALE_REVISION');
      }
      // Receipt replay above is the only repeated write. Even when the
      // expected revision matches, an existing reward row cannot be updated:
      // that would be a non-idempotent rewrite.
      if (rewardWrite && previous != null) {
        throw StateError('REWARD_UPDATE_UNSUPPORTED');
      }
      // Fresh reward rows must obey the same allowlist as [reward]. Existing
      // historical rows are never re-validated or rewritten; they remain
      // readable, restorable and retryable through [reward].
      if (rewardWrite) {
        _validateRewardEvent(id);
        final fresh =
            Map<String, Object?>.from(jsonDecode(payload) as Map);
        if (fresh['engagement'] != true) {
          throw ArgumentError(
              'A new reward event must record engagement');
        }
      }
      final revision = expectedRevision + 1;
      await db.into(db.userDocuments).insertOnConflictUpdate(
          UserDocumentsCompanion.insert(
              collection: collection,
              id: id,
              revision: revision,
              payload: payload));
      await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
          requestId: requestId,
          resultJson: jsonEncode({
            'collection': collection,
            'id': id,
            'revision': revision,
            'payload': payload
          })));
      return revision;
    });
  }

  Future<void> invalidateHistory() async {
    await (db.delete(db.userDocuments)
          ..where((t) => t.collection.equals('checkin')))
        .go();
  }

  /// Records one positive engagement event exactly once.
  ///
  /// The event id is the stable idempotency key. An existing event returns its
  /// revision without a write, even when the kind is no longer in
  /// [rewardEventKinds], so historical records stay idempotent after a policy
  /// change or restoration. Only a new event is policy-gated: repeated,
  /// concurrent and post-restore calls otherwise return the single stored
  /// event. Rewards are additive and are never deleted or downgraded here, so
  /// a missed day cannot take one away. Callers keep using the existing
  /// `planning:<date>`, `day-review:<date>` and `checkin:<date>` ids.
  /// Throws [ArgumentError] for a malformed or non-positive new event id;
  /// nothing is written in that case.
  Future<int> reward(String eventId) async {
    return db.transaction(() async {
      final previous = await read('reward', eventId);
      if (previous != null) return previous.revision;
      _validateRewardEvent(eventId);
      return put(
          requestId: 'reward:$eventId',
          collection: 'reward',
          id: eventId,
          expectedRevision: 0,
          // Kept byte-identical to historical reward documents so retries from
          // older builds and restored records still compare idempotently.
          data: const <String, Object?>{'engagement': true});
    });
  }
}
