/// Assistant screen: chat + always-available composer + before/after review.
///
/// User text and disclosed plan context are sent only after per-request
/// consent. The exchange stays in memory; only typed changes and request
/// provenance are retained in a reviewable guided draft. A malformed result,
/// foreign id, revoked consent or changed context leaves the plan untouched.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../inference/chatgpt_plan_provider.dart';
import '../../inference/provider_connection.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import 'assistant_controller.dart';
import '../plan/guided_draft_review.dart';

/// Builds the `InferenceRequest` prompt from the explicit user message and
/// the minimal allowlisted context — never the whole workspace.
///
/// Only the locale, the message, the eligible candidate ids, the targeted
/// slot ids, and app-computed plan totals are included. Measurements and
/// health declarations are omitted unless the user explicitly selects
/// sharing in the consent dialog.
String buildAssistantPrompt({
  required String userText,
  required String locale,
  required List<String> eligibleRecipeIds,
  required List<String> slotIds,
  required String planTotals,
  Map<String, Object?> contextDetails = const {},
}) {
  final context = <String, Object?>{
    'schemaName': planAssistanceSchemaName,
    'schemaVersion': 1,
    'locale': locale,
    'message': userText,
    'eligibleRecipeIds': eligibleRecipeIds,
    'slotIds': slotIds,
    'planTotals': planTotals,
    ...contextDetails,
  };
  return jsonEncode(context);
}

/// The composer is always visible, even while [AssistantController.sending]
/// is true; send then shows a cancel affordance instead of disabling the
/// text field.
class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key, this.controller});

  /// Injectable for tests. Production builds the controller from the
  /// provider-connected services.
  final AssistantController? controller;

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final _composer = TextEditingController();
  AssistantController? _owned;
  bool _shareMeasurements = false;
  bool _firstConnectExplained = false;
  String? _selectedSlotId;

  @override
  void initState() {
    super.initState();
    _owned ??= widget.controller;
  }

  @override
  void dispose() {
    _composer.dispose();
    _owned?.dispose();
    super.dispose();
  }

  AssistantController get controller {
    if (_owned != null) return _owned!;
    _owned = _buildController(ref);
    return _owned!;
  }

  AssistantController _buildController(WidgetRef ref) {
    final guided = ref.read(guidedPlanServiceProvider);
    final clock = ref.read(clockProvider);
    final ids = ref.read(idGeneratorProvider);
    String? activeRequestId;
    int requestGeneration = 0;
    String? capturedFingerprint;
    int capturedProfileRevision = 0;
    GuidedPlanProvenance? provenance;

    Future<String> fingerprint() async {
      final workspace = LocalWorkspace(ref.read(databaseProvider));
      final parts = <String>[];
      for (final collection in ['nutrition-profile-v1', 'profile',
          'health-declaration', 'target', 'plan', 'plan-meal-state-v1',
          'recipe', 'meal-content-v1']) {
        final rows = await workspace.list(collection);
        final entries = rows.map((row) => '${row.id}:${row.revision}').toList()..sort();
        parts.add('$collection=${entries.join(",")}');
      }
      return parts.join('|');
    }

    Future<PlanAssistanceSuggestion> decide(String userText) async {
      final locale = Localizations.localeOf(context).languageCode == 'pt'
          ? 'pt-PT' : 'en';
      final generation = ++requestGeneration;
      final before = await fingerprint();
      final db = ref.read(databaseProvider);
      final workspace = LocalWorkspace(db);
      final profileDoc = await workspace.read('nutrition-profile-v1', 'current');
      if (profileDoc == null) throw StateError('PROFILE_REQUIRED');
      final profile = NutritionProfile.fromJson(profileDoc.data);
      final safetyDoc = await workspace.read('profile', 'safety');
      final safety = SafetyProfile.fromJson(safetyDoc?.data ?? {});
      final today = ref.read(todayDiaryDateProvider);
      final plan = await guided.planForDate(today);
      final states = plan == null ? <PlanMealStateRecord>[] :
          await PlanMealStateService(db).listForPlan(plan.documentId);
      final unavailable = states.map((state) => state.slotId).toSet();
      final meals = plan?.meals ?? const <PlannedMeal>[];
      final slotDateById = <String, String>{
        for (final meal in meals) meal.slot.id: meal.slot.date,
      };
      final availableSlotIds = <String>{
        for (final meal in meals)
          if (!meal.pinned && !unavailable.contains(meal.slot.id) &&
              meal.slot.date.compareTo(today.toIso()) >= 0) meal.slot.id,
      };
      final selected = _selectedSlotId;
      if (selected != null && !availableSlotIds.contains(selected)) {
        throw StateError('PLAN_CONTEXT_CHANGED');
      }
      final contents = {for (final row in await workspace.list('meal-content-v1'))
        row.id: row.data};
      final recipes = <RecipeVersion>[];
      for (final row in await workspace.list('recipe')) {
        final recipe = recipeFromSnapshot(row.data);
        final meta = contents[recipe.id];
        if (meta?['revision'] == recipe.revision &&
            recipe.eligible(safety.strictExclusions, profile.dietaryTags,
                unavailableFoodIds: profile.avoidedFoodIds)) {
          recipes.add(recipe);
        }
      }
      final allowedRecipeIds = recipes.map((r) => r.id).toSet();
      final allowedFoodIds = <String>{
        for (final recipe in recipes)
          for (final ingredient in recipe.ingredients) ingredient.food.id,
      };
      final health = _shareMeasurements
          ? await workspace.read('health-declaration', 'current') : null;
      final prompt = buildAssistantPrompt(
        userText: userText, locale: locale,
        eligibleRecipeIds: allowedRecipeIds.toList()..sort(),
        slotIds: availableSlotIds.toList()..sort(),
        planTotals: _planTotals(meals),
        contextDetails: {
          'selectedSlotId': selected,
          'planEndDate': planEndIso(plan),
          'preferences': {
            'mealLabels': profile.mealLabels,
            'maximumCookingMinutes': profile.maximumCookingMinutes,
            'coldLunches': profile.coldLunches,
            'budget': profile.budget,
            'dietaryTags': profile.dietaryTags.toList()..sort(),
          },
          'meals': [for (final meal in meals) {
            'slotId': meal.slot.id, 'date': meal.slot.date,
            'label': meal.slot.label, 'recipeId': meal.recipe.id,
            'recipeName': meal.recipe.name,
            'replaceable': availableSlotIds.contains(meal.slot.id),
          }],
          'candidates': [for (final recipe in recipes) {
            'id': recipe.id, 'name': recipe.name, 'minutes': recipe.minutes,
            'mealLabels': contents[recipe.id]?['mealLabels'],
            'coldSuitable': contents[recipe.id]?['coldSuitable'],
            'costTier': contents[recipe.id]?['costTier'],
          }],
          'foods': [for (final recipe in recipes)
            for (final ingredient in recipe.ingredients)
              {'id': ingredient.food.id, 'name': ingredient.food.name}],
          if (_shareMeasurements) 'measurements': {
            'ageYears': profile.ageYears,
            'heightCm': profile.heightCm?.toJson(),
            'weightKg': profile.weightKg?.toJson(),
            'equationConstant': profile.equationConstant,
            'activityPal': profile.activityPal?.toJson(),
          },
          if (_shareMeasurements) 'healthDeclaration': health?.data,
        },
      );
      if (before != await fingerprint()) throw StateError('PLAN_CONTEXT_CHANGED');
      if (generation != requestGeneration) throw StateError('CANCELLED');
      final requestId = ids.next();
      activeRequestId = requestId;
      final draftId = 'assistant:$requestId';
      // This session is ephemeral: never store the prompt in a workspace draft.
      final session = InferenceDraftSession(MealDraft(id: draftId, values: {}));
      final connection = ref.read(providerConnectionProvider);
      final consent = TransferConsent(
        providerId: connection.providerId, task: InferenceTask.planAssistance,
        payloadClasses: _shareMeasurements ? {'text', 'measurements'} : {'text'},
        requestId: requestId, draftId: draftId,
        draftRevision: session.draft.revision,
        expiresAt: clock.nowUtc().add(const Duration(minutes: 5)),
      );
      final request = InferenceRequest(
        requestId: requestId, task: InferenceTask.planAssistance,
        prompt: prompt, expectedSchema: ChatGptPlanProvider.planAssistanceSchemaJson,
      );
      PlanAssistanceSuggestion? validated;
      AllowlistVerdict? verdict;
      await session.requestSuggestion(
        provider: ref.read(chatGptPlanProvider),
        authorization: connection.toAuthorization(), request: request,
        consent: consent, now: clock.nowUtc(),
        validate: (structured) {
          final parsed = PlanAssistanceSuggestion.fromJson(structured);
          if (parsed.changes?.scope == PlanAssistanceScope.selectedMeal && selected == null) {
            throw StateError('SCOPE_CLARIFICATION_REQUIRED');
          }
          verdict = resolveChangesFor(parsed,
            allowedRecipeIds: allowedRecipeIds, allowedFoodIds: allowedFoodIds,
            allowedSlotIds: slotDateById.keys.toSet(), selectedSlotId: selected,
            availableSlotIds: availableSlotIds, baseProfile: profile, today: today,
            planEndIso: planEndIso(plan), slotDateById: slotDateById,
            slotLabelById: {for (final meal in meals) meal.slot.id: meal.slot.label});
          validated = parsed;
          return {'suggestion': parsed.toJson()};
        },
      );
      if (before != await fingerprint()) throw StateError('PLAN_CONTEXT_CHANGED');
      if (generation != requestGeneration) throw StateError('CANCELLED');
      final suggestion = validated;
      if (suggestion == null) throw StateError('INVALID_SUGGESTION');
      capturedFingerprint = before;
      capturedProfileRevision = profileDoc.revision;
      final model = ref.read(chatGptPlanProvider).takeCompletedModel(requestId);
      if (model == null || model.isEmpty) throw StateError('MODEL_PROVENANCE_MISSING');
      provenance = GuidedPlanProvenance(
        providerId: connection.providerId, model: model,
        schemaVersion: 1, promptVersion: 1,
        requestHash: canonicalRequestHash(prompt),
      );
      controller.verdictBinder = (_) => verdict;
      return suggestion;
    }

    final c = AssistantController(
      decider: decide,
      onCancel: () async {
        requestGeneration++;
        final id = activeRequestId;
        if (id != null) ref.read(chatGptPlanProvider).cancelActive(id);
      },
      onPropose: (verdict) async {
        if (capturedFingerprint == null || capturedFingerprint != await fingerprint()) {
          throw StateError('PLAN_CONTEXT_CHANGED');
        }
        final targetPlan = await guided.planForDate(verdict.resolvedStartDate);
        if (capturedFingerprint != await fingerprint()) throw StateError('PLAN_CONTEXT_CHANGED');
        final draft = await guided.propose(
          requestId: ids.next(),
          expectedProfileRevision: capturedProfileRevision,
          expectedPlanDocumentId: targetPlan?.documentId ?? 'week:${verdict.resolvedStartDate.toIso()}',
          expectedPlanRevision: targetPlan?.revision ?? 0,
          provenance: provenance,
          startDate: verdict.resolvedStartDate,
          proposedProfile: verdict.proposedProfile,
          replaceSlotIds: verdict.resolvedSlotIds.toSet(),
          suggestedRecipeRanks: verdict.suggestedRecipeRanks,
          cookingMinutesBySlot: verdict.cookingMinutesBySlot,
        );
        return draft.id;
      },
      onAccept: (draftId) async {
        final draft = await MealDraftStore(ref.read(databaseProvider))
            .read(draftId);
        if (draft == null) throw StateError('DRAFT_NOT_FOUND');
        final values = draft.values;
        await guided.accept(
          draftId: draftId,
          expectedDraftRevision: draft.revision,
          expectedPlanRevision: values['expectedPlanRevision']! as int,
          requestId: ids.next(),
        );
        ref.invalidate(nutritionProfileProvider);
        ref.invalidate(planForDateProvider);
        ref.invalidate(mealContentProvider);
        ref.invalidate(groceryListProvider);
        ref.invalidate(planMealStateProvider);
        ref.invalidate(todayEntriesProvider);
      },
      providerLabel: 'ChatGPT',
    );
    return c;
  }

  String _planTotals(List<PlannedMeal> meals) {
    var kcal = 0.0;
    var protein = 0.0;
    var energyComplete = true;
    var proteinComplete = true;
    for (final meal in meals) {
      final per = meal.recipe.perServing(meal.portions);
      final energy = per[NutrientKey.energyKcal];
      final proteinValue = per[NutrientKey.proteinG];
      if (energy == null || !energy.isComplete) energyComplete = false;
      if (proteinValue == null || !proteinValue.isComplete) proteinComplete = false;
      kcal += energy?.value ?? 0;
      protein += proteinValue?.value ?? 0;
    }
    return 'kcal=${kcal.round()}${energyComplete ? '' : ' (partial)'},protein_g=${protein.round()}${proteinComplete ? '' : ' (partial)'}';
  }

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(providerConnectionProvider);
    final auth = ref.watch(chatGptAuthProvider);
    final c = controller;
    final plan = ref.watch(planForDateProvider(ref.watch(todayDiaryDateProvider))).valueOrNull;
    final states = plan == null ? <PlanMealStateRecord>[] :
        ref.watch(planMealStateProvider(plan.documentId)).valueOrNull ?? [];
    final unavailableSlots = states.map((state) => state.slotId).toSet();
    final options = plan?.meals.where((meal) => !meal.pinned &&
        !unavailableSlots.contains(meal.slot.id) &&
        meal.slot.date.compareTo(ref.read(todayDiaryDateProvider).toIso()) >= 0).toList() ?? [];
    return ListenableBuilder(listenable: c, builder: (context, _) {
    final sending = c.sending;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'Assistant', 'Assistente')),
      ),
      body: Column(
        children: [
          if (!connection.connected)
            _ConnectionCard(
              firstConnectExplained: _firstConnectExplained,
              onConnect: () async {
                await auth.connect();
                _firstConnectExplained = true;
                setState(() {});
              },
              onExplain: () {
                _firstConnectExplained = true;
                setState(() {});
              },
            ),
          if (connection.connected && !connection.planUsageGranted)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(tr(
                    context,
                    'This account can sign in, but AI plan help is not included. Enable AI to continue.',
                    'Esta conta pode iniciar sessão, mas a ajuda de plano por IA não está incluída. Ative a IA para continuar.')),
              ),
            ),
          if (options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<String>(
                initialValue: options.any((meal) => meal.slot.id == _selectedSlotId) ? _selectedSlotId : null,
                decoration: InputDecoration(labelText: tr(context, 'Selected meal (optional)', 'Refeição selecionada (opcional)')),
                items: [for (final meal in options)
                  DropdownMenuItem(value: meal.slot.id, child: Text('${meal.slot.date} · ${meal.slot.label} · ${meal.recipe.name}', overflow: TextOverflow.ellipsis))],
                onChanged: sending ? null : (value) => setState(() => _selectedSlotId = value),
              ),
            ),
          if (connection.connected && connection.planUsageGranted)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SwitchListTile(
                key: const Key('shareMeasurements'),
                title: Text(tr(
                    context,
                    'Include measurements and health declarations',
                    'Incluir medidas e declarações de saúde')),
                value: _shareMeasurements,
                onChanged: sending ? null : (v) => setState(() => _shareMeasurements = v),
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final turn in c.turns) _TurnTile(turn: turn),
                if (c.turns.any((turn) => turn.role == AssistantTurnRole.user &&
                    (turn.text.toLowerCase().contains('ate out') ||
                     turn.text.toLowerCase().contains('comi fora'))))
                  TextButton.icon(
                    onPressed: () => context.push('/search'),
                    icon: const Icon(Icons.search),
                    label: Text(tr(context, 'Log a meal manually (optional)', 'Registar uma refeição manualmente (opcional)')),
                  ),
                if (sending)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(tr(
                            context, 'Waiting for a reply…', 'A aguardar resposta…')),
                      ),
                      TextButton(
                        key: const Key('cancelInference'),
                        onPressed: () => c.cancel(),
                        child:
                            Text(tr(context, 'Cancel', 'Cancelar')),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('assistantComposer'),
                  controller: _composer,
                  decoration: InputDecoration(
                    labelText: tr(context, 'Ask about your plan', 'Pergunte sobre o seu plano'),
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: null,
                  onSubmitted: (_) => _send(c, connection),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('assistantSend'),
                onPressed: sending
                    ? null
                    : () => _send(c, connection),
                child: Text(tr(context, 'Send', 'Enviar')),
              ),
            ]),
          ),
        ],
      ),
    ); });
  }

  Future<void> _send(
      AssistantController c, ProviderConnectionInfo connection) async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    final ok = await _confirmSend(context, text);
    if (!ok || !mounted) return;
    _composer.clear();
    await c.send(text,
        payloadClasses:
            _shareMeasurements ? {'text', 'measurements'} : {'text'},
        connection: connection);
    if (!mounted) return;
    final proposal = c.pendingProposal;
    if (proposal != null) {
      try {
        await _reviewDraft(context, c);
      } catch (error) {
        if (!mounted) return;
        c.keepCurrentPlan();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error is GuidedPlanException ? error.message : tr(context,
            'The plan could not be prepared. Your current plan is unchanged; please retry or swap manually.',
            'Não foi possível preparar o plano. O plano atual mantém-se; tente novamente ou troque manualmente.'))));
      }
    }
  }

  Future<bool> _confirmSend(BuildContext context, String text) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(tr(context, 'Send to ChatGPT?', 'Enviar para o ChatGPT?')),
            content: Text(_shareMeasurements
              ? tr(context, 'This sends your message, meal and preference context, measurements and health declaration to ChatGPT for this request. Nothing is queued.', 'Este pedido envia a sua mensagem, refeições e preferências, medidas e declaração de saúde ao ChatGPT. Nada fica em fila.')
              : tr(context, 'This sends your message, meal and preference context to ChatGPT for this request. Measurements and health declarations are not included. Nothing is queued.', 'Este pedido envia a sua mensagem, refeições e preferências ao ChatGPT. As medidas e declarações de saúde não são incluídas. Nada fica em fila.')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr(context, 'Cancel', 'Cancelar')),
              ),
              FilledButton(
                key: const Key('confirmSend'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr(context, 'Send', 'Enviar')),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _reviewDraft(
      BuildContext context, AssistantController c) async {
    final draftId = await c.proposePending();
    final draft = await MealDraftStore(ref.read(databaseProvider))
        .read(draftId);
    if (draft == null) throw StateError('DRAFT_NOT_FOUND');
    if (!context.mounted) return;
    await showGuidedDraftReview(
      context,
      draft: draft,
      rationale: c.pendingProposal?.text,
    );
    c.keepCurrentPlan();
  }
}


/// Last scheduled date of a plan, or null when there is no plan.
String? planEndIso(StoredPlan? plan) {
  final schedule = PlanSchedule.fromMetadata(plan?.document['schedule']);
  if (schedule != null) {
    return DiaryDate.parse(schedule.startDate).addDays(schedule.days - 1).toIso();
  }
  if (plan == null || plan.meals.isEmpty) return null;
  var last = plan.meals.first.slot.date;
  for (final meal in plan.meals) {
    if (meal.slot.date.compareTo(last) > 0) last = meal.slot.date;
  }
  return last;
}

/// Allowlist-check entry point shared by the screen and tests.
AllowlistVerdict? resolveChangesFor(
  PlanAssistanceSuggestion suggestion, {
  required Set<String> allowedRecipeIds,
  required Set<String> allowedSlotIds,
  Set<String>? allowedFoodIds,
  String? selectedSlotId,
  Set<String>? availableSlotIds,
  Map<String, String> slotLabelById = const {},
  required NutritionProfile baseProfile,
  required DiaryDate today,
  required String? planEndIso,
  required Map<String, String> slotDateById,
}) {
  if (suggestion.changes == null) return null;
  return resolveChanges(
    suggestion: suggestion,
    allowedRecipeIds: allowedRecipeIds,
    allowedSlotIds: allowedSlotIds,
    allowedFoodIds: allowedFoodIds,
    selectedSlotId: selectedSlotId,
    availableSlotIds: availableSlotIds,
    slotLabelById: slotLabelById,
    baseProfile: baseProfile,
    today: today,
    planEndIso: planEndIso,
    slotDateById: slotDateById,
  );
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.firstConnectExplained,
    required this.onConnect,
    required this.onExplain,
  });
  final bool firstConnectExplained;
  final Future<void> Function() onConnect;
  final VoidCallback onExplain;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!firstConnectExplained)
              Text(tr(
                  context,
                  'Ask about your plan with ChatGPT. Your message and the minimal plan context are processed outside this device for this request only.',
                  'Pergunte sobre o seu plano com o ChatGPT. A sua mensagem e o contexto mínimo do plano são tratados fora deste dispositivo apenas para este pedido.')),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('continueWithChatGpt'),
              onPressed: () async {
                onExplain();
                await onConnect();
              },
              child: Text(tr(
                  context, 'Continue with ChatGPT', 'Continuar com o ChatGPT')),
            ),
          ],
        ),
      ),
    );
  }
}

class _TurnTile extends StatelessWidget {
  const _TurnTile({required this.turn});
  final AssistantTurn turn;

  @override
  Widget build(BuildContext context) {
    final isUser = turn.role == AssistantTurnRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Card(
        color: isUser ? Theme.of(context).colorScheme.primaryContainer : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (turn.errorCode != null) ...[
                Text(switch (turn.errorCode) {
                  'SCOPE_CLARIFICATION_REQUIRED' => tr(context, 'Which meal do you mean? Select a meal above and ask again.', 'A que refeição se refere? Selecione uma refeição acima e pergunte novamente.'),
                  'PLAN_CONTEXT_CHANGED' => tr(context, 'Your plan changed during this request. Please ask again.', 'O seu plano mudou durante este pedido. Pergunte novamente.'),
                  'INVALID_SUGGESTION' => tr(context, 'That response could not be used. Try again or swap a meal manually.', 'Não foi possível utilizar a resposta. Tente novamente ou troque uma refeição manualmente.'),
                  'UNTRUSTED_OR_REVOKED_RESULT' => tr(context, 'This request was invalidated. Please start a new request.', 'Este pedido foi invalidado. Inicie um novo pedido.'),
                  _ => '${tr(context, 'Request failed', 'O pedido falhou')}: ${turn.errorCode}',
                }, key: const Key('assistantError')),
              ] else ...[
                Text(turn.text),
                if (turn.question != null) ...[
                  const SizedBox(height: 4),
                  Text(turn.question!),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Assistant route destination.
class AssistantRouteScreen extends StatelessWidget {
  const AssistantRouteScreen({super.key});

  @override
  Widget build(BuildContext context) => const AssistantScreen();
}
