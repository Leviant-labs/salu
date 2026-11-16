import 'dart:convert';
import 'package:salu_core/salu_core.dart';
import 'database/app_database.dart';
import 'draft_store.dart';
import 'grocery_service.dart';
import 'plan_meal_state_service.dart';
import 'plan_service.dart';
import 'snapshot_codec.dart';
import 'workspace_store.dart';

typedef GuidedPlanGenerator = Future<PlannerResult> Function(
    PlannerContext context, List<PlannedMeal> existing);

final class GuidedPlanException implements Exception {
  const GuidedPlanException(this.code, this.message, [this.cause]);
  final String code, message;
  final Object? cause;
  @override
  String toString() => message;
}

final class GuidedPlanProvenance {
  const GuidedPlanProvenance({required this.providerId, required this.model,
    required this.schemaVersion, required this.promptVersion,
    required this.requestHash});
  final String providerId, model, requestHash;
  final int schemaVersion, promptVersion;

  Map<String, Object?> toJson() => {
    'providerId': providerId, 'model': model, 'schemaVersion': schemaVersion,
    'promptVersion': promptVersion, 'requestHash': requestHash,
  };
}

/// A proposal contains every reviewed input. Only acceptance mutates the plan.
final class GuidedPlanService {
  GuidedPlanService(this.db, this.clock, this.ids,
      {GuidedPlanGenerator? generator})
      : _generator = generator ?? _generate;
  final AppDatabase db;
  final Clock clock;
  final IdGenerator ids;
  final GuidedPlanGenerator _generator;
  LocalWorkspace get _workspace => LocalWorkspace(db);
  static Future<PlannerResult> _generate(PlannerContext context,
          List<PlannedMeal> existing) async =>
      const PlannerService().plan(context, existing: existing);
  static List<Exact> get portions =>
      ['0.75','1','1.25','1.5','1.75','2','2.5','3'].map(Exact.parse).toList();

  Future<StoredPlan?> planForDate(DiaryDate date) async {
    StoredPlan? legacy;
    StoredPlan? guided;
    for (final row in await _workspace.list('plan')) {
      final plan = await PlanService(db, clock, ids, documentId: row.id).load();
      if (plan == null || !_contains(plan, date)) continue;
      if (row.id == 'current') {
        legacy = plan;
      } else if (row.id.startsWith('week:')) {
        if (guided != null) {
          throw const GuidedPlanException('PLAN_PERIOD_OVERLAP',
              'Two saved weeks cover this date; review your plans.');
        }
        guided = plan;
      }
    }
    return guided ?? legacy;
  }

  static bool _contains(StoredPlan plan, DiaryDate date) {
    final schedule = PlanSchedule.fromMetadata(plan.document['schedule']);
    return schedule == null
        ? plan.meals.any((meal) => meal.slot.date == date.toIso())
        : schedule.generatedSlots.any((slot) => slot.date == date.toIso());
  }

  Future<MealDraft> propose({
    required String requestId,
    required int expectedProfileRevision,
    required DiaryDate startDate,
    NutritionProfile? proposedProfile,
    SafetyProfile? proposedSafety,
    Map<String,Object?>? proposedHealthDeclaration,
    bool recalculateTarget = false,
    bool completesOnboarding = false,
    Set<String> replaceSlotIds = const {},
    Map<String,int> suggestedRecipeRanks = const {},
    Map<String,int> cookingMinutesBySlot = const {},
    String? expectedPlanDocumentId,
    int? expectedPlanRevision,
    GuidedPlanProvenance? provenance,
    Map<String, Object?>? proposedSettings,
  }) async {
    if (requestId.isEmpty) throw ArgumentError('Empty request ID');
    if (proposedSettings != null && proposedSettings.entries.any((entry) =>
        !const {'support', 'hideCalorieNudges'}.contains(entry.key) ||
        entry.value is! bool)) {
      throw ArgumentError('Invalid proposed settings');
    }
    final fingerprint = jsonEncode(_canonical({
      'expectedProfileRevision': expectedProfileRevision,
      'startDate': startDate.toIso(), 'profile': proposedProfile?.toJson(),
      'safety': proposedSafety?.toJson(), 'health': proposedHealthDeclaration,
      'recalculateTarget': recalculateTarget,
      'completesOnboarding': completesOnboarding,
      'replaceSlotIds': replaceSlotIds.toList()..sort(),
      'suggestedRecipeRanks': suggestedRecipeRanks,
      'cookingMinutesBySlot': cookingMinutesBySlot,
      if (expectedPlanDocumentId != null) 'expectedPlanDocumentId': expectedPlanDocumentId,
      if (expectedPlanRevision != null) 'expectedPlanRevision': expectedPlanRevision,
      if (provenance != null) 'provenance': provenance.toJson(),
      if (proposedSettings != null) 'proposedSettings': proposedSettings,
    }));
    final draftId = 'guided:$requestId';
    final store = MealDraftStore(db);
    final priorDraft = await store.read(draftId);
    if (priorDraft != null) {
      if (priorDraft.values['requestFingerprint'] != fingerprint) {
        throw StateError('REQUEST_ID_REUSED');
      }
      return priorDraft;
    }
    final profileDoc = await _workspace.read('nutrition-profile-v1', 'current');
    if ((profileDoc?.revision ?? 0) != expectedProfileRevision) {
      throw StateError('PLAN_PROFILE_STALE');
    }
    final profile = proposedProfile ?? (profileDoc == null ? null :
        NutritionProfile.fromJson(profileDoc.data));
    if (profile == null) throw StateError('PROFILE_REQUIRED');
    final safetyDoc = await _workspace.read('profile', 'safety');
    final safety = proposedSafety ?? SafetyProfile.fromJson(safetyDoc?.data ?? {});
    final healthDoc = await _workspace.read('health-declaration', 'current');
    final health = <String,Object?>{
      ...const AdultHealthDeclaration().toJson(), ...?healthDoc?.data,
      ...?proposedHealthDeclaration,
      'conditions': {
        ...?((healthDoc?.data['conditions']) as Map?)?.cast<String,Object?>(),
        ...?((proposedHealthDeclaration?['conditions']) as Map?)
            ?.cast<String,Object?>(),
      },
      if (proposedProfile != null) 'goal': profile.goal.name,
    };
    AdultHealthDeclaration.fromJson(health);
    final conditionInput = ConditionGuidanceInput.fromDeclarationDocument(health);
    final conditionAssessment = ConditionGuidancePolicy.assess(
        input: conditionInput, strictExclusions: safety.strictExclusions,
        eatingConcern: safety.eatingConcern == true);
    final targetDoc = await _workspace.read('target', 'current');
    DeclaredTarget? target = targetDoc == null ? null :
        DeclaredTarget.fromJson(targetDoc.data);
    var writeTarget = false;
    if (recalculateTarget || (completesOnboarding && target == null)) {
      try {
        target = const TargetService().generateAutomaticTarget(profile: profile,
            id: 'current', revision: (targetDoc?.revision ?? 0) + 1,
            effectiveDate: startDate.toIso());
        writeTarget = true;
      } on TargetEstimateException catch (error) {
        if (recalculateTarget || error.code != 'TARGET_INPUT_REQUIRED') rethrow;
      }
    }
    final current = await planForDate(startDate);
    final currentGuided = current?.document['guided'];
    if (!writeTarget && currentGuided is Map &&
        currentGuided.containsKey('targetSnapshot')) {
      final snapshot = currentGuided['targetSnapshot'];
      target = snapshot == null ? null :
          DeclaredTarget.fromJson(Map<String, Object?>.from(snapshot as Map));
    }
    final currentSchedule = current == null ? null :
        PlanSchedule.fromMetadata(current.document['schedule']);
    final effectiveStart = currentSchedule == null ? startDate :
        DiaryDate.parse(currentSchedule.startDate);
    final documentId = current?.documentId ?? 'week:${startDate.toIso()}';
    if ((expectedPlanDocumentId != null && expectedPlanDocumentId != documentId) ||
        (expectedPlanRevision != null && expectedPlanRevision != (current?.revision ?? 0))) {
      throw StateError('PLAN_STALE');
    }
    final scheduleJson = <String,Object?>{
      'schemaVersion': 2, 'startDate': effectiveStart.toIso(), 'days': 7,
      'labels': profile.mealLabels,
      'portions': portions.map((value) => value.toJson()).toList(),
      'excludedSlotIds': <String>[],
    };
    final schedule = PlanSchedule.fromMetadata(scheduleJson)!;
    final slots = schedule.slots;
    final slotIds = slots.map((slot) => slot.id).toSet();
    if (!slotIds.containsAll(replaceSlotIds) ||
        cookingMinutesBySlot.entries.any((entry) =>
            !replaceSlotIds.contains(entry.key) || entry.value <= 0)) {
      throw StateError('PLAN_CONTEXT_INVALID');
    }
    final states = current == null ? <PlanMealStateRecord>[] :
        await PlanMealStateService(db).listForPlan(documentId);
    final consumed = {for (final state in states)
      if (state.state == PlanMealState.consumed) state.slotId};
    final previousMeals = current?.meals ?? const <PlannedMeal>[];
    for (final meal in previousMeals) {
      if (!slotIds.contains(meal.slot.id)) {
        if (consumed.contains(meal.slot.id)) throw StateError('MEAL_ALREADY_CONSUMED');
        if (meal.pinned) throw StateError('PINNED_MEAL');
      }
    }
    for (final meal in previousMeals) {
      if (!replaceSlotIds.contains(meal.slot.id)) continue;
      if (consumed.contains(meal.slot.id)) throw StateError('MEAL_ALREADY_CONSUMED');
      if (meal.pinned) throw StateError('PINNED_MEAL');
    }
    final recipeDocs = await _workspace.list('recipe');
    final recipes = recipeDocs.map((row) => recipeFromSnapshot(row.data)).toList();
    final recipeIds = recipes.map((recipe) => recipe.id).toSet();
    if (suggestedRecipeRanks.entries.any((entry) => !recipeIds.contains(entry.key)
        || entry.value < 0 || entry.value > 100)) {
      throw StateError('INVALID_SUGGESTION');
    }
    final content = {for (final row in await _workspace.list('meal-content-v1'))
      row.id: row.data};
    final candidates = <String,Set<String>>{};
    final priorGuided = current?.document['guided'] as Map?;
    final caps = <String,int>{
      ...?((priorGuided?['cookingMinutesBySlot']) as Map?)?.cast<String,int>(),
      ...cookingMinutesBySlot,
    };
    for (final slot in slots) {
      final ids = <String>{};
      for (final recipe in recipes) {
        final meta = content[recipe.id];
        final labels = meta?['mealLabels'] as List?;
        final cap = caps[slot.id] ?? profile.maximumCookingMinutes;
        if (meta?['revision'] != recipe.revision || labels == null ||
            !labels.contains(slot.label) ||
            (profile.coldLunches && slot.label == 'lunch' &&
                meta?['coldSuitable'] != true) ||
            (cap != null && recipe.minutes > cap) ||
            profile.dislikedRecipeIds.contains(recipe.id) ||
            !recipe.eligible(safety.strictExclusions, profile.dietaryTags,
                unavailableFoodIds: profile.avoidedFoodIds)) continue;
        if (replaceSlotIds.contains(slot.id) && previousMeals.any((meal) =>
            meal.slot.id == slot.id && meal.recipe.id == recipe.id)) continue;
        ids.add(recipe.id);
      }
      if (ids.isEmpty) {
        final alternatives = recipes.where((recipe) =>
            (content[recipe.id]?['mealLabels'] as List? ?? []).contains(slot.label)
            && recipe.eligible(safety.strictExclusions, profile.dietaryTags,
                unavailableFoodIds: profile.avoidedFoodIds))
            .map((recipe) => '${recipe.name} (${recipe.minutes} min)').join(', ');
        throw GuidedPlanException('MEAL_CANDIDATES_REQUIRED',
            'No ${slot.label} fits the selected food/time choices. '
            'Review those choices.${alternatives.isEmpty ? '' : ' Alternatives: $alternatives'}',
            {'slotId':slot.id,'label':slot.label});
      }
      candidates[slot.id] = ids;
    }
    // Explicit authored grain metadata only: absence (grain-free or unknown)
    // is never treated as refined, and whole-grain meals are never penalized.
    // Respect policy abstentions (including eating concerns). The offset sits
    // just above the validated 0-100 suggestion rank but below the 102 budget
    // penalty, so an explicit lower-cost choice still wins and nothing is
    // excluded or treated as clinically sufficient.
    final preferWholeGrain = conditionAssessment.directives.any((directive) =>
        directive.condition == PlanningCondition.highCholesterol ||
        directive.condition == PlanningCondition.highTriglycerides);
    final ranks = <String,int>{for (final recipe in recipes) recipe.id:
      102 * ((profile.budget == 'lowerCost' &&
          content[recipe.id]?['costTier'] == 'standard') ? 1 : 0) +
      (suggestedRecipeRanks[recipe.id] ??
          (suggestedRecipeRanks.isEmpty ? 0 : 101)) +
      (preferWholeGrain &&
              content[recipe.id]?['grainComposition'] == 'refinedGrain'
          ? 101 : 0)};
    final goals = <NutrientKey,Exact>{};
    if (target != null && target.active) {
      goals[NutrientKey.energyKcal] = target.energyKcal;
      if (target.proteinG?.positive == true) goals[NutrientKey.proteinG] = target.proteinG!;
      if (target.fatG?.positive == true) goals[NutrientKey.fatG] = target.fatG!;
      // INSA available carbohydrate is not the EU carbohydrate target basis.
    }
    final effectiveRevision = expectedProfileRevision + (proposedProfile == null ? 0 : 1);
    final oldConstraint = current?.document['constraintRevision'] as int? ?? 0;
    final batches = <CookedBatch>[];
    for (final row in await _workspace.list('batch')) {
      final data = row.data;
      batches.add(CookedBatch(id: row.id, revision: row.revision,
          recipe: recipeFromSnapshot(_map(data['recipe'])),
          available: Exact.fromJson(_map(data['available'])),
          unit: FoodUnit.values.byName(data['unit']! as String),
          finishedWeightG: data['finishedWeightG'] == null ? null :
              Exact.fromJson(_map(data['finishedWeightG'])),
          allocations: [
            for (final raw in data['allocations']! as List)
              BatchAllocation((raw as Map)['id']! as String,
                  Exact.fromJson(_map(raw['amount'])),raw['status']! as String,
                  intakeRequestId:raw['intakeRequestId'] as String?)
          ]));
    }
    final context = PlannerContext(slots: slots, recipes: recipes,
        seed: effectiveStart.year * 10000 + effectiveStart.month * 100 +
            effectiveStart.day + effectiveRevision,
        maxNodes: 20000, maximumMinutes: profile.maximumCookingMinutes,
        maximumRepeats: 2, strictExclusions: safety.strictExclusions,
        dietaryTags: profile.dietaryTags, unavailableFoodIds: profile.avoidedFoodIds,
        recipeIdsBySlot: candidates, targetGoals: goals,
        recipePreferenceRanks: ranks, preferredRecipeIds: profile.likedRecipeIds,
        portions: portions, revision: oldConstraint + 1,
        batches: batches,
        currentFoods: await PlanService(db,clock,ids).currentFoodsForRecipes(recipes),
        conditionGuidance: conditionAssessment,
        objectives: [PlannerObjective.practicalPreference,
          if (profile.preferVariety) PlannerObjective.variety,
          PlannerObjective.targetProximity, PlannerObjective.dataCompleteness,
          PlannerObjective.guidance, PlannerObjective.recipePreference,
          if (!profile.preferVariety) PlannerObjective.variety,
          PlannerObjective.cookingEffort, PlannerObjective.ingredientReuse]);
    final retained = previousMeals.where((meal) =>
        slotIds.contains(meal.slot.id) && !replaceSlotIds.contains(meal.slot.id) &&
        (replaceSlotIds.isNotEmpty || consumed.contains(meal.slot.id) || meal.pinned))
        .map((meal) => PlannedMeal(meal.slot,meal.recipe,meal.portions,
            pinned:true,batchUse:meal.batchUse)).toList();
    final generated = await _generator(context, retained);
    if (generated.status != PlannerStatus.validPlan) {
      throw GuidedPlanException(generated.status == PlannerStatus.searchExhausted
          ? 'PLAN_SEARCH_EXHAUSTED' : 'PLAN_CONSTRAINT_CONFLICT',
          'No complete plan was generated. Review the selected choices.',
          generated.diagnostics);
    }
    if (expectedPlanDocumentId != null || expectedPlanRevision != null) {
      final latest = await planForDate(startDate);
      if ((latest?.documentId ?? 'week:${startDate.toIso()}') != documentId ||
          (latest?.revision ?? 0) != (current?.revision ?? 0)) {
        throw StateError('PLAN_STALE');
      }
    }
    final meals = generated.meals.map((meal) => PlannedMeal(meal.slot,
        meal.recipe,meal.portions, batchUse:meal.batchUse,
        pinned:previousMeals.any((prior) => prior.slot.id == meal.slot.id && prior.pinned)))
        .toList();
    if (replaceSlotIds.isNotEmpty && !meals.any((meal) =>
        replaceSlotIds.contains(meal.slot.id) && !previousMeals.any((prior) =>
            prior.slot.id == meal.slot.id && prior.recipe == meal.recipe &&
            prior.portions == meal.portions))) throw StateError('PLAN_NO_CHANGE');
    final metadata = <String,Object?>{
      'schedule':scheduleJson, 'constraintRevision':oldConstraint + 1,
      'constraints':{'maximumMinutes':profile.maximumCookingMinutes,
        'maximumRepeats':2,'unavailableFoodIds':profile.avoidedFoodIds.toList()..sort()},
      'conditionGuidance':conditionInput.toJson(),
      'guided':{'schemaVersion':1,'profileSnapshot':profile.toJson(),
        'profileRevision':effectiveRevision,'targetSnapshot':target?.toJson(),
        'householdServings':profile.householdServings,
        'recipeIdsBySlot':{for(final e in candidates.entries)e.key:e.value.toList()..sort()},
        'targetGoals':{for(final e in goals.entries)e.key.wire:e.value.toJson()},
        'recipePreferenceRanks':ranks,'cookingMinutesBySlot':caps},
    };
    final groceryDoc = await _workspace.read('groceries',documentId);
    final manualDoc = await _workspace.read('groceries','manual');
    final settingsDoc = await _workspace.read('preferences','app');
    final values = <String,Object?>{
      'kind':'guided-plan-v1','requestFingerprint':fingerprint,
      if (provenance != null) 'provenance': provenance.toJson(),
      if (proposedSettings != null) 'proposedSettings': proposedSettings,
      'planDocumentId':documentId,'expectedPlanRevision':current?.revision ?? 0,
      'baseRevisions':{'profile':expectedProfileRevision,
        'safety':safetyDoc?.revision ?? 0,'health':healthDoc?.revision ?? 0,
        'target':targetDoc?.revision ?? 0,'groceries':groceryDoc?.revision ?? 0,
        'manualGroceries':manualDoc?.revision ?? 0,'settings':settingsDoc?.revision ?? 0},
      'profile':profile.toJson(),'safety':safety.toJson(),'health':health,
      'target':target?.toJson(),'writeProfile':proposedProfile != null,
      'writeSafety':proposedSafety != null,
      'writeHealth':proposedHealthDeclaration != null || proposedProfile != null,
      'writeTarget':writeTarget,'completesOnboarding':completesOnboarding,
      'settings':settingsDoc?.data ?? <String,Object?>{},
      'metadata':metadata,'seed':context.seed,'policyVersion':'guided-plan-v1',
      'meals':meals.map(_mealJson).toList(),
      'previousMeals':previousMeals.map(_mealJson).toList(),
      'previousDocument':current?.document ?? <String,Object?>{},
      'groceryBefore':_groceryJson(previousMeals,
          GroceryService.householdServingsForPlan(current?.document ?? {})),
      'groceryAfter':_groceryJson(meals,profile.householdServings),
    };
    await store.create(id:draftId,requestId:'$requestId:draft',values:values);
    return store.receiveValidated(id:draftId,requestId:'$requestId:review',
        expectedRevision:1,suggestion:values);
  }

  /// Swaps one selection in a still-unaccepted preview, without a plan write.
  Future<MealDraft> swapDraft({required String draftId,
      required int expectedDraftRevision, required String slotId,
      required String requestId}) async {
    final store = MealDraftStore(db);
    final draft = await store.read(draftId);
    if (draft == null || draft.status != DraftStatus.review ||
        draft.revision != expectedDraftRevision ||
        draft.values['kind'] != 'guided-plan-v1') {
      throw StateError('STALE_DRAFT');
    }
    final values = draft.values;
    final metadata = _map(values['metadata']);
    final guided = _map(metadata['guided']);
    final profile = NutritionProfile.fromJson(_map(values['profile']));
    final safety = SafetyProfile.fromJson(_map(values['safety']));
    final meals = _meals(values['meals']);
    final selected = meals.where((meal) => meal.slot.id == slotId).firstOrNull;
    if (selected == null) throw StateError('PLANNED_MEAL_MISSING');
    if (selected.pinned) throw StateError('PINNED_MEAL');
    final state = await PlanMealStateService(db).read(
        values['planDocumentId']! as String, slotId);
    if (state?.state == PlanMealState.consumed) {
      throw StateError('MEAL_ALREADY_CONSUMED');
    }
    final recipes = (await _workspace.list('recipe'))
        .map((row) => recipeFromSnapshot(row.data)).toList();
    final candidates = <String,Set<String>>{
      for (final entry in _map(guided['recipeIdsBySlot']).entries)
        entry.key:(entry.value! as List).cast<String>().toSet()
    };
    candidates[slotId] = {...?candidates[slotId]}..remove(selected.recipe.id);
    if (candidates[slotId]!.isEmpty) throw StateError('MEAL_CANDIDATES_REQUIRED');
    final goals = <NutrientKey,Exact>{
      for (final entry in _map(guided['targetGoals']).entries)
        NutrientKey.values.singleWhere((key) => key.wire == entry.key):
            Exact.fromJson(_map(entry.value))
    };
    final conditionInput = ConditionGuidanceInput.fromJson(
        _map(metadata['conditionGuidance']));
    final context = PlannerContext(slots:meals.map((meal) => meal.slot).toList(),
        recipes:recipes,seed:values['seed']! as int,maxNodes:20000,
        maximumMinutes:profile.maximumCookingMinutes,maximumRepeats:2,
        strictExclusions:safety.strictExclusions,dietaryTags:profile.dietaryTags,
        unavailableFoodIds:profile.avoidedFoodIds,recipeIdsBySlot:candidates,
        targetGoals:goals,recipePreferenceRanks:
            _map(guided['recipePreferenceRanks']).cast<String,int>(),
        preferredRecipeIds:profile.likedRecipeIds,portions:portions,
        currentFoods:await PlanService(db,clock,ids).currentFoodsForRecipes(recipes),
        conditionGuidance:ConditionGuidancePolicy.assess(input:conditionInput,
            strictExclusions:safety.strictExclusions,
            eatingConcern:safety.eatingConcern == true),
        objectives:[PlannerObjective.practicalPreference,
          if(profile.preferVariety)PlannerObjective.variety,
          PlannerObjective.targetProximity,PlannerObjective.dataCompleteness,
          PlannerObjective.guidance,PlannerObjective.recipePreference,
          if(!profile.preferVariety)PlannerObjective.variety,
          PlannerObjective.cookingEffort,PlannerObjective.ingredientReuse]);
    final result = await _generator(context,[
      for(final meal in meals)
        if(meal.slot.id != slotId)PlannedMeal(meal.slot,meal.recipe,meal.portions,
            pinned:true,batchUse:meal.batchUse)
    ]);
    if(result.status != PlannerStatus.validPlan) {
      throw GuidedPlanException('PLAN_CONSTRAINT_CONFLICT',
          'No alternative fits this meal. Review the selected choices.',
          result.diagnostics);
    }
    final changed = [
      for(final meal in result.meals)PlannedMeal(meal.slot,meal.recipe,meal.portions,
          pinned:meals.any((old) => old.slot.id == meal.slot.id && old.pinned),
          batchUse:meal.batchUse)
    ];
    return store.edit(id:draftId,requestId:requestId,
        expectedRevision:expectedDraftRevision,values:{
          ...values,'meals':changed.map(_mealJson).toList(),
          'groceryAfter':_groceryJson(changed,profile.householdServings),
        });
  }

  Future<MealDraft> accept({required String draftId,
    required int expectedDraftRevision,required int expectedPlanRevision,
    required String requestId}) async {
    final store = MealDraftStore(db);
    final draft = await store.read(draftId);
    if (draft == null || draft.values['kind'] != 'guided-plan-v1') {
      throw StateError('DRAFT_NOT_FOUND');
    }
    final values = draft.values;
    if (values['expectedPlanRevision'] != expectedPlanRevision) {
      throw StateError('STALE_PLAN');
    }
    return store.confirm(id:draftId,requestId:requestId,
        expectedRevision:expectedDraftRevision,reviewed:true,writeLocal:() async {
      final base = _map(values['baseRevisions']);
      final planId = values['planDocumentId']! as String;
      final dependencies = {
        'profile':('nutrition-profile-v1','current'),
        'safety':('profile','safety'),'health':('health-declaration','current'),
        'target':('target','current'),'groceries':('groceries',planId),
        'manualGroceries':('groceries','manual'),
        if (values['completesOnboarding'] == true || values['proposedSettings'] != null)
          'settings':('preferences','app'),
      };
      for (final entry in dependencies.entries) {
        final live = await _workspace.read(entry.value.$1,entry.value.$2);
        if ((live?.revision ?? 0) != base[entry.key]) {
          throw StateError(entry.key == 'profile' ? 'PLAN_PROFILE_STALE' : 'DRAFT_DEPENDENCY_STALE');
        }
      }
      Future<void> put(String key,String collection,String id,String suffix) async {
        await _workspace.put(requestId:'$requestId:$suffix',collection:collection,
            id:id,expectedRevision:base[key]! as int,data:_map(values[key]));
      }
      if (values['writeProfile'] == true) await put('profile','nutrition-profile-v1','current','profile');
      if (values['writeSafety'] == true) await put('safety','profile','safety','safety');
      if (values['writeHealth'] == true) await put('health','health-declaration','current','health');
      if (values['writeTarget'] == true) await put('target','target','current','target');
      final metadata = _map(values['metadata']);
      final saved = await PlanService(db,clock,ids,documentId:planId).save(
          requestId:'$requestId:plan',expectedPlanRevision:expectedPlanRevision,
          expectedProfileRevision:(base['profile']! as int) +
              (values['writeProfile'] == true ? 1 : 0),
          meals:_meals(values['meals']),metadata:metadata,
          seed:values['seed']! as int,policyVersion:values['policyVersion']! as String);
      await GroceryService(db).reconcileOverlayWithPrior(planDocumentId:planId,
          priorMeals:_meals(values['previousMeals']),newMeals:saved.meals,
          priorPlanDocument:_map(values['previousDocument']),
          newPlanDocument:saved.document,requestId:'$requestId:groceries',
          expectedRevision:base['groceries']! as int);
      if (values['completesOnboarding'] == true || values['proposedSettings'] != null) {
        final settings = _map(values['settings']);
        if (values['proposedSettings'] != null) {
          settings.addAll(_map(values['proposedSettings']));
        }
        if (values['completesOnboarding'] == true) {
          settings.remove('onboarded');
          settings['onboardingVersion'] = 2;
        }
        await _workspace.put(requestId:'$requestId:onboarding',
            collection:'preferences',id:'app',
            expectedRevision:base['settings']! as int,data:settings);
      }
    });
  }

  Future<LoggedEntry> consume({required String planDocumentId,
    required String slotId,required Exact portions,required EventStamp stamp,
    required DiaryDate diaryDate,required int expectedPlanRevision,
    required String requestId}) async {
    final plan = await PlanService(db,clock,ids,documentId:planDocumentId).load();
    if (plan == null) throw StateError('PLANNED_MEAL_MISSING');
    final meal = plan.meals.where((meal) => meal.slot.id == slotId).firstOrNull;
    if (meal == null) throw StateError('PLANNED_MEAL_MISSING');
    final state = await _workspace.read('plan-meal-state-v1',
        PlanMealStateService.documentIdFor(planDocumentId,slotId));
    return PlanMealStateService(db).consumePlannedMeal(requestId:requestId,
        meal:meal,planDocumentId:planDocumentId,
        expectedPlanRevision:expectedPlanRevision,expectedStateRevision:state?.revision ?? 0,
        portions:portions,stamp:stamp,offsetMinutes:stamp.offsetMinutes,
        diaryDate:diaryDate,occurredAt:stamp,assignedDiaryDate:diaryDate,
        clock:clock,ids:ids);
  }

  static Map<String,Object?> _mealJson(PlannedMeal meal) => {
    'slot':meal.slot.id,'date':meal.slot.date,'label':meal.slot.label,
    'recipe':recipeSnapshot(meal.recipe),'portions':meal.portions.toJson(),
    'pinned':meal.pinned,
    if (meal.batchUse != null) 'batchUse':{'batchId':meal.batchUse!.batchId,
      'batchRevision':meal.batchUse!.batchRevision,'allocationId':meal.batchUse!.allocationId},
  };
  static List<PlannedMeal> _meals(Object? raw) => [
    for (final value in raw! as List) _mealFromJson(_map(value))
  ];
  static PlannedMeal _mealFromJson(Map<String,Object?> value) {
    final use = value['batchUse'] == null ? null : _map(value['batchUse']);
    return PlannedMeal(MealSlot(value['slot']! as String,value['date']! as String,
        value['label']! as String),recipeFromSnapshot(_map(value['recipe'])),
        Exact.fromJson(_map(value['portions'])),pinned:value['pinned'] == true,
        batchUse:use == null ? null : PlannedBatchUse(use['batchId']! as String,
            use['batchRevision']! as int,use['allocationId']! as String));
  }
  static List<Map<String,Object?>> _groceryJson(List<PlannedMeal> meals,int household) => [
    for (final line in GroceryService.requirementsFor(meals,household))
      {'foodId':line.foodId,'name':line.name,'grams':line.grams.toJson(),
        'preparation':line.preparation.name}
  ];
  static Map<String,Object?> _map(Object? value) =>
      Map<String,Object?>.from(value! as Map);
  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for(final key in keys)key:_canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
