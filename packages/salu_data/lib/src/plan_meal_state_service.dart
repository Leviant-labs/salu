import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import 'batch_service.dart';
import 'database/app_database.dart';
import 'repositories/drift_entry_repository.dart';
import 'snapshot_codec.dart';
import 'workspace_store.dart';
/// Feedback state for one planned meal slot.
///
/// `consumed` links the slot to a confirmed diary entry; `skipped` records
/// explicit feedback only and never writes intake.
enum PlanMealState { consumed, skipped }

/// Persisted feedback for a planned meal.
///
/// Stored in `plan-meal-state-v1` with id `<planDocumentId>|<slotId>`.
/// `selectionSignature` is the canonical JSON of
/// `{planDocumentId, slotId, date, recipeDefinitionSignature, plannedPortions}`
/// using [RecipeVersion.definitionSignature] and [Exact.toJson].
final class PlanMealStateRecord {
  const PlanMealStateRecord({
    required this.planDocumentId,
    required this.slotId,
    required this.date,
    required this.selectionSignature,
    required this.state,
    this.entryId,
    this.portions,
  });

  final String planDocumentId;
  final String slotId;
  final DiaryDate date;
  final String selectionSignature;
  final PlanMealState state;
  final String? entryId;
  final Exact? portions;

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'planDocumentId': planDocumentId,
        'slotId': slotId,
        'date': date.toIso(),
        'selectionSignature': selectionSignature,
        'state': state.name,
        if (entryId != null) 'entryId': entryId,
        if (portions != null) 'portions': portions!.toJson(),
      };

  factory PlanMealStateRecord.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1 ||
        json['planDocumentId'] is! String ||
        (json['planDocumentId']! as String).isEmpty ||
        json['slotId'] is! String ||
        (json['slotId']! as String).isEmpty ||
        json['date'] is! String ||
        json['selectionSignature'] is! String ||
        (json['selectionSignature']! as String).isEmpty) {
      throw const FormatException('Invalid plan meal state');
    }
    final state = switch (json['state']) {
      'consumed' => PlanMealState.consumed,
      'skipped' => PlanMealState.skipped,
      _ => throw const FormatException('Invalid plan meal state'),
    };
    if (state == PlanMealState.consumed &&
        (json['entryId'] is! String ||
            (json['entryId']! as String).isEmpty ||
            json['portions'] == null)) {
      throw const FormatException('Invalid plan meal state');
    }
    return PlanMealStateRecord(
      planDocumentId: json['planDocumentId']! as String,
      slotId: json['slotId']! as String,
      date: DiaryDate.parse(json['date']! as String),
      selectionSignature: json['selectionSignature']! as String,
      state: state,
      entryId: json['entryId'] as String?,
      portions: json['portions'] == null
          ? null
          : Exact.fromJson(Map<String, Object?>.from(json['portions']! as Map)),
    );
  }
}

/// Canonical selection signature for a planned slot.
String selectionSignatureFor({
  required String planDocumentId,
  required String slotId,
  required DiaryDate date,
  required RecipeVersion recipe,
  required Exact plannedPortions,
}) =>
    jsonEncode({
      'planDocumentId': planDocumentId,
      'slotId': slotId,
      'date': date.toIso(),
      'recipeDefinitionSignature': recipe.definitionSignature,
      'plannedPortions': plannedPortions.toJson(),
    });

/// Shared read/write helper for plan-meal feedback and entry links.
///
/// The repository's revise/delete/substitute paths call the cleanup entry
/// points inside their existing transactions. [consumePlannedMeal] is the
/// helper for `GuidedPlanService.consume`: it verifies plan revision and
/// signature, logs intake through [LogRecipeHandler] or
/// [BatchService.consumeAmount], and writes the consumed link in the same
/// database transaction.
final class PlanMealStateService {
  PlanMealStateService(this.db);
  final AppDatabase db;

  static String documentIdFor(String planDocumentId, String slotId) =>
      '$planDocumentId|$slotId';

  Future<PlanMealStateRecord?> read(String planDocumentId, String slotId) async {
    final row = await LocalWorkspace(db).read(
        'plan-meal-state-v1', documentIdFor(planDocumentId, slotId));
    return row == null ? null : PlanMealStateRecord.fromJson(row.data);
  }

  Future<PlanMealStateRecord?> readForEntry(String entryId) async {
    final rows = await LocalWorkspace(db).list('plan-meal-state-v1');
    for (final row in rows) {
      final record = PlanMealStateRecord.fromJson(row.data);
      if (record.entryId == entryId) return record;
    }
    return null;
  }

  Future<List<PlanMealStateRecord>> listForPlan(String planDocumentId) async {
    final rows = await LocalWorkspace(db).list('plan-meal-state-v1');
    return [
      for (final row in rows)
        if (PlanMealStateRecord.fromJson(row.data).planDocumentId ==
            planDocumentId)
          PlanMealStateRecord.fromJson(row.data)
    ];

  }

  /// Explicit skip: feedback only, never intake. Verifies the slot still
  /// holds the expected selection and refuses to overwrite a consumed link.
  Future<PlanMealStateRecord> skip({
    required String requestId,
    required String planDocumentId,
    required String slotId,
    required DiaryDate date,
    required RecipeVersion recipe,
    required Exact plannedPortions,
    required int expectedRevision,
    int? expectedPlanRevision,
  }) async {
    if (requestId.isEmpty) throw ArgumentError('A stable request id is required');
    return db.transaction(() async {
      if (expectedPlanRevision != null) {
        final planDoc = await LocalWorkspace(db).read('plan', planDocumentId);
        if (planDoc == null || planDoc.revision != expectedPlanRevision) {
          throw StateError('STALE_PLAN');
        }
        final meals = planDoc.data['meals'];
        PlannedMeal? current;
        if (meals is List) {
          for (final raw in meals) {
            final m = Map<String, Object?>.from(raw as Map);
            if (m['slot'] == slotId) {
              current = PlannedMeal(
                MealSlot(m['slot']! as String, m['date']! as String,
                    m['label']! as String),
                recipeFromSnapshot(
                    Map<String, Object?>.from(m['recipe']! as Map)),
                Exact.fromJson(
                    Map<String, Object?>.from(m['portions']! as Map)),
                pinned: m['pinned'] == true,
              );
              break;
            }
          }
        }
        if (current == null) throw StateError('PLANNED_MEAL_MISSING');
        final expected = selectionSignatureFor(
            planDocumentId: planDocumentId,
            slotId: slotId,
            date: date,
            recipe: recipe,
            plannedPortions: plannedPortions);
        final actual = selectionSignatureFor(
            planDocumentId: planDocumentId,
            slotId: current.slot.id,
            date: DiaryDate.parse(current.slot.date),
            recipe: current.recipe,
            plannedPortions: current.portions);
        if (expected != actual) throw StateError('PLAN_MEAL_CHANGED');
      }
      final prior = await read(planDocumentId, slotId);
      if (prior != null && prior.state == PlanMealState.consumed) {
        throw StateError('PLAN_MEAL_ALREADY_CONSUMED');
      }
      final signature = selectionSignatureFor(
        planDocumentId: planDocumentId,
        slotId: slotId,
        date: date,
        recipe: recipe,
        plannedPortions: plannedPortions,
      );
      final record = PlanMealStateRecord(
        planDocumentId: planDocumentId,
        slotId: slotId,
        date: date,
        selectionSignature: signature,
        state: PlanMealState.skipped,
      );
      await LocalWorkspace(db).put(
        requestId: requestId,
        collection: 'plan-meal-state-v1',
        id: documentIdFor(planDocumentId, slotId),
        expectedRevision: expectedRevision,
        data: record.toJson(),
      );
      return record;
    });
  }

  /// Removes feedback (undo-skip and stale-link cleanup). Reads the receipt
  /// first: a retry of the same request returns immediately without touching
  /// the live state row (which may have been reused for new feedback), and a
  /// request id used for another slot or expected revision conflicts.
  Future<void> undo({
    required String requestId,
    required String planDocumentId,
    required String slotId,
    required int expectedRevision,
  }) async {
    if (requestId.isEmpty) throw ArgumentError('A stable request id is required');
    await db.transaction(() async {
      final receiptId = 'undo-meal-state:$requestId';
      final prior = await (db.select(db.appliedCommands)
            ..where((t) => t.requestId.equals(receiptId)))
          .getSingleOrNull();
      if (prior != null) {
        final r = Map<String, Object?>.from(jsonDecode(prior.resultJson) as Map);
        if (r['collection'] != 'plan-meal-state-v1' ||
            r['id'] != documentIdFor(planDocumentId, slotId) ||
            r['expectedRevision'] != expectedRevision) {
          throw StateError('REQUEST_ID_REUSED');
        }
        return;
      }
      final id = documentIdFor(planDocumentId, slotId);
      final workspace = LocalWorkspace(db);
      final current = await workspace.read('plan-meal-state-v1', id);
      if (current == null) {
        if (expectedRevision != 0) throw StateError('STALE_REVISION');
        await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
          requestId: receiptId,
          resultJson: jsonEncode({
            'collection': 'plan-meal-state-v1',
            'id': id,
            'expectedRevision': expectedRevision,
            'revision': 0,
          }),
        ));
        return;
      }
      if (current.revision != expectedRevision) {
        throw StateError('STALE_REVISION');
      }
      await (db.delete(db.userDocuments)
            ..where((t) => t.collection.equals('plan-meal-state-v1') & t.id.equals(id)))
          .go();
      await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
        requestId: receiptId,
        resultJson: jsonEncode({
          'collection': 'plan-meal-state-v1',
          'id': id,
          'expectedRevision': expectedRevision,
          'revision': expectedRevision + 1,
        }),
      ));
    });
  }

  /// Clears any consumed link pointing at [entryId] (date move, deletion).
  /// Must run inside the caller's transaction; uses delete + no receipt so
  /// repeated cleanup is a no-op. No stock is returned in any case.
  Future<void> clearForEntry(String entryId) async {
    final rows = await LocalWorkspace(db).list('plan-meal-state-v1');
    for (final row in rows) {
      final record = PlanMealStateRecord.fromJson(row.data);
      if (record.entryId == entryId) {
        await (db.delete(db.userDocuments)
              ..where((t) => t.collection.equals('plan-meal-state-v1') & t.id.equals(row.id)))
            .go();
      }
    }
  }

  /// Updates recorded consumed portions after a whole-entry scaling
  /// correction. Ingredient substitution deliberately does not call this.
  Future<void> updateConsumedPortions(
      String entryId, Exact factor, Exact newPortions) async {
    final record = await readForEntry(entryId);
    if (record == null || record.state != PlanMealState.consumed) return;
    final updated = PlanMealStateRecord(
      planDocumentId: record.planDocumentId,
      slotId: record.slotId,
      date: record.date,
      selectionSignature: record.selectionSignature,
      state: record.state,
      entryId: record.entryId,
      portions: newPortions,
    );
    final row = await LocalWorkspace(db).read('plan-meal-state-v1',
        documentIdFor(record.planDocumentId, record.slotId));
    await LocalWorkspace(db).put(
      requestId: 'scale-meal-state:$entryId:${newPortions.numerator}/${newPortions.denominator}',
      collection: 'plan-meal-state-v1',
      id: documentIdFor(record.planDocumentId, record.slotId),
      expectedRevision: row?.revision ?? 0,
      data: updated.toJson(),
    );
  }

  /// intake, and writes the consumed link atomically.
  ///
  /// Batch-backed meals go through [BatchService.consumeAmount] with
  /// [EntryChannel.plan]; plain meals use [LogRecipeHandler] with the same
  /// channel. Reserved allocations are exact: a requested portion that
  /// differs from the planned portion throws `BATCH_ALLOCATION_CONFLICT`
  /// before any stock is spent. [occurredAt] is used unchanged when supplied
  /// (its offset must already match [offsetMinutes]); otherwise the clock
  /// supplies the instant. The diary day is [assignedDiaryDate] when supplied,
  /// otherwise the required [diaryDate]. A retry replays from the stored
  /// request fingerprint before any live stale checks.
  Future<LoggedEntry> consumePlannedMeal({
    required String requestId,
    required PlannedMeal meal,
    required String planDocumentId,
    required int expectedPlanRevision,
    required int expectedStateRevision,
    required Exact portions,
    required EventStamp stamp,
    required int offsetMinutes,
    required DiaryDate diaryDate,
    required Clock clock,
    required IdGenerator ids,
    AppDatabase? dbOverride,
    EventStamp? occurredAt,
    DiaryDate? assignedDiaryDate,
  }) async {
    if (requestId.isEmpty || !portions.positive) {
      throw ArgumentError('A stable request id and positive portions are required');
    }
    if (stamp.offsetMinutes != offsetMinutes) {
      throw StateError('INVALID_TIME_OFFSET');
    }
    if (occurredAt != null && occurredAt.offsetMinutes != offsetMinutes) {
      throw StateError('INVALID_TIME_OFFSET');
    }
    final effectiveStamp = occurredAt ?? stamp;
    final effectiveDay = assignedDiaryDate ?? diaryDate;
    // Semantic fingerprint binds only the caller's arguments (plan slot,
    // expected plan revision, portions, stamp, diary day). Derived state
    // (expectedStateRevision, recipe/batch identity) is verified for the
    // first write but never fingerprinted, so a retry that re-reads state
    // or meal selection still replays the original entry.
    final fingerprint = <String, Object?>{
      'planDocumentId': planDocumentId,
      'slotId': meal.slot.id,
      'expectedPlanRevision': expectedPlanRevision,
      'portions': portions.toJson(),
      'stamp': {
        'utc': effectiveStamp.instantUtc.toIso8601String(),
        'offset': effectiveStamp.offsetMinutes,
      },
      'offsetMinutes': offsetMinutes,
      'diaryDate': effectiveDay.toIso(),
    };
    return db.transaction(() async {
      // Replay first, before any live stale checks: a retry after the plan
      // was edited must return the original entry, not fail STALE_PLAN.
      final priorReceipt = await (db.select(db.appliedCommands)
            ..where((t) => t.requestId.equals(requestId)))
          .getSingleOrNull();
      if (priorReceipt != null) {
        final decoded = jsonDecode(priorReceipt.resultJson);
        if (decoded is! Map) throw StateError('REQUEST_ID_REUSED');
        final stored = Map<String, Object?>.from(decoded);
        if (stored['mealConsumeFingerprint'] != jsonEncode(fingerprint)) {
          throw StateError('REQUEST_ID_REUSED');
        }
        final prior = await DriftEntryRepository(db).findByRequestId(requestId);
        if (prior == null) throw StateError('MEAL_CONSUMPTION_MISSING');
        return prior;
      }
      final workspace = LocalWorkspace(db);
      final planDoc = await workspace.read('plan', planDocumentId);
      if (planDoc == null || planDoc.revision != expectedPlanRevision) {
        throw StateError('STALE_PLAN');
      }
      final meals = planDoc.data['meals'];
      PlannedMeal? current;
      if (meals is List) {
        for (final raw in meals) {
          final m = Map<String, Object?>.from(raw as Map);
          if (m['slot'] == meal.slot.id) {
            final recipe = recipeFromSnapshot(
                Map<String, Object?>.from(m['recipe']! as Map));
            final useData = m['batchUse'];
            current = PlannedMeal(
              MealSlot(m['slot']! as String, m['date']! as String,
                  m['label']! as String),
              recipe,
              Exact.fromJson(Map<String, Object?>.from(m['portions']! as Map)),
              pinned: m['pinned'] == true,
              batchUse: useData == null
                  ? null
                  : PlannedBatchUse(
                      (useData as Map)['batchId']! as String,
                      (useData['batchRevision']! as int),
                      useData['allocationId']! as String),
            );
            break;
          }
        }
      }
      if (current == null) throw StateError('PLANNED_MEAL_MISSING');
      final expectedSignature = selectionSignatureFor(
        planDocumentId: planDocumentId,
        slotId: meal.slot.id,
        date: DiaryDate.parse(meal.slot.date),
        recipe: meal.recipe,
        plannedPortions: meal.portions,
      );
      final currentSignature = selectionSignatureFor(
        planDocumentId: planDocumentId,
        slotId: current.slot.id,
        date: DiaryDate.parse(current.slot.date),
        recipe: current.recipe,
        plannedPortions: current.portions,
      );
      if (expectedSignature != currentSignature) {
        throw StateError('PLAN_MEAL_CHANGED');
      }
      final prior = await read(planDocumentId, meal.slot.id);
      if (prior != null && prior.state == PlanMealState.consumed) {
        throw StateError('PLAN_MEAL_ALREADY_CONSUMED');
      }

      final LoggedEntry entry;
      final batchUse = meal.batchUse;
      if (batchUse != null) {
        final batchDoc = await workspace.read('batch', batchUse.batchId);
        if (batchDoc == null) throw StateError('STALE_BATCH');
        final unit = FoodUnit.values.byName(batchDoc.data['unit']! as String);
        // Exact reserved amounts are finite: the requested portions must
        // equal the planned portions exactly, or the reservation conflicts.
        // (BatchService would throw BATCH_RESERVATION_MISMATCH; surface the
        // explicit conflict here before spending anything.)
        if (portions != meal.portions) {
          throw StateError('BATCH_ALLOCATION_CONFLICT');
        }
        final amount = unit == FoodUnit.g
            ? _batchGrams(batchDoc.data, portions)
            : portions;
        entry = await BatchService(db, clock, ids).consumeAmount(
          requestId: requestId,
          batchId: batchUse.batchId,
          expectedRevision: batchDoc.revision,
          amount: amount,
          unit: unit,
          offsetMinutes: offsetMinutes,
          confirmed: true,
          reservedAllocationId: batchUse.allocationId,
          channel: EntryChannel.plan,
          occurredAt: effectiveStamp,
          assignedDiaryDate: effectiveDay,
        );
      } else {
        entry = await LogRecipeHandler(DriftEntryRepository(db), clock, ids)
            .handle(LogRecipeCommand(
          requestId: requestId,
          recipe: meal.recipe,
          portions: portions,
          offsetMinutes: offsetMinutes,
          confirmed: true,
          channel: EntryChannel.plan,
          occurredAt: effectiveStamp,
          assignedDiaryDate: effectiveDay,
        ));
      }
      final record = PlanMealStateRecord(
        planDocumentId: planDocumentId,
        slotId: meal.slot.id,
        date: DiaryDate.parse(meal.slot.date),
        selectionSignature: currentSignature,
        state: PlanMealState.consumed,
        entryId: entry.id,
        portions: portions,
      );
      await workspace.put(
        requestId: 'meal-state:$requestId',
        collection: 'plan-meal-state-v1',
        id: documentIdFor(planDocumentId, meal.slot.id),
        expectedRevision: expectedStateRevision,
        data: record.toJson(),
      );
      await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
        requestId: requestId,
        resultJson: jsonEncode({
          'mealConsumeFingerprint': jsonEncode(fingerprint),
          'entryId': entry.id,
        }),
      ));
      return entry;
    });
  }

  static Exact _batchGrams(Map<String, Object?> batchData, Exact portions) {
    final finished = batchData['finishedWeightG'];
    if (finished == null) throw StateError('PLAN_BATCH_INVALID');
    final finishedWeight =
        Exact.fromJson(Map<String, Object?>.from(finished as Map));
    final batchRecipe = recipeFromSnapshot(
        Map<String, Object?>.from(batchData['recipe']! as Map));
    return finishedWeight * portions / batchRecipe.servings;
  }
}

