import 'package:salu_core/salu_core.dart';

import 'database/app_database.dart';
import 'workspace_store.dart';

/// Durable draft revisions. No provider request or diary write happens here
/// except through an explicit local confirmation callback.
final class MealDraftStore {
  MealDraftStore(this.db) : _workspace = LocalWorkspace(db);
  final AppDatabase db;
  final LocalWorkspace _workspace;

  Future<MealDraft?> read(String id) async {
    final row = await _workspace.read('meal-draft-v1', id);
    return row == null ? null : _decode(row);
  }

  Future<List<MealDraft>> list() async =>
      (await _workspace.list('meal-draft-v1')).map(_decode).toList(growable: false);

  Future<MealDraft> create({
    required String id,
    required String requestId,
    Map<String, Object?> values = const {},
  }) async {
    final draft = MealDraft(id: id, values: values);
    await _write(draft, expectedRevision: 0, requestId: requestId);
    return (await read(id))!;
  }

  Future<MealDraft> edit({
    required String id,
    required String requestId,
    required int expectedRevision,
    required Map<String, Object?> values,
  }) =>
      _transition(
          id, requestId, expectedRevision, (draft) => draft.edit(values));

  /// The caller must validate provider output before passing it here. An async
  /// response tied to an old revision cannot overwrite a later edit.
  Future<MealDraft> receiveValidated({
    required String id,
    required String requestId,
    required int expectedRevision,
    required Map<String, Object?> suggestion,
  }) =>
      _transition(
          id,
          requestId,
          expectedRevision,
          (draft) => draft.receive(
              expectedRevision: expectedRevision, suggestion: suggestion));

  Future<MealDraft> cancel({
    required String id,
    required String requestId,
    required int expectedRevision,
  }) =>
      _transition(id, requestId, expectedRevision, (draft) => draft.cancel());

  /// Atomically mark a reviewed draft committed with its local database write.
  /// [writeLocal] must use this database and must not perform external I/O.
  /// Retrying the same confirmation request does not call it again.
  Future<MealDraft> confirm({
    required String id,
    required String requestId,
    required int expectedRevision,
    required bool reviewed,
    required Future<void> Function() writeLocal,
  }) async {
    if (requestId.isEmpty) throw ArgumentError('Empty request ID');
    return db.transaction(() async {
      final row = await _workspace.read('meal-draft-v1', id);
      if (row == null) throw StateError('DRAFT_NOT_FOUND');
      final draft = _decode(row);
      if (draft.status == DraftStatus.committed &&
          row.data['confirmationRequestId'] == requestId &&
          reviewed) {
        // The request id identifies the confirmation that was already applied,
        // so a retry after a refreshed revision still replays without writing.
        return draft;
      }
      if (draft.revision != expectedRevision) throw StateError('STALE_DRAFT');
      final confirmed =
          draft.confirm(expectedRevision: expectedRevision, reviewed: reviewed);
      await writeLocal();
      await _write(confirmed,
          expectedRevision: expectedRevision,
          requestId: requestId,
          confirmationRequestId: requestId);
      return confirmed;
    });
  }

  Future<MealDraft> _transition(String id, String requestId,
          int expectedRevision, MealDraft Function(MealDraft) transition) =>
      db.transaction(() async {
        final draft = await read(id);
        if (draft == null) throw StateError('DRAFT_NOT_FOUND');
        if (draft.revision != expectedRevision) throw StateError('STALE_DRAFT');
        final next = transition(draft);
        await _write(next,
            expectedRevision: expectedRevision, requestId: requestId);
        return next;
      });

  Future<void> _write(MealDraft draft,
      {required int expectedRevision,
      required String requestId,
      String? confirmationRequestId}) async {
    await _workspace.put(
      requestId: requestId,
      collection: 'meal-draft-v1',
      id: draft.id,
      expectedRevision: expectedRevision,
      data: {
        'status': draft.status.name,
        'values': draft.values,
        if (confirmationRequestId != null)
          'confirmationRequestId': confirmationRequestId
      },
    );
  }

  static MealDraft _decode(StoredDocument row) => MealDraft(
      id: row.id,
      revision: row.revision,
      status: DraftStatus.values.byName(row.data['status']! as String),
      values: Map<String, Object?>.from(row.data['values']! as Map));
}
