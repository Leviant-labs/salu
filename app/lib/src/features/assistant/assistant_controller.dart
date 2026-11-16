/// In-memory exchange for the Assistant screen.
///
/// The text the user typed, the model's free-text `message`/`question`, and
/// the conversational exchange stay in memory here. Only the typed,
/// allowlisted plan-change fields — the reviewed profile changes and the
/// generated draft — ever leave the device, through
/// [GuidedPlanService.propose]/[GuidedPlanService.accept]. Nothing here
/// writes a diary entry or commits a plan merely because the model said so.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';

import '../../inference/provider_connection.dart';

/// One chat turn held in memory.
enum AssistantTurnRole { user, assistant }

/// A single line of conversation. The model's free text lives only here and
/// is never persisted to the workspace.
final class AssistantTurn {
  const AssistantTurn({
    required this.role,
    required this.text,
    this.question,
    this.suggestion,
    this.errorCode,
  });

  final AssistantTurnRole role;
  final String text;
  final String? question;
  final PlanAssistanceSuggestion? suggestion;
  final String? errorCode;
}

/// Outcome of validating a structured suggestion against the allowlists.
///
/// The provider cannot supply revisions or allowlisted ids — the app binds
/// them. Anything outside the request's allowlists throws
/// [StateError] with a stable code; nothing is rebased.
final class AllowlistVerdict {
  const AllowlistVerdict({
    required this.resolvedSlotIds,
    required this.resolvedStartDate,
    required this.suggestedRecipeRanks,
    required this.proposedProfile,
    required this.cookingMinutesBySlot,
  });

  /// The slot ids the change is allowed to touch, after scope resolution.
  final List<String> resolvedSlotIds;

  /// The start date for the scoped proposal (`remainingWeek`/`nextWeek`).
  final DiaryDate resolvedStartDate;

  /// Validated recipe ranks for the generated draft (AI may order eligible
  /// candidates only, never widen eligibility).
  final Map<String, int> suggestedRecipeRanks;

  /// The proposed profile with the validated preference changes applied, or
  /// null for an `explain` turn with no profile change.
  final NutritionProfile? proposedProfile;

  /// Per-slot cooking caps for this draft only (selected-meal scope) or for
  /// the resolved window (remaining/next-week scope).
  final Map<String, int> cookingMinutesBySlot;
}

/// Resolves [PlanAssistanceSuggestion.changes] against the app's allowlists.
///
/// [allowedRecipeIds] / [allowedSlotIds] are the exact sets captured when the
/// request was sent. A rank or slot outside them is a hard failure — the
/// model may only order and target ids the app offered. Cooking-minute caps
/// are candidate filters for the resolved slots only, never a global
/// `maximumCookingMinutes` write by themselves.
AllowlistVerdict resolveChanges({
  required PlanAssistanceSuggestion suggestion,
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
  final changes = suggestion.changes;
  if (changes == null) {
    return AllowlistVerdict(
      resolvedSlotIds: const [],
      resolvedStartDate: today,
      suggestedRecipeRanks: const {},
      proposedProfile: null,
      cookingMinutesBySlot: const {},
    );
  }
  for (final slotId in changes.slotIds) {
    if (!allowedSlotIds.contains(slotId)) {
      throw StateError('INVALID_SUGGESTION: slot outside allowlist: $slotId');
    }
  }
  if (changes.slotIds.toSet().length != changes.slotIds.length) {
    throw StateError('INVALID_SUGGESTION: duplicate slotId');
  }
  if (changes.avoidFoodIds.any((id) => !(allowedFoodIds ?? const <String>{}).contains(id)) ||
      [...changes.likedRecipeIds, ...changes.dislikedRecipeIds]
          .any((id) => !allowedRecipeIds.contains(id)) ||
      changes.likedRecipeIds.toSet().intersection(changes.dislikedRecipeIds.toSet()).isNotEmpty) {
    throw StateError('INVALID_SUGGESTION');
  }
  final ranks = <String, int>{};
  for (final rank in suggestion.recipeRanks) {
    if (!allowedRecipeIds.contains(rank.recipeId)) {
      throw StateError(
          'INVALID_SUGGESTION: recipe outside allowlist: ${rank.recipeId}');
    }
    if (ranks.containsKey(rank.recipeId)) throw StateError('INVALID_SUGGESTION');
    if (rank.rank < 0 || rank.rank > 100) {
      throw StateError('INVALID_SUGGESTION: rank out of range');
    }
    ranks[rank.recipeId] = rank.rank;
  }
  switch (changes.scope) {
    case PlanAssistanceScope.selectedMeal:
      if (changes.slotIds.length != 1 ||
          (selectedSlotId != null && changes.slotIds.single != selectedSlotId) ||
          (availableSlotIds != null && !availableSlotIds.contains(changes.slotIds.single))) {
        throw StateError(
            'INVALID_SUGGESTION: selectedMeal requires exactly one slot');
      }
      break;
    case PlanAssistanceScope.remainingWeek:
      if (changes.slotIds.any((id) =>
          (availableSlotIds != null && !availableSlotIds.contains(id)) ||
          (slotDateById[id]?.compareTo(today.toIso()) ?? -1) < 0)) {
        throw StateError('INVALID_SUGGESTION');
      }
      if (changes.coldLunches == true && slotLabelById.isNotEmpty &&
          changes.slotIds.any((id) => slotLabelById[id] != 'lunch')) {
        throw StateError('INVALID_SUGGESTION');
      }
      break;
    case PlanAssistanceScope.nextWeek:
      if (changes.slotIds.isNotEmpty) throw StateError('INVALID_SUGGESTION');
      break;
  }
  final start = switch (changes.scope) {
    PlanAssistanceScope.selectedMeal =>
      DiaryDate.parse(slotDateById[changes.slotIds.first] ?? today.toIso()),
    PlanAssistanceScope.remainingWeek => today,
    PlanAssistanceScope.nextWeek => planEndIso == null
        ? today
        : DiaryDate.parse(planEndIso).addDays(1),
  };
  final resolvedSlots = changes.scope == PlanAssistanceScope.remainingWeek &&
          changes.slotIds.isEmpty && availableSlotIds != null
      ? availableSlotIds.where((id) =>
          (slotDateById[id]?.compareTo(today.toIso()) ?? -1) >= 0 &&
          (changes.coldLunches != true || slotLabelById[id] == 'lunch')).toList()
      : changes.slotIds;
  final cooking = <String, int>{};
  if (changes.maximumCookingMinutes != null &&
      changes.scope == PlanAssistanceScope.selectedMeal) {
    for (final slotId in changes.slotIds) {
      cooking[slotId] = changes.maximumCookingMinutes!;
    }
  }
  final proposed = baseProfile.copyWith(
    coldLunches: changes.coldLunches ?? baseProfile.coldLunches,
    maximumCookingMinutes: changes.scope == PlanAssistanceScope.selectedMeal
        ? baseProfile.maximumCookingMinutes
        : changes.maximumCookingMinutes ?? baseProfile.maximumCookingMinutes,
    budget: changes.budget?.name ?? baseProfile.budget,
    avoidedFoodIds: {
      ...baseProfile.avoidedFoodIds,
      ...changes.avoidFoodIds,
    },
    likedRecipeIds: {
      ...baseProfile.likedRecipeIds.difference(changes.dislikedRecipeIds.toSet()),
      ...changes.likedRecipeIds,
    },
    dislikedRecipeIds: {
      ...baseProfile.dislikedRecipeIds.difference(changes.likedRecipeIds.toSet()),
      ...changes.dislikedRecipeIds,
    },
  );
  return AllowlistVerdict(
    resolvedSlotIds: List.unmodifiable(resolvedSlots),
    resolvedStartDate: start,
    suggestedRecipeRanks: Map.unmodifiable(ranks),
    proposedProfile: jsonEncode(proposed.toJson()) == jsonEncode(baseProfile.toJson())
        ? null : proposed,
    cookingMinutesBySlot: Map.unmodifiable(cooking),
  );
}

/// What the assistant needs from the app to run one turn.
typedef AssistantDecider = Future<PlanAssistanceSuggestion> Function(
    String userText);

/// The controller behind the Assistant screen.
///
/// It assembles the minimal context (locale, the explicit message, the
/// allowlisted eligible candidate ids and slot ids, and app-computed plan
/// totals), validates the structured output against those allowlists, and
/// hands the resolved change to [GuidedPlanService] for a local, reviewable
/// draft. It never persists the free-text exchange and never commits a plan
/// without the review screen's explicit Apply action.
final class AssistantController extends ChangeNotifier {
  AssistantController({
    required this.decider,
    required this.onCancel,
    required this.onPropose,
    required this.onAccept,
    required this.providerLabel,
  });

  /// Runs the provider + reviewed-inference pipeline for one message. The
  /// implementation in `assistant_screen.dart` wraps `ReviewedInferenceService`
  /// + `InferenceDraftSession` + `ChatGptPlanProvider`; tests inject a fake
  /// that returns a pre-validated [PlanAssistanceSuggestion].
  final AssistantDecider decider;

  /// Aborts an in-flight inference. Called when the controller is disposed
  /// or the user cancels.
  final Future<void> Function() onCancel;

  /// Creates (or returns the existing) reviewable draft via
  /// `GuidedPlanService.propose`. Returns the draft id for the review UI.
  final Future<String> Function(AllowlistVerdict verdict) onPropose;

  /// Commits the reviewed draft via `GuidedPlanService.accept`.
  final Future<void> Function(String draftId) onAccept;

  /// Human-readable provider name, e.g. `ChatGPT`.
  final String providerLabel;

  final List<AssistantTurn> _turns = [];
  List<AssistantTurn> get turns => List.unmodifiable(_turns);

  AssistantTurn? get pendingProposal => _pendingVerdict == null
      ? null
      : _turns.where((t) => t.suggestion != null).lastOrNull;

  bool _sending = false;
  bool get sending => _sending;

  String? _errorCode;
  String? get errorCode => _errorCode;

  bool _cancelled = false;
  bool _disposed = false;

  /// Sends one user message.
  ///
  /// [consentText] must already be the result of the explicit per-request
  /// consent dialog (review + payload disclosure + Send). A request cannot
  /// grant consent or enlarge its payload class set — this method only
  /// forwards the already-granted consent.
  Future<void> send(
    String userText, {
    required Set<String> payloadClasses,
    required ProviderConnectionInfo connection,
  }) async {
    final text = userText.trim();
    if (text.isEmpty || _sending) return;
    _pendingVerdict = null;
    if (!connection.connected) {
      _errorCode = 'PROVIDER_NOT_CONNECTED';
      notifyListeners();
      return;
    }
    if (!connection.planUsageGranted) {
      _errorCode = 'PROVIDER_SCOPE_REQUIRED';
      notifyListeners();
      return;
    }
    _sending = true;
    _cancelled = false;
    _errorCode = null;
    _turns.add(AssistantTurn(role: AssistantTurnRole.user, text: text));
    notifyListeners();
    try {
      final suggestion = await decider(text);
      if (_cancelled) return;
      if (suggestion.action == PlanAssistanceAction.proposePlanChange &&
          suggestion.changes != null) {
        final verdict = _bind(suggestion);
        if (verdict != null) _pendingVerdict = verdict;
        _turns.add(AssistantTurn(
          role: AssistantTurnRole.assistant,
          text: suggestion.message,
          suggestion: suggestion,
        ));
      } else {
        _turns.add(AssistantTurn(
          role: AssistantTurnRole.assistant,
          text: suggestion.message,
          question: suggestion.question,
          suggestion: null,
        ));
      }
    } catch (e) {
      if (_cancelled) return;
      final code = _errorCodeOf(e);
      _errorCode = code;
      _turns.add(AssistantTurn(
        role: AssistantTurnRole.assistant,
        text: code,
        errorCode: code,
      ));
    } finally {
      _sending = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Appends an already allowlist-checked turn (e.g. a clarify question
  /// or an explain answer) without touching the pending proposal.
  void appendTurn(AssistantTurn turn) {
    _turns.add(turn);
    notifyListeners();
  }

  /// Hook used by the screen wiring to bind a validated suggestion to the
  /// app-owned allowlists before any draft is generated. Returns null for
  /// non-proposal actions.
  AllowlistVerdict? Function(PlanAssistanceSuggestion suggestion)? verdictBinder;

  AllowlistVerdict? _bind(PlanAssistanceSuggestion suggestion) {
    final binder = verdictBinder;
    if (binder == null) throw StateError('INVALID_SUGGESTION');
    return binder(suggestion);
  }

  /// Proposes the reviewed draft for the pending change and returns its id.
  Future<String> proposePending() async {
    final verdict = _pendingVerdict;
    if (verdict == null) throw StateError('NO_PENDING_PROPOSAL');
    return onPropose(verdict);
  }

  /// Accepts the reviewed draft through the guided service. The screen must
  /// show the before/after review first; this is only called from Apply.
  Future<void> accept(String draftId) => onAccept(draftId);

  /// Keeps the current plan: discards the pending proposal. The stored plan
  /// stays byte-equivalent because nothing was ever written for it.
  void keepCurrentPlan() {
    _pendingVerdict = null;
    notifyListeners();
  }

  /// Cancels an in-flight inference (user pressed Cancel or the widget
  /// unmounted). The next send requires a fresh request + consent.
  Future<void> cancel() async {
    _cancelled = true;
    await onCancel();
    if (!_disposed) notifyListeners();
  }

  AllowlistVerdict? _pendingVerdict;

  /// Stores the allowlist verdict for the pending proposal. Called by the
  /// screen wiring after the decider returns a validated suggestion.
  void stageVerdict(AllowlistVerdict verdict) {
    _pendingVerdict = verdict;
  }

  static String _errorCodeOf(Object e) {
    if (e is StateError) {
      final message = e.message;
      // The core services speak in stable codes; keep the first token.
      final code = message.split(':').first.split(' ').first.trim();
      if (code.isNotEmpty) return code;
      return 'INFERENCE_FAILED';
    }
    return 'INFERENCE_FAILED';
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelled = true;
    unawaited(onCancel());
    super.dispose();
  }
}

/// Hash the exact UTF-8 request payload without retaining its text.
String canonicalRequestHash(String payload) =>
    sha256.convert(utf8.encode(payload)).toString();

