import 'dart:convert';

import '../database/app_database.dart';

typedef LocalRecord = ({int revision, Map<String, dynamic> data});

/// Storage for typed feature documents; revision 0 denotes a missing document.
final class LocalDocumentStore {
  const LocalDocumentStore(this.db);

  final AppDatabase db;

  Future<LocalRecord?> read(String id) async {
    final row = await (db.select(db.localDocuments)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return (
      revision: row.revision,
      data: jsonDecode(row.payload) as Map<String, dynamic>
    );
  }

  Future<bool> put(
          String id, int expectedRevision, Map<String, Object?> data) =>
      db.transaction(() async {
        final before = await read(id);
        if ((before?.revision ?? 0) != expectedRevision) return false;
        await db
            .into(db.localDocuments)
            .insertOnConflictUpdate(LocalDocumentsCompanion.insert(
              id: id,
              revision: expectedRevision + 1,
              payload: jsonEncode(data),
            ));
        return true;
      });

  Future<void> remove(String id) async {
    await (db.delete(db.localDocuments)..where((t) => t.id.equals(id))).go();
  }
}
