import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../codec.dart';
import '../codec/photo_meal_codec.dart';
import '../codec/recipe_codec.dart';
import '../database/app_database.dart';
import 'local_document_store.dart';

/// Transactional, idempotent mutation journal for [PhotoMeal] records.
final class MealMutationRepository {
  MealMutationRepository(this._db, {required Clock clock}) : _clock = clock;

  static const Duration undoWindow = Duration(hours: 24);

  final AppDatabase _db;
  final Clock _clock;

  /// Applies [command] atomically with idempotency and optimistic revision
  /// checking.
  Future<MealMutationResult> apply(MealCommand command) {
    final requestId = command.requestId.trim();
    if (requestId.isEmpty) {
      throw ArgumentError.value(command.requestId, 'requestId', 'required');
    }
    final digest = _payloadDigest(command);

    return _db.transaction(() async {
      final existing = await (_db.select(_db.mealMutations)
            ..where((t) => t.requestId.equals(requestId)))
          .getSingleOrNull();
      if (existing != null) {
        if (existing.payloadDigest != digest) {
          return const MealMutationResult(status: MutationStatus.stale);
        }
        final restoredMeal = existing.afterJson == null
            ? null
            : decodePhotoMeal(decodeJsonMap(existing.afterJson!));
        return MealMutationResult(
          status: MutationStatus.alreadyApplied,
          meal: restoredMeal,
          undoToken: existing.operation == 'delete' ? existing.requestId : null,
        );
      }

      return switch (command) {
        ReviseMeal() => _applyRevise(command, requestId, digest),
        MoveMeal() => _applyMove(command, requestId, digest),
        DeleteMeal() => _applyDelete(command, requestId, digest),
        UndoMeal() => _applyUndo(command, requestId, digest),
      };
    });
  }

  Future<MealMutationResult> _applyRevise(
    ReviseMeal command,
    String requestId,
    String digest,
  ) async {
    final row = await (_db.select(_db.photoMeals)
          ..where((t) => t.id.equals(command.meal.id)))
        .getSingleOrNull();
    if (row == null) {
      return const MealMutationResult(status: MutationStatus.notFound);
    }
    if (row.revision != command.expectedRevision) {
      return const MealMutationResult(status: MutationStatus.stale);
    }

    final before = _hydrateRow(row);
    final resultingRevision = command.expectedRevision + 1;
    final after = before.copyWith(
      date: command.meal.date,
      slot: command.meal.slot,
      caption: command.meal.caption,
      items: command.meal.items,
      revision: resultingRevision,
      photoPath: command.meal.photoPath,
      clearPhoto: command.meal.photoPath == null,
      estimateStatus: command.meal.estimateStatus,
    );

    final updated = await (_db.update(_db.photoMeals)
          ..where((t) =>
              t.id.equals(before.id) &
              t.revision.equals(command.expectedRevision)))
        .write(PhotoMealsCompanion(
      diaryDate: Value(after.date.toIso()),
      slot: Value(after.slot.name),
      caption: Value(after.caption),
      revision: Value(resultingRevision),
      photoPath: Value(after.photoPath),
      estimateStatus: Value(after.estimateStatus.name),
      itemsJson: Value(_encodeItems(after.items)),
    ));
    if (updated != 1) {
      return const MealMutationResult(status: MutationStatus.stale);
    }

    final nowMs = _clock.nowUtc().millisecondsSinceEpoch;
    await _db.into(_db.mealMutations).insert(MealMutationsCompanion.insert(
          requestId: requestId,
          mealId: before.id,
          operation: 'revise',
          expectedRevision: command.expectedRevision,
          resultingRevision: resultingRevision,
          beforeJson: Value(jsonEncode(encodePhotoMeal(before))),
          afterJson: Value(jsonEncode(encodePhotoMeal(after))),
          createdAtMs: nowMs,
          undoExpiresAtMs: const Value(null),
          payloadDigest: digest,
        ));

    return MealMutationResult(status: MutationStatus.applied, meal: after);
  }

  Future<MealMutationResult> _applyMove(
    MoveMeal command,
    String requestId,
    String digest,
  ) async {
    if (command.date.compareTo(command.today) > 0) {
      return const MealMutationResult(status: MutationStatus.invalidDate);
    }

    final row = await (_db.select(_db.photoMeals)
          ..where((t) => t.id.equals(command.mealId)))
        .getSingleOrNull();
    if (row == null) {
      return const MealMutationResult(status: MutationStatus.notFound);
    }
    if (row.revision != command.expectedRevision) {
      return const MealMutationResult(status: MutationStatus.stale);
    }

    final before = _hydrateRow(row);
    final resultingRevision = command.expectedRevision + 1;
    final after = before.copyWith(
      date: command.date,
      revision: resultingRevision,
    );

    final updated = await (_db.update(_db.photoMeals)
          ..where((t) =>
              t.id.equals(before.id) &
              t.revision.equals(command.expectedRevision)))
        .write(PhotoMealsCompanion(
      diaryDate: Value(after.date.toIso()),
      revision: Value(resultingRevision),
    ));
    if (updated != 1) {
      return const MealMutationResult(status: MutationStatus.stale);
    }

    final nowMs = _clock.nowUtc().millisecondsSinceEpoch;
    await _db.into(_db.mealMutations).insert(MealMutationsCompanion.insert(
          requestId: requestId,
          mealId: before.id,
          operation: 'move',
          expectedRevision: command.expectedRevision,
          resultingRevision: resultingRevision,
          beforeJson: Value(jsonEncode(encodePhotoMeal(before))),
          afterJson: Value(jsonEncode(encodePhotoMeal(after))),
          createdAtMs: nowMs,
          undoExpiresAtMs: const Value(null),
          payloadDigest: digest,
        ));

    return MealMutationResult(status: MutationStatus.applied, meal: after);
  }

  Future<MealMutationResult> _applyDelete(
    DeleteMeal command,
    String requestId,
    String digest,
  ) async {
    final row = await (_db.select(_db.photoMeals)
          ..where((t) => t.id.equals(command.mealId)))
        .getSingleOrNull();
    if (row == null) {
      return const MealMutationResult(status: MutationStatus.notFound);
    }
    if (row.revision != command.expectedRevision) {
      return const MealMutationResult(status: MutationStatus.stale);
    }

    final before = _hydrateRow(row);
    final resultingRevision = command.expectedRevision + 1;
    final deletedCount = await (_db.delete(_db.photoMeals)
          ..where((t) =>
              t.id.equals(before.id) &
              t.revision.equals(command.expectedRevision)))
        .go();
    if (deletedCount != 1) {
      return const MealMutationResult(status: MutationStatus.stale);
    }

    final nowMs = _clock.nowUtc().millisecondsSinceEpoch;
    final expiresAtMs = nowMs + undoWindow.inMilliseconds;
    await _db.into(_db.mealMutations).insert(MealMutationsCompanion.insert(
          requestId: requestId,
          mealId: before.id,
          operation: 'delete',
          expectedRevision: command.expectedRevision,
          resultingRevision: resultingRevision,
          beforeJson: Value(jsonEncode(encodePhotoMeal(before))),
          afterJson: const Value(null),
          createdAtMs: nowMs,
          undoExpiresAtMs: Value(expiresAtMs),
          payloadDigest: digest,
        ));

    return MealMutationResult(
      status: MutationStatus.applied,
      undoToken: requestId,
    );
  }

  Future<MealMutationResult> _applyUndo(
    UndoMeal command,
    String requestId,
    String digest,
  ) async {
    final deleteRow = await (_db.select(_db.mealMutations)
          ..where((t) => t.requestId.equals(command.undoToken)))
        .getSingleOrNull();
    if (deleteRow == null ||
        deleteRow.operation != 'delete' ||
        deleteRow.beforeJson == null) {
      return const MealMutationResult(status: MutationStatus.notFound);
    }

    final nowMs = _clock.nowUtc().millisecondsSinceEpoch;
    final expiresAtMs = deleteRow.undoExpiresAtMs;
    if (expiresAtMs == null || nowMs >= expiresAtMs) {
      return const MealMutationResult(status: MutationStatus.expired);
    }

    final activeRow = await (_db.select(_db.photoMeals)
          ..where((t) => t.id.equals(deleteRow.mealId)))
        .getSingleOrNull();
    if (activeRow != null) {
      return const MealMutationResult(status: MutationStatus.stale);
    }

    final mealHistory = await (_db.select(_db.mealMutations)
          ..where((t) => t.mealId.equals(deleteRow.mealId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.resultingRevision),
            (t) => OrderingTerm.desc(t.createdAtMs),
          ]))
        .get();
    final latest = mealHistory.first;
    if (latest.requestId != deleteRow.requestId) {
      return const MealMutationResult(status: MutationStatus.stale);
    }

    final maxRevision = math.max(
      deleteRow.resultingRevision,
      latest.resultingRevision,
    );
    final resultingRevision = maxRevision + 1;
    final before = decodePhotoMeal(decodeJsonMap(deleteRow.beforeJson!));
    final restored = before.copyWith(revision: resultingRevision);

    await _db.into(_db.photoMeals).insert(PhotoMealsCompanion.insert(
          id: restored.id,
          diaryDate: restored.date.toIso(),
          slot: restored.slot.name,
          caption: restored.caption,
          createdAtMs: restored.createdAt.millisecondsSinceEpoch,
          revision: restored.revision,
          photoPath: Value(restored.photoPath),
          estimateStatus: Value(restored.estimateStatus.name),
          recordedOffsetMinutes: Value(restored.recordedOffsetMinutes),
          itemsJson: _encodeItems(restored.items),
        ));

    await _db.into(_db.mealMutations).insert(MealMutationsCompanion.insert(
          requestId: requestId,
          mealId: restored.id,
          operation: 'undo',
          expectedRevision: deleteRow.resultingRevision,
          resultingRevision: resultingRevision,
          beforeJson: const Value(null),
          afterJson: Value(jsonEncode(encodePhotoMeal(restored))),
          createdAtMs: nowMs,
          undoExpiresAtMs: const Value(null),
          payloadDigest: digest,
        ));

    return MealMutationResult(status: MutationStatus.applied, meal: restored);
  }

  /// Removes orphaned `estimate:<meal-id>` status documents for deleted meals
  /// whose undo window has expired and which have not been restored.
  Future<int> purgeExpiredUndoStatus(DateTime nowUtc) =>
      _db.transaction(() async {
        final nowMs = nowUtc.toUtc().millisecondsSinceEpoch;
        final expiredDeletes = await (_db.select(_db.mealMutations)
              ..where((t) =>
                  t.operation.equals('delete') &
                  t.undoExpiresAtMs.isNotNull() &
                  t.undoExpiresAtMs.isSmallerOrEqualValue(nowMs)))
            .get();
        if (expiredDeletes.isEmpty) return 0;

        final candidateIds = {for (final row in expiredDeletes) row.mealId};
        final activeRows = await (_db.select(_db.photoMeals)
              ..where((t) => t.id.isIn(candidateIds)))
            .get();
        final activeIds = {for (final row in activeRows) row.id};

        final documents = LocalDocumentStore(_db);
        var purged = 0;
        for (final mealId in candidateIds) {
          if (activeIds.contains(mealId)) continue;
          final docId = 'estimate:$mealId';
          final existing = await documents.read(docId);
          if (existing != null) {
            await documents.remove(docId);
            purged++;
          }
        }
        return purged;
      });

  /// Returns all media references (`photoPath` and item `labelPaths`) owned by
  /// live [PhotoMeals] rows and unexpired deletion snapshots in [MealMutations].
  Future<Set<String>> referencedMedia(DateTime nowUtc) async {
    final refs = <String>{};

    void collectFromMeal(PhotoMeal meal) {
      final photo = meal.photoPath;
      if (photo != null && photo.isNotEmpty) refs.add(photo);
      for (final item in meal.items) {
        for (final label in item.labelPaths) {
          if (label.isNotEmpty) refs.add(label);
        }
      }
    }

    final liveRows = await _db.select(_db.photoMeals).get();
    for (final row in liveRows) {
      collectFromMeal(_hydrateRow(row));
    }

    final nowMs = nowUtc.toUtc().millisecondsSinceEpoch;
    final unexpiredDeletes = await (_db.select(_db.mealMutations)
          ..where((t) =>
              t.operation.equals('delete') &
              t.undoExpiresAtMs.isNotNull() &
              t.undoExpiresAtMs.isBiggerThanValue(nowMs) &
              t.beforeJson.isNotNull()))
        .get();
    for (final row in unexpiredDeletes) {
      collectFromMeal(decodePhotoMeal(decodeJsonMap(row.beforeJson!)));
    }

    return refs;
  }

  PhotoMeal _hydrateRow(PhotoMealRow row) => PhotoMeal(
        id: row.id,
        date: DiaryDate.parse(row.diaryDate),
        slot: MealSlot.values.byName(row.slot),
        caption: row.caption,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row.createdAtMs, isUtc: true),
        revision: row.revision,
        photoPath: row.photoPath,
        estimateStatus: MealEstimateStatus.values.byName(row.estimateStatus),
        recordedOffsetMinutes: row.recordedOffsetMinutes,
        items: (jsonDecode(row.itemsJson) as List)
            .indexed
            .map((entry) => decodePhotoMealItem(
                  entry.$2,
                  fallbackId: '${row.id}:legacy:${entry.$1}',
                  strict: false,
                ))
            .toList(),
      );

  String _encodeItems(List<PhotoMealItem> items) =>
      jsonEncode([for (final item in items) encodePhotoMealItem(item)]);

  String _payloadDigest(MealCommand command) => switch (command) {
        ReviseMeal() => jsonEncode(<String, Object?>{
            'op': 'revise',
            'expectedRevision': command.expectedRevision,
            'meal': encodePhotoMeal(command.meal),
          }),
        MoveMeal() => jsonEncode(<String, Object?>{
            'op': 'move',
            'mealId': command.mealId,
            'expectedRevision': command.expectedRevision,
            'date': command.date.toIso(),
            'today': command.today.toIso(),
          }),
        DeleteMeal() => jsonEncode(<String, Object?>{
            'op': 'delete',
            'mealId': command.mealId,
            'expectedRevision': command.expectedRevision,
          }),
        UndoMeal() => jsonEncode(<String, Object?>{
            'op': 'undo',
            'undoToken': command.undoToken,
          }),
      };
}
