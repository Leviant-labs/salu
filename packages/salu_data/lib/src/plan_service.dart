import 'dart:convert';

import 'package:salu_core/salu_core.dart';

import 'batch_service.dart';
import 'codec.dart';
import 'database/app_database.dart';
import 'document_validation.dart';
import 'snapshot_codec.dart';
import 'workspace_store.dart';

/// Feature-level rejection for a plan save. [code] is stable for UI branching;
/// [message] is safe to show beside a retry action.
final class PlanException implements Exception {
  const PlanException(this.code, this.message, [this.cause]);
  final String code, message;
  final Object? cause;
  @override
  String toString() => message;
}

/// The persisted plan and its optimistic revision.
final class StoredPlan {
  StoredPlan._({
    required this.documentId,
    required this.revision,
    required List<PlannedMeal> meals,
    required this.seed,
    required this.policyVersion,
    required Map<String, Object?> document,
    this.conditionGuidance,
  })  : meals = List.unmodifiable(meals),
        document = Map.unmodifiable(document);
  final int revision;
  final String documentId;
  final List<PlannedMeal> meals;
  final int seed;
  final String policyVersion;

  /// Policy inputs the plan was generated under, or null for a legacy plan
  /// that predates condition-aware planning. Malformed input fails the load.
  final ConditionGuidanceInput? conditionGuidance;

  /// The exact stored payload, including unknown legacy/newer metadata.
  final Map<String, Object?> document;
}

/// Outcome of one committed plan save.
final class PlanSaveResult {
  PlanSaveResult._({
    required this.documentId,
    required this.revision,
    required List<PlannedMeal> meals,
    required Map<String, int> batchRevisions,
    required Map<String, Object?> document,
    this.conditionGuidance,
  })  : meals = List.unmodifiable(meals),
        batchRevisions = Map.unmodifiable(batchRevisions),
        document = Map.unmodifiable(document);
  final int revision;
  final String documentId;

  /// Policy inputs recorded by this save, if the caller supplied them.
  final ConditionGuidanceInput? conditionGuidance;

  /// The persisted meals with every [PlannedBatchUse.batchRevision] refreshed
  /// to the batch revision written by this save.
  final List<PlannedMeal> meals;

  /// Final revisions for every batch referenced by the plan or released by it.
  final Map<String, int> batchRevisions;
  final Map<String, Object?> document;
}

/// A validated persisted plan schedule with its effective slots.
///
/// Slots are generated as `'$label:$index'` with date `startDate + index`.
/// `excludedSlotIds` may omit some of those generated slots, but it never
/// renumbers, re-dates or shortens the generated schedule: a retained slot
/// keeps its original id and date, so retained meals, pins and reservations do
/// not move. Missing `excludedSlotIds` is the legacy form and means no
/// exclusions. Malformed, duplicate, foreign-label or out-of-range ids fail
/// closed; exclusions are only meaningful inside the matching generated
/// schedule.
final class PlanSchedule {
  PlanSchedule._({
    required this.startDate,
    required this.days,
    required this.labels,
    required List<String> excludedSlotIds,
    required List<MealSlot> generatedSlots,
  })  : excludedSlotIds = List.unmodifiable(excludedSlotIds),
        generatedSlots = List.unmodifiable(generatedSlots),
        slots = List.unmodifiable([
          for (final slot in generatedSlots)
            if (!excludedSlotIds.contains(slot.id)) slot
        ]);

  /// Parses persisted `schedule` metadata and applies its exclusions.
  ///
  /// Returns null when [rawSchedule] is null (a legacy plan without persisted
  /// schedule metadata). A present but invalid schedule throws
  /// [PlanException] `PLAN_CONTEXT_INVALID`; callers must not fall back to a
  /// permissive interpretation.
  static PlanSchedule? fromMetadata(Object? rawSchedule) {
    if (rawSchedule == null) return null;
    if (rawSchedule is! Map) {
      throw const PlanException(
          'PLAN_CONTEXT_INVALID', 'The persisted plan schedule is invalid.');
    }
    final schedule = Map<String, Object?>.from(rawSchedule);
    final startRaw = schedule['startDate'];
    final daysRaw = schedule['days'];
    final version = schedule['schemaVersion'];
    final legacy = version == null || version == 1;
    final labelRaw = schedule['label'];
    final labelsRaw = legacy ? [labelRaw] : schedule['labels'];
    if ((!legacy && version != 2) ||
        startRaw is! String || daysRaw is! int ||
        daysRaw < 1 || daysRaw > 366 || labelsRaw is! List ||
        labelsRaw.isEmpty ||
        labelsRaw.any((value) => value is! String ||
            value.trim().isEmpty ||
            (!legacy && !const ['breakfast','lunch','snack','dinner']
                .contains(value))) ||
        labelsRaw.toSet().length != labelsRaw.length) {
      throw const PlanException(
          'PLAN_CONTEXT_INVALID', 'The persisted plan schedule is invalid.');
    }
    late final DiaryDate start;
    try {
      start = DiaryDate.parse(startRaw);
    } catch (error) {
      throw PlanException('PLAN_CONTEXT_INVALID',
          'The persisted plan start date is invalid.', error);
    }
    final labels = labelsRaw.cast<String>();
    final generated = [
      for (var index = 0; index < daysRaw; index++)
        for (final label in labels)
          MealSlot(legacy ? '$label:$index' :
              '${start.addDays(index).toIso()}:$label',
              start.addDays(index).toIso(), label)
    ];
    final generatedIds = {for (final slot in generated) slot.id};
    final rawExcluded = schedule['excludedSlotIds'];
    final excluded = <String>[];
    if (schedule.containsKey('excludedSlotIds')) {
      if (rawExcluded is! List) {
        throw const PlanException('PLAN_CONTEXT_INVALID',
            'The persisted excluded plan slots are invalid.');
      }
      final seen = <String>{};
      for (final value in rawExcluded) {
        if (value is! String ||
            !generatedIds.contains(value) ||
            !seen.add(value)) {
          throw const PlanException('PLAN_CONTEXT_INVALID',
              'The persisted excluded plan slots are invalid.');
        }
        excluded.add(value);
      }
    }
    return PlanSchedule._(
      startDate: start.toIso(),
      days: daysRaw,
      labels: List.unmodifiable(labels),
      excludedSlotIds: excluded,
      generatedSlots: generated,
    );
  }

  final String startDate;
  final int days;
  final List<String> labels;

  /// The valid exclusions, in persisted order, each naming one generated slot.
  final List<String> excludedSlotIds;

  /// Every generated slot, including excluded ones, in date order.
  final List<MealSlot> generatedSlots;

  /// Generated slots that remain effective after exclusions, in date order.
  final List<MealSlot> slots;

  List<String> get generatedSlotIds =>
      [for (final slot in generatedSlots) slot.id];

  bool get hasRetainedSlots => slots.isNotEmpty;
}

/// Saves future meals and their cooked-stock reservations as one transaction.
///
/// A planned meal is never intake: this service never writes diary entries.
/// Reservations are derived from each meal's [PlannedBatchUse] and diffed
/// against the stored plan, so a reservation cannot exist without exactly one
/// planned use and a removed meal releases only unspent stock.
///
/// A reservation's amount is expressed in the batch's own stock unit: grams
/// computed from the measured finished yield for a gram batch, or the meal's
/// exact recipe portions for a serving batch. Serving stock is never converted
/// to a guessed gram amount; unsupported batch units fail closed.
///
/// A persisted `schedule` may carry `excludedSlotIds`: generated `'$label:$i'`
/// slots removed from the effective schedule. Exclusions never renumber,
/// re-date or shorten retained slots, so retained meals, pins and reservations
/// do not move. They are validated at commit time, require a newer
/// `constraintRevision` when changed, and a removed meal releases only its
/// unspent stock.
///
/// A persisted `constraints.unavailableFoodIds` list is the user's explicit
/// hard availability declaration. Every planned meal, including a retained or
/// pinned one, is validated against it at commit; a recipe containing a
/// declared-unavailable food fails the save as `PLAN_CONSTRAINT_CONFLICT` with
/// `INGREDIENT_UNAVAILABLE`. The declaration is never inferred and is only
/// relaxed by an explicit, revised save that removes the food id.
///
/// Consumed allocations are accounting records, not reservations. A kept use
/// that has already been consumed stays in the plan exactly once; it is never
/// released or re-reserved. A new use cannot claim a consumed allocation.
///
/// Legacy batch documents produced before reservation ids were stable re-keyed
/// the allocation to the intake request id. Such a use is reconciled only when
/// a diary item's `sourceSnapshot.reservedAllocationId` verifiably identifies
/// the consumed allocation for the same batch, frozen stock unit and amount;
/// otherwise the save fails closed.
final class PlanService {
  PlanService(this.db, this.clock, this.ids, {this.documentId = 'current'}) {
    if (documentId.isEmpty) throw ArgumentError('Empty plan document ID');
  }
  final String documentId;
  final AppDatabase db;
  final Clock clock;
  final IdGenerator ids;

  static const _collection = 'plan';
  String get _document => documentId;
  static const _savePrefix = 'plan-save:';
  static const _reservePrefix = 'plan-reserve:';
  static const _releasePrefix = 'plan-release:';


  /// Reads the current plan, or null when nothing has been planned yet.
  Future<StoredPlan?> load() async {
    final doc = await LocalWorkspace(db).read(_collection, _document);
    return doc == null ? null : _stored(doc.revision, doc.data);
  }

  /// The effective current definition for every ingredient in [recipes],
  /// exactly as [save] will validate the plan's ingredients.
  ///
  /// A present `catalog_foods` row is current for every provenance, so a
  /// changed allergen, nutrient, preparation or basis fails as
  /// `INGREDIENT_STALE`. An absent row is omitted and becomes
  /// `INGREDIENT_UNRESOLVED`: recipe snapshot provenance strings are not
  /// accepted as ownership proof. Debug, fixture, imported and custom records
  /// must therefore be preserved as real catalogue rows.
  /// Pass the result to [PlannerContext.currentFoods] to surface these before
  /// the commit.
  ///
  /// Throws [PlanException] `PLAN_INGREDIENT_INVALID` when stored catalogue
  /// safety data is unreadable; callers must not fall back to a permissive
  /// definition.
  Future<Map<String, Food>> currentFoodsForRecipes(
          Iterable<RecipeVersion> recipes) async =>
      Map<String, Food>.unmodifiable(await _currentFoodsForRecipes(recipes));

  /// Reads the current `health-declaration/current` document as policy inputs.
  ///
  /// A missing document means no declarations. An unsupported schema or a
  /// malformed condition value fails closed as `PLAN_CONDITION_INVALID`
  /// instead of being read as "no conditions". No condition is inferred.
  Future<ConditionGuidanceInput> readConditionGuidanceInput() async {
    try {
      final doc =
          await LocalWorkspace(db).read('health-declaration', 'current');
      return ConditionGuidanceInput.fromDeclarationDocument(doc?.data);
    } catch (error) {
      throw PlanException(
          'PLAN_CONDITION_INVALID',
          'The stored health declarations are invalid; review them in Settings before planning.',
          error);
    }
  }

  /// Saves [meals] against [expectedPlanRevision] and reserves/releases cooked
  /// stock in the same database transaction.
  ///
  /// [metadata] preserves or replaces arbitrary top-level plan fields such as a
  /// schedule, constraint revision or accepted-relaxation list. Values must be
  /// JSON-encodable. Keys owned by this service (`meals`, `seed`,
  /// `policyVersion`) cannot be overridden through it. Existing top-level keys
  /// are retained unless overwritten.
  ///
  /// `conditionGuidance` records the declaration inputs the caller planned
  /// under. When `health-declaration/current` declares a condition, a save
  /// without that block fails as `PLAN_CONDITION_INPUT_REQUIRED`; a block whose
  /// declaration fingerprint differs from the current document fails as
  /// `PLAN_CONDITION_INPUT_STALE`; an older `policyVersion` fails as
  /// `PLAN_CONDITION_POLICY_MISMATCH`. Conditions stay soft guidance and never
  /// become a hard constraint or a safety claim.
  ///
  /// `constraints.unavailableFoodIds` is the user's explicit hard availability
  /// declaration: an optional unique list of nonempty food ids, where missing
  /// means none. The effective list is validated against every planned meal at
  /// commit, including meals retained from the stored plan, and a violation
  /// fails as `PLAN_CONSTRAINT_CONFLICT` with `INGREDIENT_UNAVAILABLE`. A save
  /// that omits `constraints` entirely keeps the persisted declaration; a save
  /// that replaces `constraints` without the key declares none, which changes
  /// the hard-context fingerprint and therefore requires a newer
  /// `constraintRevision`. Reordering the ids is not a change, and an explicit
  /// empty list is the same reviewed state as a missing key.
  ///
  /// An identical retry of the same [requestId] returns the originally
  /// committed result even after later writes; any different argument with that
  /// id throws [PlanException] `REQUEST_ID_REUSED`.
  ///
  /// A newly selected batch use must carry the batch revision it was read at;
  /// otherwise the save fails closed with `STALE_BATCH`. A use retained from
  /// the stored plan may carry an older live revision and is refreshed.
  Future<PlanSaveResult> save({
    required String requestId,
    required int expectedPlanRevision,
    required List<PlannedMeal> meals,
    int? expectedProfileRevision,
    Map<String, Object?> metadata = const {},
    int? seed,
    String? policyVersion,
  }) async {
    if (requestId.isEmpty) {
      throw ArgumentError('A stable request id is required');
    }
    if (expectedPlanRevision < 0) {
      throw ArgumentError('A plan revision cannot be negative');
    }
    final meta = Map<String, Object?>.unmodifiable(metadata);
    for (final key in meta.keys) {
      if (key == 'meals' || key == 'seed' || key == 'policyVersion') {
        throw ArgumentError('Metadata cannot override $key');
      }
    }
    final input = List<PlannedMeal>.unmodifiable(meals);
    _checkRequest(input);
    final fingerprint = _fingerprint(
        expectedPlanRevision: expectedPlanRevision,
        expectedProfileRevision: expectedProfileRevision,
        meals: input,
        metadata: meta,
        seed: seed,
        policyVersion: policyVersion);
    return _translate(() => db.transaction(() async {
          final replayed = await _replay(requestId, fingerprint);
          if (replayed != null) return replayed;

          final workspace = LocalWorkspace(db);
          if (expectedProfileRevision != null &&
              (await workspace.read('nutrition-profile-v1', 'current'))
                      ?.revision != expectedProfileRevision) {
            if (expectedProfileRevision != 0 ||
                await workspace.read('nutrition-profile-v1', 'current') != null) {
              throw const PlanException('PLAN_PROFILE_STALE',
                  'Your preferences changed; review the plan again.');
            }
          }
          final proposedAllocations = {
            for (final meal in input)
              if (meal.batchUse != null) _useKey(meal.batchUse!)
          };
          for (final other in await workspace.list(_collection)) {
            if (other.id == documentId) continue;
            if (_priorUses(other).any(
                (use) => proposedAllocations.contains(_useKey(use)))) {
              throw const PlanException('BATCH_ALLOCATION_ALREADY_PLANNED',
                  'This batch allocation belongs to another plan.');
            }
          }
          final prior = await workspace.read(_collection, _document);
          if ((prior?.revision ?? 0) != expectedPlanRevision) {
            throw const PlanException(
                'STALE_PLAN', 'The plan changed since it was loaded; reload and retry.');
          }

          // The effective hard context is the persisted plan metadata plus the
          // reviewed metadata in this save. A change to it must be a new
          // explicit constraint revision, otherwise the save fails closed.
          final effectiveMeta = <String, Object?>{...?prior?.data};
          for (final entry in meta.entries) {
            effectiveMeta[entry.key] = entry.value;
          }
          if (effectiveMeta['guided'] != null) {
            final proposed = PlanSchedule.fromMetadata(effectiveMeta['schedule']);
            if (proposed == null) {
              throw const PlanException('PLAN_CONTEXT_INVALID',
                  'A guided plan requires a dated schedule.');
            }
            final dates = proposed.generatedSlots.map((slot) => slot.date).toSet();
            for (final other in await workspace.list(_collection)) {
              if (other.id == documentId || !other.id.startsWith('week:')) continue;
              final schedule = PlanSchedule.fromMetadata(other.data['schedule']);
              if (schedule != null && schedule.generatedSlots
                  .any((slot) => dates.contains(slot.date))) {
                throw const PlanException('PLAN_PERIOD_OVERLAP',
                    'Another guided week already covers these dates.');
              }
            }
          }
          _validateConstraintInput(effectiveMeta['constraints']);
          _checkContextRevision(prior, effectiveMeta);
          final conditionInput = await readConditionGuidanceInput();
          _checkConditionInput(
              effectiveMeta['conditionGuidance'], conditionInput);

          final priorUses = _priorUses(prior);
          final priorUseMaps = _priorUseMaps(prior);
          final newUseKeys = {
            for (final meal in input)
              if (meal.batchUse != null) _useKey(meal.batchUse!)
          };
          final revisions = <String, int>{};
          final baselines = <String, int>{};

          // Release unspent stock first so an in-place meal replacement can
          // reuse the stock freed by the removed allocation.
          for (final use in priorUses) {
            if (newUseKeys.contains(_useKey(use))) continue;
            await _release(requestId, use, revisions, baselines);
          }

          final resolved = List<PlannedBatchUse?>.filled(input.length, null);
          final retainedUses = List<bool>.filled(input.length, false);
          for (var i = 0; i < input.length; i++) {
            final meal = input[i];
            final use = meal.batchUse;
            if (use == null) continue;
            final retained =
                priorUses.any((priorUse) => _useKey(priorUse) == _useKey(use));
            retainedUses[i] = retained;
            resolved[i] = await _resolveUse(
                requestId: requestId,
                meal: meal,
                use: use,
                retained: retained,
                revisions: revisions,
                baselines: baselines);
          }

          // Read every referenced batch once more so the persisted use points
          // at the revision this transaction actually leaves behind.
          final refreshed = <PlannedMeal>[];
          final batchViews = <String, _BatchView>{};
          for (var i = 0; i < input.length; i++) {
            final meal = input[i];
            final use = resolved[i];
            if (use == null) {
              refreshed.add(meal);
              continue;
            }
            final batch = await _readBatch(use.batchId);
            if (batch == null) {
              throw const PlanException('PLAN_BATCH_MISSING',
                  'The cooked batch for this meal no longer exists.');
            }
            batchViews[batch.id] = batch;
            final expected = _expectedAmount(batch, meal);
            final allocation = batch.allocation(use.allocationId);
            if (allocation == null) {
              throw const PlanException('PLAN_BATCH_ALLOCATION_MISSING',
                  'The batch reservation for this meal is gone; remove the meal or choose a new allocation.');
            }
            if (allocation.consumed) {
              // A kept use stays accounted exactly once and is not re-reserved.
              if (!retainedUses[i]) {
                throw const PlanException('PLAN_BATCH_USE_CONSUMED',
                    'This allocation was already consumed; choose unspent stock for a new planned meal.');
              }
            } else if (!allocation.planned) {
              throw const PlanException('PLAN_BATCH_ALLOCATION_MISMATCH',
                  'The batch allocation has an unsupported state.');
            }
            if (allocation.amount != expected.amount) {
              throw const PlanException('PLAN_BATCH_ALLOCATION_MISMATCH',
                  'The batch reservation no longer matches this meal; release and reserve a new allocation.');
            }
            revisions[batch.id] = batch.revision;
            refreshed.add(PlannedMeal(meal.slot, meal.recipe, meal.portions,
                pinned: meal.pinned,
                batchUse:
                    PlannedBatchUse(batch.id, batch.revision, use.allocationId)));
          }

          // The plan may have changed while this transaction was reserving.
          final latest = await workspace.read(_collection, _document);
          if ((latest?.revision ?? 0) != expectedPlanRevision) {
            throw const PlanException(
                'STALE_PLAN', 'The plan changed while it was being saved; reload and retry.');
          }
          final data = <String, Object?>{...effectiveMeta};
          final priorSeed = prior?.data['seed'];
          final priorPolicy = prior?.data['policyVersion'];
          data['seed'] = seed ?? (priorSeed is int ? priorSeed : 7);
          data['policyVersion'] = policyVersion ??
              (priorPolicy is String ? priorPolicy : 'planner-v3');
          data['meals'] = [
            for (final meal in refreshed) _mealJson(meal, priorUseMaps)
          ];
          validateUserDocument(_collection, data);
          final revision = expectedPlanRevision + 1;
          // Acquire the write lock before the final context read: a concurrent
          // catalogue or recipe change that committed earlier is visible, and
          // one that has not committed cannot slip in between validation and
          // the plan write. A failed validation rolls this write back.
          await db.into(db.userDocuments).insertOnConflictUpdate(
              UserDocumentsCompanion.insert(
                  collection: _collection,
                  id: _document,
                  revision: revision,
                  payload: jsonEncode(data)));
          await _validateCommit(
            document: data,
            meals: refreshed,
            batches: batchViews,
            seed: data['seed']! as int,
            policyVersion: data['policyVersion']! as String,
          );

          final result = PlanSaveResult._(
              documentId: documentId,
              revision: revision,
              meals: refreshed,
              batchRevisions: revisions,
              document: data,
              conditionGuidance:
                  _conditionInputOrNull(data['conditionGuidance']));
          await _record(requestId, fingerprint, result);
          return result;
        }));
  }

  /// The persisted plan's hard context plus reviewed metadata may only change
  /// with a strictly newer explicit constraint revision.
  ///
  /// `excludedSlotIds` is part of the reviewed schedule. Replacing a schedule
  /// that had exclusions with a new schedule object must name the reviewed
  /// exclusion list explicitly (an empty list resets it); silently dropping the
  /// key or the whole schedule is rejected because it could move retained meals
  /// or pins. `unavailableFoodIds` is a reviewed hard constraint too: missing
  /// and empty lists mean none, so dropping the persisted declaration changes
  /// the fingerprint and requires a newer revision before a meal may use the
  /// food again.
  void _checkContextRevision(
      StoredDocument? prior, Map<String, Object?> effective) {
    if (prior == null) return;
    final priorData = prior.data;
    final hasContext = priorData.containsKey('schedule') ||
        priorData.containsKey('constraints') ||
        priorData.containsKey('constraintRevision') ||
        priorData.containsKey('acceptedRelaxations');
    if (!hasContext) return;
    if (_hasExclusions(priorData['schedule'])) {
      final effectiveSchedule = effective['schedule'];
      if (effectiveSchedule is! Map) {
        throw const PlanException('PLAN_CONTEXT_INVALID',
            'The plan schedule cannot be removed while excluded slots exist; explicitly reset or reconcile excluded slots.');
      }
      if (!effectiveSchedule.containsKey('excludedSlotIds')) {
        throw const PlanException('PLAN_CONTEXT_INVALID',
            'The plan schedule changed without explicitly resetting or reconciling excluded slots; save the reviewed exclusions.');
      }
    }
    if (_hardContextFingerprint(priorData) ==
        _hardContextFingerprint(effective)) {
      return;
    }
    if (_constraintRevision(effective) <= _constraintRevision(priorData)) {
      throw const PlanException('PLAN_CONSTRAINT_REVISION_REQUIRED',
          'Hard planning constraints changed without a new constraint revision; review and save a new revision.');
    }
  }

  bool _hasExclusions(Object? schedule) {
    if (schedule is! Map) return false;
    final raw = schedule['excludedSlotIds'];
    return raw is List && raw.isNotEmpty;
  }

  int _constraintRevision(Map<String, Object?> data) {
    final value = data['constraintRevision'];
    if (value == null) return 1;
    if (value is int && value >= 1) return value;
    throw const PlanException(
        'PLAN_CONTEXT_INVALID', 'The persisted constraint revision is invalid.');
  }

  String _hardContextFingerprint(Map<String, Object?> data) =>
      jsonEncode(_canonical({
        'schedule': _canonicalSchedule(data['schedule']),
        'constraints': _canonicalConstraints(data['constraints']),
        'acceptedRelaxations': data['acceptedRelaxations'],
        'constraintRevision': data['constraintRevision'],
        if (data['guided'] case final Map guided)
          'guidedHard': {
            'dietaryTags': (guided['profileSnapshot'] as Map?)?['dietaryTags'],
            'avoidedFoodIds': (guided['profileSnapshot'] as Map?)?['avoidedFoodIds'],
            'coldLunches': (guided['profileSnapshot'] as Map?)?['coldLunches'],
            'maximumCookingMinutes':
                (guided['profileSnapshot'] as Map?)?['maximumCookingMinutes'],
            'recipeIdsBySlot': guided['recipeIdsBySlot'],
            'cookingMinutesBySlot': guided['cookingMinutesBySlot'],
          },
      }));

  /// Treats missing, empty and reordered `unavailableFoodIds` lists as the
  /// same reviewed hard constraint. An absent constraints object and an empty
  /// one both declare no constraints. Malformed values stay verbatim so
  /// repairing them still requires a new revision.
  Object? _canonicalConstraints(Object? rawConstraints) {
    if (rawConstraints == null) return const <String, Object?>{};
    if (rawConstraints is! Map) return rawConstraints;
    final constraints = Map<String, Object?>.from(rawConstraints);
    if (!constraints.containsKey('unavailableFoodIds')) return constraints;
    final rawIds = constraints['unavailableFoodIds'];
    if (rawIds is! List) return constraints;
    if (rawIds.isEmpty) {
      constraints.remove('unavailableFoodIds');
      return constraints;
    }
    if (rawIds.every((value) => value is String)) {
      constraints['unavailableFoodIds'] =
          rawIds.cast<String>().toList()..sort();
    }
    return constraints;
  }

  /// Treats missing, empty and reordered exclusion lists as the same reviewed
  /// schedule. Malformed values stay verbatim so repairing them still requires
  /// a new revision.
  Object? _canonicalSchedule(Object? rawSchedule) {
    if (rawSchedule is! Map) return rawSchedule;
    final schedule = Map<String, Object?>.from(rawSchedule);
    final rawExcluded = schedule['excludedSlotIds'];
    if (rawExcluded is! List) return schedule;
    if (rawExcluded.isEmpty) {
      schedule.remove('excludedSlotIds');
      return schedule;
    }
    if (rawExcluded.every((value) => value is String)) {
      schedule['excludedSlotIds'] = rawExcluded.cast<String>().toList()..sort();
    }
    return schedule;
  }

  Future<void> _validateCommit({
    required Map<String, Object?> document,
    required List<PlannedMeal> meals,
    required Map<String, _BatchView> batches,
    required int seed,
    required String policyVersion,
  }) async {
    final safety = await _readSafetyProfile();
    // Re-read while the plan write holds the lock. An edit to the declarations
    // committed after the caller planned must not be recorded as if the meals
    // were generated under it.
    final conditionInput = await readConditionGuidanceInput();
    _checkConditionInput(document['conditionGuidance'], conditionInput);
    late final ConditionGuidanceAssessment conditionAssessment;
    try {
      conditionAssessment = ConditionGuidancePolicy.assess(
          input: conditionInput,
          strictExclusions: safety.strictExclusions,
          eatingConcern: safety.eatingConcern == true);
    } catch (error) {
      throw PlanException('PLAN_CONDITION_INVALID',
          'The stored health declarations cannot be assessed; review them before planning.',
          error);
    }
    final recipes = await _readRecipesFor(meals);
    final currentFoods = await _currentFoodsFor(meals);
    // Re-read referenced batches while the plan row write holds the database
    // write lock, so a concurrent reserve/consume/release cannot be masked by
    // the views read earlier in this save.
    final freshBatches = <String, _BatchView>{};
    for (final id in batches.keys) {
      final batch = await _readBatch(id);
      if (batch != null) freshBatches[id] = batch;
    }
    final parts = _contextParts(document, meals);
    late final List<CookedBatch> cooked;
    try {
      cooked = [for (final batch in freshBatches.values) batch.cookedBatch];
    } catch (error) {
      throw PlanException('PLAN_BATCH_INVALID',
          'A referenced cooked batch is invalid; review it before planning.',
          error);
    }
    late final PlannerContext context;
    NutritionProfile? guidedProfile;
    final allowedBySlot = <String, Set<String>>{};
    final goals = <NutrientKey, Exact>{};
    final rawGuided = document['guided'];
    if (rawGuided != null) {
      if (rawGuided is! Map || rawGuided['schemaVersion'] != 1) {
        throw const PlanException('PLAN_CONTEXT_INVALID',
            'The reviewed meal profile is invalid.');
      }
      guidedProfile = NutritionProfile.fromJson(
          Map<String, Object?>.from(rawGuided['profileSnapshot'] as Map));
      final persisted = Map<String, Object?>.from(
          rawGuided['recipeIdsBySlot'] as Map);
      final caps = Map<String, Object?>.from(
          rawGuided['cookingMinutesBySlot'] as Map? ?? {});
      final content = {
        for (final row in await LocalWorkspace(db).list('meal-content-v1'))
          row.id: row.data
      };
      for (final slot in parts.slots) {
        final narrowed = persisted[slot.id];
        if (narrowed is! List || narrowed.any((id) => id is! String)) {
          throw const PlanException('PLAN_CONTEXT_INVALID',
              'Meal candidates are missing from the reviewed plan.');
        }
        final cap = caps[slot.id];
        if (cap != null && (cap is! int || cap < 1)) {
          throw const PlanException('PLAN_CONTEXT_INVALID',
              'A meal preparation limit is invalid.');
        }
        allowedBySlot[slot.id] = {
          for (final recipe in recipes)
            if (narrowed.contains(recipe.id) &&
                content[recipe.id]?['revision'] == recipe.revision &&
                (content[recipe.id]?['mealLabels'] as List? ?? [])
                    .contains(slot.label) &&
                (!guidedProfile.coldLunches || slot.label != 'lunch' ||
                    content[recipe.id]?['coldSuitable'] == true) &&
                (cap == null || recipe.minutes <= (cap as int)) &&
                (guidedProfile.maximumCookingMinutes == null ||
                    recipe.minutes <= guidedProfile.maximumCookingMinutes!))
              recipe.id
        };
      }
      final rawGoals = rawGuided['targetGoals'] as Map? ?? {};
      for (final entry in rawGoals.entries) {
        goals[NutrientKey.values.singleWhere((key) => key.wire == entry.key)] =
            Exact.fromJson(Map<String, Object?>.from(entry.value as Map));
      }
    }
    try {
      context = PlannerContext(
        slots: parts.slots,
        recipes: recipes,
        seed: seed,
        policyVersion: policyVersion,
        maximumMinutes: parts.constraints.maximumMinutes,
        maximumRepeats: parts.constraints.maximumRepeats,
        strictExclusions: safety.strictExclusions,
        dietaryTags: guidedProfile?.dietaryTags ?? const {},
        recipeIdsBySlot: allowedBySlot,
        targetGoals: goals,
        constraints: parts.constraints.constraints,
        unavailableFoodIds: {
          ...parts.constraints.unavailableFoodIds,
          ...?guidedProfile?.avoidedFoodIds,
        },
        batches: cooked,
        portions: parts.portions,
        revision: parts.revision,
        acceptedRelaxations: parts.acceptedRelaxations,
        currentFoods: currentFoods,
        conditionGuidance: conditionAssessment,
      );
    } catch (error) {
      throw PlanException('PLAN_CONTEXT_INVALID',
          'The persisted plan schedule or hard constraints are invalid; review them before planning.',
          error);
    }
    final errors = const PlannerService().validate(meals, context);
    if (errors.isNotEmpty) {
      throw PlanException('PLAN_CONSTRAINT_CONFLICT',
          'This plan violates hard constraints: ${errors.join(', ')}',
          errors);
    }
  }

  Future<SafetyProfile> _readSafetyProfile() async {
    final doc = await LocalWorkspace(db).read('profile', 'safety');
    if (doc == null) return const SafetyProfile();
    try {
      return SafetyProfile.fromJson(doc.data);
    } catch (error) {
      throw PlanException('PLAN_SAFETY_INVALID',
          'The persisted safety profile is invalid; review it before planning.',
          error);
    }
  }

  /// Reads current persisted recipe revisions. A malformed document for a
  /// recipe used by this plan, or a stale revision, fails closed.
  Future<List<RecipeVersion>> _readRecipesFor(
      List<PlannedMeal> meals) async {
    final docs = await LocalWorkspace(db).list('recipe');
    final recipes = <RecipeVersion>[];
    final malformed = <String>{};
    for (final doc in docs) {
      try {
        recipes.add(recipeFromSnapshot(doc.data));
      } catch (_) {
        final separator = doc.id.indexOf(':');
        malformed.add(
            separator < 0 ? doc.id : doc.id.substring(0, separator));
      }
    }
    for (final meal in meals) {
      if (malformed.contains(meal.recipe.id)) {
        throw PlanException('PLAN_RECIPE_INVALID',
            'The persisted recipe ${meal.recipe.id} is invalid; review it before planning.');
      }
    }
    return recipes;
  }

  /// Builds the fresh ingredient definitions the planner compares against each
  /// recipe snapshot at commit time.
  ///
  /// Every present `catalog_foods` row is current for every provenance,
  /// including a user-authored custom row; a changed allergen, nutrient,
  /// preparation or basis therefore fails as INGREDIENT_STALE. An absent row is
  /// always INGREDIENT_UNRESOLVED: the recipe snapshot's provenance strings are
  /// caller-spoofable and are not accepted as ownership proof. Debug, fixture,
  /// imported and custom records are preserved by keeping their real rows.
  Future<Map<String, Food>> _currentFoodsFor(List<PlannedMeal> meals) =>
      _currentFoodsForRecipes([for (final meal in meals) meal.recipe]);

  Future<Map<String, Food>> _currentFoodsForRecipes(
          Iterable<RecipeVersion> recipes) =>
      _currentFoodsForIngredients([
        for (final recipe in recipes)
          for (final ingredient in recipe.ingredients) ingredient.food.id
      ]);

  Future<Map<String, Food>> _currentFoodsForIngredients(
      Iterable<String> ingredientIds) async {
    final ids = ingredientIds.toSet().toList();
    if (ids.isEmpty) return const <String, Food>{};
    final rowsById = <String, CatalogFood>{};
    for (var start = 0; start < ids.length; start += 500) {
      final end = start + 500 < ids.length ? start + 500 : ids.length;
      final rows = await (db.select(db.catalogFoods)
            ..where((t) => t.id.isIn(ids.sublist(start, end))))
          .get();
      for (final row in rows) {
        rowsById[row.id] = row;
      }
    }
    final current = <String, Food>{};
    for (final id in ids) {
      final row = rowsById[id];
      if (row == null) continue; // omitted => INGREDIENT_UNRESOLVED
      try {
        current[id] = _catalogueFoodFromRow(row);
      } catch (error) {
        if (error is PlanException) rethrow;
        throw PlanException('PLAN_INGREDIENT_INVALID',
            'The active definition for $id is unreadable; review it before planning.',
            error);
      }
    }
    return current;
  }

  /// Rehydrates the persisted catalogue row defensively: malformed safety data
  /// fails closed instead of degrading to an empty allergen/nutrient set.
  Food _catalogueFoodFromRow(CatalogFood row) {
    final per100g = _strictJsonMap(row.per100gJson, 'nutrient profile');
    final allergensJson = row.allergensJson;
    final allergens = allergensJson == null
        ? null
        : _strictJsonStringSet(allergensJson, 'allergens');
    final dietaryTags =
        _strictJsonStringSet(row.dietaryTagsJson, 'dietary tags');
    final basis = Exact.parse(row.basisValue);
    if (!basis.positive ||
        row.name.trim().isEmpty ||
        row.source.isEmpty ||
        row.sourceId.isEmpty) {
      throw const FormatException('Invalid catalogue identity or basis');
    }
    return Food(
      id: row.id,
      name: row.name,
      per100g: NutrientProfile.fromJson(per100g),
      source: FoodSource(
        dataset: row.source,
        datasetId: row.sourceId,
        datasetVersion: row.sourceVersion,
      ),
      quality: enumByWire(DataQuality.values, row.quality, DataQuality.imported),
      preparation: Preparation.values.byName(row.preparation),
      allergens: allergens,
      dietaryTags: dietaryTags,
      basisUnit: FoodUnit.values.byName(row.basisUnit),
      basisValue: row.basisValue,
    );
  }

  static Map<String, Object?> _strictJsonMap(String json, String field) {
    final decoded = jsonDecode(json);
    if (decoded is! Map) throw FormatException('Invalid $field');
    return Map<String, Object?>.from(decoded);
  }

  static Set<String> _strictJsonStringSet(String json, String field) {
    final decoded = jsonDecode(json);
    if (decoded is! List) throw FormatException('Invalid $field');
    final values = <String>{};
    for (final value in decoded) {
      if (value is! String) throw FormatException('Invalid $field');
      values.add(value);
    }
    return values;
  }

  _ContextParts _contextParts(
      Map<String, Object?> document, List<PlannedMeal> meals) {
    final rawSchedule = document['schedule'];
    final planSchedule = PlanSchedule.fromMetadata(rawSchedule);
    final List<MealSlot> slots;
    final List<Exact> portions;
    if (planSchedule == null) {
      // Legacy plan without persisted schedule metadata: the meals themselves
      // are the only known schedule and portion bounds.
      slots = [for (final meal in meals) meal.slot];
      portions = _legacyPortions(meals);
    } else {
      slots = planSchedule.slots;
      portions = _schedulePortions(
          Map<String, Object?>.from(rawSchedule! as Map));
    }
    return _ContextParts(
      slots,
      portions,
      _constraintsFor(document),
      _constraintRevision(document),
      _acceptedRelaxationsFor(document),
    );
  }

  List<Exact> _schedulePortions(Map<String, Object?> schedule) {
    final raw = schedule['portions'];
    if (raw == null) return <Exact>[Exact.one];
    if (raw is! List) {
      throw const PlanException(
          'PLAN_CONTEXT_INVALID', 'The persisted portion bounds are invalid.');
    }
    final portions = <Exact>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const PlanException(
            'PLAN_CONTEXT_INVALID', 'The persisted portion bounds are invalid.');
      }
      late final Exact value;
      try {
        value = Exact.fromJson(Map<String, Object?>.from(item));
      } catch (error) {
        throw PlanException('PLAN_CONTEXT_INVALID',
            'The persisted portion bounds are invalid.', error);
      }
      if (!value.positive) {
        throw const PlanException(
            'PLAN_CONTEXT_INVALID', 'The persisted portion bounds are invalid.');
      }
      portions.add(value);
    }
    if (portions.isEmpty) {
      throw const PlanException(
          'PLAN_CONTEXT_INVALID', 'The persisted portion bounds are invalid.');
    }
    return portions;
  }

  List<Exact> _legacyPortions(List<PlannedMeal> meals) {
    final portions = <Exact>[];
    final seen = <String>{};
    for (final meal in meals) {
      final key = '${meal.portions.numerator}/${meal.portions.denominator}';
      if (seen.add(key)) portions.add(meal.portions);
    }
    return portions.isEmpty ? <Exact>[Exact.one] : portions;
  }

  /// Fails before any stock is staged when the effective constraints are
  /// malformed, so a bad declaration is never read as "no unavailable foods"
  /// by the revision comparison or the commit context.
  void _validateConstraintInput(Object? rawConstraints) {
    if (rawConstraints == null) return;
    if (rawConstraints is! Map) {
      throw const PlanException(
          'PLAN_CONTEXT_INVALID', 'The persisted hard constraints are invalid.');
    }
    _unavailableFoodIds(Map<String, Object?>.from(rawConstraints));
  }

  _HardConstraints _constraintsFor(Map<String, Object?> document) {
    final raw = document['constraints'];
    if (raw == null) return const _HardConstraints(null, null, [], {});
    if (raw is! Map) {
      throw const PlanException(
          'PLAN_CONTEXT_INVALID', 'The persisted hard constraints are invalid.');
    }
    final constraints = Map<String, Object?>.from(raw);
    final unavailableFoodIds = _unavailableFoodIds(constraints);
    final maximumMinutes =
        _optionalInt(constraints['maximumMinutes'], 'maximumMinutes', 0);
    final maximumRepeats =
        _optionalInt(constraints['maximumRepeats'], 'maximumRepeats', 1);
    final minimum = _optionalExact(constraints['energyMinimum'], 'energyMinimum');
    final maximum = _optionalExact(constraints['energyMaximum'], 'energyMaximum');
    if ((minimum == null) != (maximum == null)) {
      throw const PlanException('PLAN_CONTEXT_INVALID',
          'Energy bounds must be declared together.');
    }
    final bounds = <NumericConstraint>[];
    if (minimum != null && maximum != null) {
      if (minimum.compareTo(maximum) > 0 ||
          minimum.compareTo(Exact.zero) < 0) {
        throw const PlanException(
            'PLAN_CONTEXT_INVALID', 'Energy bounds conflict.');
      }
      bounds.add(
          NumericConstraint(NutrientKey.energyKcal, minimum, maximum));
    }
    return _HardConstraints(
        maximumMinutes, maximumRepeats, bounds, unavailableFoodIds);
  }

  /// Parses the user's explicit unavailable-food declaration.
  ///
  /// Missing means none. A present value must be a list of unique, nonempty
  /// string food ids without surrounding whitespace; anything else fails
  /// closed instead of silently dropping a hard availability constraint.
  Set<String> _unavailableFoodIds(Map<String, Object?> constraints) {
    if (!constraints.containsKey('unavailableFoodIds')) {
      return const <String>{};
    }
    final raw = constraints['unavailableFoodIds'];
    if (raw is! List) {
      throw const PlanException('PLAN_CONTEXT_INVALID',
          'The persisted unavailable food ids are invalid.');
    }
    final ids = <String>{};
    for (final value in raw) {
      if (value is! String ||
          value.isEmpty ||
          value.trim() != value ||
          !ids.add(value)) {
        throw const PlanException('PLAN_CONTEXT_INVALID',
            'The persisted unavailable food ids are invalid.');
      }
    }
    return Set<String>.unmodifiable(ids);
  }

  int? _optionalInt(Object? value, String name, int minimum) {
    if (value == null) return null;
    if (value is int && value >= minimum) return value;
    throw PlanException('PLAN_CONTEXT_INVALID',
        'The persisted $name constraint is invalid.');
  }

  Exact? _optionalExact(Object? value, String name) {
    if (value == null) return null;
    if (value is! Map) {
      throw PlanException('PLAN_CONTEXT_INVALID',
          'The persisted $name constraint is invalid.');
    }
    try {
      return Exact.fromJson(Map<String, Object?>.from(value));
    } catch (error) {
      throw PlanException('PLAN_CONTEXT_INVALID',
          'The persisted $name constraint is invalid.', error);
    }
  }

  List<PlannerRelaxation> _acceptedRelaxationsFor(
      Map<String, Object?> document) {
    final raw = document['acceptedRelaxations'];
    if (raw == null) return const [];
    if (raw is! List) {
      throw const PlanException('PLAN_CONTEXT_INVALID',
          'The persisted accepted relaxations are invalid.');
    }
    final accepted = <PlannerRelaxation>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const PlanException('PLAN_CONTEXT_INVALID',
            'The persisted accepted relaxations are invalid.');
      }
      try {
        accepted.add(PlannerRelaxation.fromJson(
            Map<String, Object?>.from(item)));
      } catch (error) {
        throw PlanException('PLAN_CONTEXT_INVALID',
            'The persisted accepted relaxations are invalid.', error);
      }
    }
    return accepted;
  }

  /// Wraps batch-layer rejections in the feature error type without changing
  /// their stable code.
  Future<T> _translate<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlanException {
      rethrow;
    } on StateError catch (error) {
      final code = error.message;
      throw PlanException(code, _messageFor(code), error);
    }
  }

  static String _messageFor(String code) => switch (code) {
        'STALE_BATCH' => 'The cooked batch changed; reload and retry.',
        'BATCH_OVERALLOCATED' =>
          'The cooked batch does not have enough unspent stock for this plan.',
        'BATCH_ALLOCATION_CONFLICT' =>
          'That allocation id already exists with a different amount or state.',
        'BATCH_ALLOCATION_ALREADY_CONSUMED' =>
          'Consumed stock cannot be released.',
        'REQUEST_ID_REUSED' =>
          'This request id was already used for a different operation.',
        _ => code,
      };

  void _checkRequest(List<PlannedMeal> meals) {
    final slots = <String>{};
    final uses = <String>{};
    for (final meal in meals) {
      if (!slots.add(meal.slot.id)) {
        throw const PlanException(
            'DUPLICATE_MEAL_SLOT', 'Two planned meals use the same slot.');
      }
      try {
        DiaryDate.parse(meal.slot.date);
      } catch (_) {
        throw const PlanException('PLAN_INVALID_DATE',
            'Planned meal dates must be valid ISO yyyy-MM-dd values.');
      }
      final use = meal.batchUse;
      if (use != null && !uses.add(_useKey(use))) {
        throw const PlanException('DUPLICATE_BATCH_USE',
            'Two planned meals reference the same batch allocation.');
      }
    }
  }

  Future<void> _release(String requestId, PlannedBatchUse use,
      Map<String, int> revisions, Map<String, int> baselines) async {
    final batch = await _readBatch(use.batchId);
    if (batch == null) {
      // The batch no longer exists, so there is no stock to free.
      return;
    }
    baselines.putIfAbsent(batch.id, () => batch.revision);
    revisions[batch.id] = batch.revision;
    if (use.batchRevision > batch.revision) {
      throw const PlanException('PLAN_BATCH_REVISION_MISMATCH',
          'The plan refers to a newer batch revision than the stored batch; reload and retry.');
    }
    final allocation = batch.allocation(use.allocationId);
    if (allocation == null) {
      // Already consumed, re-keyed by a legacy build, or released earlier.
      return;
    }
    if (!allocation.planned) {
      // Consumed stock is intake accounting, not a reservation; never remove it.
      return;
    }
    final revision = await BatchService(db, clock, ids).releaseReservation(
      requestId: '$_releasePrefix$requestId:${batch.id}:${use.allocationId}',
      batchId: batch.id,
      allocationId: use.allocationId,
      expectedRevision: batch.revision,
    );
    revisions[batch.id] = revision;
  }

  /// Ensures one meal's reservation exists and is exact.
  ///
  /// Returns the use to persist; for a legacy re-keyed consumption this is the
  /// verified consumed allocation id instead of the original reservation id.
  Future<PlannedBatchUse> _resolveUse({
    required String requestId,
    required PlannedMeal meal,
    required PlannedBatchUse use,
    required bool retained,
    required Map<String, int> revisions,
    required Map<String, int> baselines,
  }) async {
    final batch = await _readBatch(use.batchId);
    if (batch == null) {
      throw const PlanException('PLAN_BATCH_MISSING',
          'The cooked batch for this meal no longer exists.');
    }
    final baseline = baselines.putIfAbsent(batch.id, () => batch.revision);
    if (use.batchRevision > batch.revision) {
      throw const PlanException('PLAN_BATCH_REVISION_MISMATCH',
          'The plan refers to a newer batch revision than the stored batch; reload and retry.');
    }
    if (!retained && use.batchRevision != baseline) {
      // A new stock selection must have been read from the batch revision this
      // save started from. Accepting an older pointer could reserve a changed
      // batch (different recipe, yield or availability) behind the user's back.
      throw const PlanException('STALE_BATCH',
          'The cooked batch changed since this stock selection was made; reload the batch and choose again.');
    }
    revisions[batch.id] = batch.revision;
    final expected = _expectedAmount(batch, meal);
    final allocation = batch.allocation(use.allocationId);
    if (allocation != null) {
      if (allocation.consumed) {
        if (!retained) {
          throw const PlanException('PLAN_BATCH_USE_CONSUMED',
              'This allocation was already consumed; choose unspent stock for a new planned meal.');
        }
        if (allocation.amount != expected.amount) {
          throw const PlanException('PLAN_BATCH_ALLOCATION_MISMATCH',
              'The consumed allocation no longer matches this meal.');
        }
        return use;
      }
      if (!allocation.planned || allocation.amount != expected.amount) {
        throw const PlanException('PLAN_BATCH_ALLOCATION_MISMATCH',
            'The batch reservation no longer matches this meal; release and reserve a new allocation.');
      }
      return use;
    }
    if (retained) {
      final reconciled = await _reconcileLegacyConsumption(batch, use, expected);
      if (reconciled == null) {
        throw const PlanException('PLAN_BATCH_ALLOCATION_MISSING',
            'The batch reservation for this meal is gone and could not be verified; remove the meal or choose a new allocation.');
      }
      return PlannedBatchUse(batch.id, batch.revision, reconciled);
    }
    final revision = await BatchService(db, clock, ids).reserveAmount(
      requestId: '$_reservePrefix$requestId:${batch.id}:${use.allocationId}',
      batchId: batch.id,
      allocationId: use.allocationId,
      expectedRevision: batch.revision,
      amount: expected.amount,
      unit: expected.unit,
    );
    revisions[batch.id] = revision;
    return use;
  }

  /// Older builds re-keyed a consumed reservation to the intake request id.
  /// Reconcile only when the diary snapshot names this exact reservation, the
  /// batch, the frozen stock unit, and the consumed amount, and exactly one
  /// consumed allocation matches that intake. Anything else fails closed.
  Future<String?> _reconcileLegacyConsumption(
      _BatchView batch, PlannedBatchUse use, _StockAmount expected) async {
    final intakeRequests = await _verifiedIntakeRequests(
        batch, use.allocationId, expected);
    if (intakeRequests.isEmpty) return null;
    final matches = <String>{};
    for (final requestId in intakeRequests) {
      for (final allocation in batch.allocations) {
        if (!allocation.consumed ||
            allocation.amount != expected.amount) {
          continue;
        }
        if (allocation.intakeRequestId != null) {
          if (allocation.intakeRequestId == requestId) matches.add(allocation.id);
        } else if (allocation.id == requestId) {
          matches.add(allocation.id);
        }
      }
    }
    if (matches.length > 1) {
      throw const PlanException('PLAN_LEGACY_AMBIGUOUS',
          'Several consumed allocations could belong to this plan; review the batch before continuing.');
    }
    return matches.isEmpty ? null : matches.first;
  }

  Future<Set<String>> _verifiedIntakeRequests(
      _BatchView batch, String allocationId, _StockAmount expected) async {
    final items = await db.select(db.logEntryItems).get();
    final entryIds = <String>{};
    for (final item in items) {
      final sourceJson = item.sourceJson;
      if (sourceJson == null) continue;
      final source = _decodeSource(sourceJson);
      if (source == null) continue;
      if (source['reservedAllocationId'] != allocationId ||
          source['batchId'] != batch.id) {
        continue;
      }
      final amount = _snapshotAmount(source, expected.unit);
      if (amount == null || amount != expected.amount) continue;
      entryIds.add(item.entryId);
    }
    if (entryIds.isEmpty) return const <String>{};
    final rows = await (db.select(db.logEntries)
          ..where((t) => t.id.isIn(entryIds)))
        .get();
    return {for (final row in rows) row.requestId};
  }

  /// Reads the frozen consumed amount in the batch's stock unit.
  ///
  /// A snapshot carries exactly one of `consumedBatchGrams` or
  /// `consumedBatchServings`, plus `consumedBatchUnit` for serving amounts.
  /// Legacy gram snapshots omit the unit and remain readable as grams; an
  /// explicit unit that disagrees with the live batch is never reinterpreted.
  Exact? _snapshotAmount(Map<String, Object?> source, FoodUnit unit) {
    final grams = source['consumedBatchGrams'];
    final servings = source['consumedBatchServings'];
    final rawUnit = source['consumedBatchUnit'];
    switch (unit) {
      case FoodUnit.g:
        if (grams is! Map || servings != null) return null;
        if (rawUnit != null && rawUnit != 'g') return null;
        return _exactOrNull(grams);
      case FoodUnit.serving:
        if (servings is! Map || grams != null) return null;
        if (rawUnit != 'serving') return null;
        return _exactOrNull(servings);
      case FoodUnit.ml:
      case FoodUnit.item:
        return null;
    }
  }

  Exact? _exactOrNull(Object? raw) {
    if (raw is! Map) return null;
    try {
      return Exact.fromJson(Map<String, Object?>.from(raw));
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?>? _decodeSource(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  /// The allocation amount for [meal] in the batch's own stock unit.
  ///
  /// Gram batches are planned from their measured finished yield; serving
  /// batches reserve the meal's exact recipe portions. No amount is ever
  /// converted between units.
  _StockAmount _expectedAmount(_BatchView batch, PlannedMeal meal) {
    final unit = batch.unit;
    if (unit != FoodUnit.g && unit != FoodUnit.serving) {
      throw const PlanException('BATCH_UNIT_MISMATCH',
          'Only gram- or serving-based cooked batches support planned reservations.');
    }
    if (batch.recipe != meal.recipe) {
      throw const PlanException('PLAN_BATCH_RECIPE_MISMATCH',
          'The planned meal recipe no longer matches the cooked batch.');
    }
    if (unit == FoodUnit.g) {
      final finished = batch.finishedWeightG;
      if (finished == null || !finished.positive) {
        throw const PlanException('PLAN_BATCH_INVALID',
            'The cooked batch has no measured finished weight.');
      }
      return _StockAmount(
          finished * meal.portions / batch.recipe.servings, FoodUnit.g);
    }
    return _StockAmount(meal.portions, FoodUnit.serving);
  }

  Future<_BatchView?> _readBatch(String batchId) async {
    final doc = await LocalWorkspace(db).read('batch', batchId);
    if (doc == null) return null;
    try {
      final data = doc.data;
      final recipe = recipeFromSnapshot(
          Map<String, Object?>.from(data['recipe']! as Map));
      final finishedJson = data['finishedWeightG'];
      final allocations = [
        for (final raw in data['allocations']! as List) _allocationFrom(raw)
      ];
      return _BatchView(
        id: doc.id,
        revision: doc.revision,
        unit: FoodUnit.values.byName(data['unit']! as String),
        recipe: recipe,
        available:
            Exact.fromJson(Map<String, Object?>.from(data['available']! as Map)),
        finishedWeightG: finishedJson == null
            ? null
            : Exact.fromJson(Map<String, Object?>.from(finishedJson as Map)),
        allocations: allocations,
      );
    } on PlanException {
      rethrow;
    } catch (error) {
      throw PlanException('PLAN_BATCH_INVALID',
          'The cooked batch document is invalid; review it before planning.',
          error);
    }
  }

  BatchAllocation _allocationFrom(Object? raw) {
    final json = Map<String, Object?>.from(raw! as Map);
    return BatchAllocation(
      json['id']! as String,
      Exact.fromJson(Map<String, Object?>.from(json['amount']! as Map)),
      json['status']! as String,
      intakeRequestId: json['intakeRequestId'] as String?,
    );
  }

  StoredPlan _stored(int revision, Map<String, Object?> data) {
    final seed = data['seed'];
    final policy = data['policyVersion'];
    return StoredPlan._(
      documentId: documentId,
      revision: revision,
      meals: _decodeMeals(data),
      seed: seed is int ? seed : 7,
      policyVersion: policy is String ? policy : 'planner-v3',
      document: data,
      conditionGuidance: _conditionInputOrNull(data['conditionGuidance']),
    );
  }

  /// Reads persisted condition policy inputs. A malformed block fails closed
  /// instead of loading a plan as if no conditions were involved.
  ConditionGuidanceInput? _conditionInputOrNull(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw const PlanException('PLAN_CONDITION_INVALID',
          'The persisted condition guidance is invalid; review it before planning.');
    }
    try {
      return ConditionGuidanceInput.fromJson(Map<String, Object?>.from(raw));
    } catch (error) {
      throw PlanException('PLAN_CONDITION_INVALID',
          'The persisted condition guidance is invalid; review it before planning.',
          error);
    }
  }

  /// A plan may only record the declarations it was generated under.
  ///
  /// Missing input is allowed only while the user has declared no condition;
  /// otherwise the save is rejected until the plan is repaired with the current
  /// declarations. This is deliberately independent of the declaration's
  /// `guidancePolicy` label.
  void _checkConditionInput(Object? raw, ConditionGuidanceInput current) {
    if (raw == null) {
      if (current.declared.isNotEmpty ||
          current.unrecognizedDeclared.isNotEmpty) {
        throw const PlanException('PLAN_CONDITION_INPUT_REQUIRED',
            'Declared health conditions are not recorded in this plan; repair the plan to apply them.');
      }
      return;
    }
    final saved = _conditionInputOrNull(raw);
    if (saved == null) return;
    if (saved.policyVersion != ConditionGuidancePolicy.version) {
      throw const PlanException('PLAN_CONDITION_POLICY_MISMATCH',
          'Condition guidance policy changed; repair the plan to apply the current experimental policy.');
    }
    if (!saved.sameDeclaration(current)) {
      throw const PlanException('PLAN_CONDITION_INPUT_STALE',
          'Declared conditions changed since this plan was generated; reload and repair the plan before saving.');
    }
  }

  List<PlannedMeal> _decodeMeals(Map<String, Object?> data) {
    final raw = data['meals'];
    if (raw is! List) throw const FormatException('Invalid plan meals');
    return [
      for (final item in raw)
        _decodeMeal(Map<String, Object?>.from(item as Map))
    ];
  }

  PlannedMeal _decodeMeal(Map<String, Object?> meal) {
    final rawUse = meal['batchUse'];
    PlannedBatchUse? use;
    if (rawUse is Map) {
      final parsed = _validUse(Map<String, Object?>.from(rawUse));
      if (parsed == null) {
        throw const FormatException('Invalid plan batch use');
      }
      use = parsed;
    }
    return PlannedMeal(
      MealSlot(meal['slot']! as String, meal['date']! as String,
          meal['label']! as String),
      recipeFromSnapshot(Map<String, Object?>.from(meal['recipe']! as Map)),
      Exact.fromJson(Map<String, Object?>.from(meal['portions']! as Map)),
      pinned: meal['pinned'] == true,
      batchUse: use,
    );
  }

  List<PlannedBatchUse> _priorUses(StoredDocument? doc) {
    final raw = doc?.data['meals'];
    if (raw is! List) return const [];
    final uses = <PlannedBatchUse>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final rawUse = item['batchUse'];
      if (rawUse is! Map) continue;
      final use = _validUse(Map<String, Object?>.from(rawUse));
      if (use != null) uses.add(use);
    }
    return uses;
  }

  Map<String, Map<String, Object?>> _priorUseMaps(StoredDocument? doc) {
    final raw = doc?.data['meals'];
    if (raw is! List) return const {};
    final maps = <String, Map<String, Object?>>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final rawUse = item['batchUse'];
      if (rawUse is! Map) continue;
      final use = Map<String, Object?>.from(rawUse);
      final batchId = use['batchId'];
      final allocationId = use['allocationId'];
      if (batchId is! String || allocationId is! String) continue;
      maps['$batchId\u0000$allocationId'] = use;
    }
    return maps;
  }

  PlannedBatchUse? _validUse(Map<String, Object?> use) {
    final batchId = use['batchId'];
    final allocationId = use['allocationId'];
    final revision = use['batchRevision'];
    if (batchId is! String ||
        allocationId is! String ||
        revision is! int ||
        batchId.isEmpty ||
        allocationId.isEmpty ||
        revision < 1) {
      return null;
    }
    return PlannedBatchUse(batchId, revision, allocationId);
  }

  Map<String, Object?> _mealJson(
      PlannedMeal meal, Map<String, Map<String, Object?>> priorUseMaps) {
    final json = <String, Object?>{
      'slot': meal.slot.id,
      'date': meal.slot.date,
      'label': meal.slot.label,
      'recipe': recipeSnapshot(meal.recipe),
      'portions': meal.portions.toJson(),
      'pinned': meal.pinned,
    };
    final use = meal.batchUse;
    if (use != null) {
      // Unknown keys written by a newer build (for example an intake identity)
      // survive a save of the same reservation.
      json['batchUse'] = <String, Object?>{
        ...?priorUseMaps[_useKey(use)],
        'batchId': use.batchId,
        'batchRevision': use.batchRevision,
        'allocationId': use.allocationId,
      };
    }
    return json;
  }

  static String _useKey(PlannedBatchUse use) =>
      '${use.batchId}\u0000${use.allocationId}';

  String _fingerprint({
    required int expectedPlanRevision,
    int? expectedProfileRevision,
    required List<PlannedMeal> meals,
    required Map<String, Object?> metadata,
    required int? seed,
    required String? policyVersion,
  }) =>
      jsonEncode(_canonical({
        if (documentId != 'current') 'documentId': documentId,
        if (expectedProfileRevision != null)
          'expectedProfileRevision': expectedProfileRevision,
        'expectedPlanRevision': expectedPlanRevision,
        'seed': seed,
        'policyVersion': policyVersion,
        'metadata': metadata,
        'meals': [
          for (final meal in meals)
            {
              'slot': meal.slot.id,
              'date': meal.slot.date,
              'label': meal.slot.label,
              'recipe': recipeSnapshot(meal.recipe),
              'portions': meal.portions.toJson(),
              'pinned': meal.pinned,
              'batchUse': meal.batchUse == null
                  ? null
                  : {
                      'batchId': meal.batchUse!.batchId,
                      'batchRevision': meal.batchUse!.batchRevision,
                      'allocationId': meal.batchUse!.allocationId,
                    },
            }
        ],
      }));

  Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = <String>[];
      for (final key in value.keys) {
        if (key is! String) {
          throw ArgumentError('Plan metadata keys must be strings');
        }
        keys.add(key);
      }
      keys.sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return [for (final item in value) _canonical(item)];
    return value;
  }

  Future<PlanSaveResult?> _replay(String requestId, String fingerprint) async {
    final row = await (db.select(db.appliedCommands)
          ..where((t) => t.requestId.equals('$_savePrefix$requestId')))
        .getSingleOrNull();
    if (row == null) return null;
    final decoded = jsonDecode(row.resultJson);
    if (decoded is! Map ||
        decoded['operation'] != 'plan-save' ||
        decoded['fingerprint'] != fingerprint) {
      throw const PlanException('REQUEST_ID_REUSED',
          'This request id was already used for a different plan save.');
    }
    final receipt = Map<String, Object?>.from(decoded);
    final document = Map<String, Object?>.from(receipt['document']! as Map);
    return PlanSaveResult._(
      documentId: documentId,
      revision: receipt['revision']! as int,
      meals: _decodeMeals(document),
      batchRevisions: {
        for (final entry in (receipt['batchRevisions']! as Map).entries)
          entry.key as String: entry.value as int
      },
      document: document,
      conditionGuidance: _conditionInputOrNull(document['conditionGuidance']),
    );
  }

  Future<void> _record(
      String requestId, String fingerprint, PlanSaveResult result) async {
    await db.into(db.appliedCommands).insert(AppliedCommandsCompanion.insert(
        requestId: '$_savePrefix$requestId',
        resultJson: jsonEncode({
          'operation': 'plan-save',
          'fingerprint': fingerprint,
          'revision': result.revision,
          'batchRevisions': result.batchRevisions,
          'document': result.document,
        })));
  }
}

final class _StockAmount {
  const _StockAmount(this.amount, this.unit);
  final Exact amount;
  final FoodUnit unit;
}

final class _BatchView {
  _BatchView({
    required this.id,
    required this.revision,
    required this.unit,
    required this.recipe,
    required this.available,
    required this.finishedWeightG,
    required this.allocations,
  });
  final String id;
  final int revision;
  final FoodUnit unit;
  final RecipeVersion recipe;
  final Exact available;
  final Exact? finishedWeightG;
  final List<BatchAllocation> allocations;

  BatchAllocation? allocation(String allocationId) {
    for (final allocation in allocations) {
      if (allocation.id == allocationId) return allocation;
    }
    return null;
  }

  CookedBatch get cookedBatch => CookedBatch(
      id: id,
      recipe: recipe,
      revision: revision,
      available: available,
      unit: unit,
      finishedWeightG: finishedWeightG,
      allocations: allocations);
}

final class _HardConstraints {
  const _HardConstraints(this.maximumMinutes, this.maximumRepeats,
      this.constraints, this.unavailableFoodIds);
  final int? maximumMinutes, maximumRepeats;
  final List<NumericConstraint> constraints;
  final Set<String> unavailableFoodIds;
}

final class _ContextParts {
  const _ContextParts(
      this.slots, this.portions, this.constraints, this.revision,
      this.acceptedRelaxations);
  final List<MealSlot> slots;
  final List<Exact> portions;
  final _HardConstraints constraints;
  final int revision;
  final List<PlannerRelaxation> acceptedRelaxations;
}
