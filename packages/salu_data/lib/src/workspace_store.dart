import 'dart:convert';
import 'package:drift/drift.dart';
import 'database/app_database.dart';
import 'document_validation.dart';

const userCollections = {
  'preferences',
  'favorite-food',
  'saved-meal',
  'profile',
  'target',
  'recipe',
  'batch',
  'plan',
  'groceries',
  'draft',
  'day',
  'water',
  'weight',
  'activity',
  'fast',
  'reward',
  'entry-revision',
  'checkin'
};

final class StoredDocument {
  StoredDocument(
      this.collection, this.id, this.revision, Map<String, Object?> data)
      : data = Map.unmodifiable(data);
  final String collection, id;
  final int revision;
  final Map<String, Object?> data;
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

  Future<int> reward(String eventId) async {
    final previous = await read('reward', eventId);
    if (previous != null) return previous.revision;
    return put(
        requestId: 'reward:$eventId',
        collection: 'reward',
        id: eventId,
        expectedRevision: 0,
        data: {'engagement': true});
  }
}
