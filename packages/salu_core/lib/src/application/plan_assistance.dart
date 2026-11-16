/// Strict, closed parser for `salu-plan-assistance-v1` structured output.
///
/// The provider supplies only untrusted data: no arbitrary commands, SQL,
/// external actions, nutrient numbers, targets, credentials, or consent
/// directives may appear. The app binds revisions and allowlisted IDs;
/// this parser rejects unknown fields, unsupported actions/scopes, and
/// malformed types, and enforces the per-action invariants.
library;

/// Structured-output schema name for plan assistance.
const String planAssistanceSchemaName = 'salu-plan-assistance-v1';

/// Budget value accepted by onboarding and plan assistance.
enum PlanBudget { lowerCost, standard, flexible }

/// Action requested by a plan-assistance suggestion.
enum PlanAssistanceAction { explain, clarify, proposePlanChange }

/// Scope a proposed plan change targets.
enum PlanAssistanceScope { selectedMeal, remainingWeek, nextWeek }

/// One validated recipe rank (0-100, lower is better).
final class RecipeRankSuggestion {
  const RecipeRankSuggestion({required this.recipeId, required this.rank});
  final String recipeId;
  final int rank;
  Map<String, Object?> toJson() =>
      <String, Object?>{'recipeId': recipeId, 'rank': rank};
}

/// The `changes` object of a `proposePlanChange` suggestion.
final class PlanChangeSuggestion {
  const PlanChangeSuggestion({
    required this.scope,
    required this.slotIds,
    this.coldLunches,
    this.maximumCookingMinutes,
    this.budget,
    this.avoidFoodIds = const <String>[],
    this.likedRecipeIds = const <String>[],
    this.dislikedRecipeIds = const <String>[],
  });
  final PlanAssistanceScope scope;
  final List<String> slotIds;
  final bool? coldLunches;
  final int? maximumCookingMinutes;
  final PlanBudget? budget;
  final List<String> avoidFoodIds;
  final List<String> likedRecipeIds;
  final List<String> dislikedRecipeIds;

  bool get hasPreferenceChange =>
      coldLunches != null ||
      maximumCookingMinutes != null ||
      budget != null ||
      avoidFoodIds.isNotEmpty ||
      likedRecipeIds.isNotEmpty ||
      dislikedRecipeIds.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'scope': scope.name,
        'slotIds': List<String>.unmodifiable(slotIds),
        'coldLunches': coldLunches,
        'maximumCookingMinutes': maximumCookingMinutes,
        'budget': budget?.name,
        'avoidFoodIds': List<String>.unmodifiable(avoidFoodIds),
        'likedRecipeIds': List<String>.unmodifiable(likedRecipeIds),
        'dislikedRecipeIds': List<String>.unmodifiable(dislikedRecipeIds),
      };
}

/// A validated plan-assistance suggestion.
final class PlanAssistanceSuggestion {
  const PlanAssistanceSuggestion({
    required this.action,
    required this.message,
    this.question,
    this.recipeRanks = const <RecipeRankSuggestion>[],
    this.changes,
  });
  final PlanAssistanceAction action;
  final String message;
  final String? question;
  final List<RecipeRankSuggestion> recipeRanks;
  final PlanChangeSuggestion? changes;

  static const _topKeys = {
    'schemaVersion',
    'action',
    'message',
    'question',
    'recipeRanks',
    'changes',
  };
  static const _rankKeys = {'recipeId', 'rank'};
  static const _changeKeys = {
    'scope',
    'slotIds',
    'coldLunches',
    'maximumCookingMinutes',
    'budget',
    'avoidFoodIds',
    'likedRecipeIds',
    'dislikedRecipeIds',
  };
  static const _budgets = {'lowerCost', 'standard', 'flexible'};

  static Map<String, Object?> _asObject(Object? raw, String what) {
    if (raw is! Map) throw FormatException('$what must be an object');
    final out = <String, Object?>{};
    for (final e in raw.entries) {
      out[e.key.toString()] = e.value;
    }
    return out;
  }

  static List<Object?> _asList(Object? raw, String what) {
    if (raw is! List) throw FormatException('$what must be a list');
    return raw;
  }

  /// Equivalent of `PlanAssistanceSuggestion.fromJson` with contract checks.
  factory PlanAssistanceSuggestion.fromJson(Map<String, Object?> json) {
    void fail(String why) => throw FormatException(why);
    for (final key in json.keys) {
      if (!_topKeys.contains(key)) fail('unknown field: $key');
    }
    for (final key in _topKeys) {
      if (!json.containsKey(key)) fail('missing field: $key');
    }
    if (json['schemaVersion'] != 1) fail('schemaVersion must be 1');
    final actionRaw = json['action'];
    if (actionRaw is! String) fail('action must be a string');
    final PlanAssistanceAction action = switch (actionRaw) {
      'explain' => PlanAssistanceAction.explain,
      'clarify' => PlanAssistanceAction.clarify,
      'proposePlanChange' => PlanAssistanceAction.proposePlanChange,
      _ => throw FormatException('unsupported action: $actionRaw'),
    };
    final messageRaw = json['message'];
    if (messageRaw is! String || messageRaw.trim().isEmpty) {
      fail('message must be a nonempty string');
    }
    final String message = messageRaw as String;
    final qRaw = json['question'];
    if (qRaw != null && qRaw is! String) fail('question must be a string or null');
    final String? questionRaw = qRaw as String?;
    final ranksRaw = _asList(json['recipeRanks'], 'recipeRanks');
    final ranks = <RecipeRankSuggestion>[];
    for (final entry in ranksRaw) {
      final map = _asObject(entry, 'recipeRanks entries');
      for (final key in map.keys) {
        if (!_rankKeys.contains(key)) fail('unknown rank field: $key');
      }
      for (final key in _rankKeys) {
        if (!map.containsKey(key)) fail('missing rank field: $key');
      }
      final idRaw = map['recipeId'];
      final rankRaw = map['rank'];
      if (idRaw is! String || idRaw.isEmpty) fail('recipeId must be nonempty');
      final String id = idRaw as String;
      if (id.contains('://') || id.contains('\n')) {
        fail('recipeId must be an internal id');
      }
      if (rankRaw is! int || rankRaw < 0 || rankRaw > 100) {
        fail('rank must be an integer in 0..100');
      }
      final int rank = rankRaw as int;
      ranks.add(RecipeRankSuggestion(recipeId: id, rank: rank));
    }
    final changesRaw = json['changes'];
    PlanChangeSuggestion? changes;
    if (changesRaw != null) {
      final map = _asObject(changesRaw, 'changes');
      for (final key in map.keys) {
        if (!_changeKeys.contains(key)) fail('unknown changes field: $key');
      }
      for (final key in _changeKeys) {
        if (!map.containsKey(key)) fail('missing changes field: $key');
      }
      final scopeRaw = map['scope'];
      if (scopeRaw is! String) fail('scope must be a string');
      final PlanAssistanceScope scope = switch (scopeRaw as String) {
        'selectedMeal' => PlanAssistanceScope.selectedMeal,
        'remainingWeek' => PlanAssistanceScope.remainingWeek,
        'nextWeek' => PlanAssistanceScope.nextWeek,
        _ => throw FormatException('unsupported scope: $scopeRaw'),
      };
      final slotIdsRaw = _asList(map['slotIds'], 'slotIds');
      final slotIds = <String>[];
      for (final slot in slotIdsRaw) {
        if (slot is! String || slot.isEmpty) fail('slotIds entries must be nonempty strings');
        final String s = slot as String;
        if (slotIds.contains(s)) fail('duplicate slotId: $s');
        slotIds.add(s);
      }
      if (slotIds.isEmpty) fail('slotIds must be nonempty for a plan change');
      final coldRaw = map['coldLunches'];
      if (coldRaw != null && coldRaw is! bool) fail('coldLunches must be bool or null');
      final cookRaw = map['maximumCookingMinutes'];
      int? cooking;
      if (cookRaw != null) {
        if (cookRaw is! int || cookRaw <= 0) fail('maximumCookingMinutes must be a positive int');
        cooking = cookRaw as int;
      }
      PlanBudget? budget;
      final budgetRaw = map['budget'];
      if (budgetRaw != null) {
        if (budgetRaw is! String || !_budgets.contains(budgetRaw)) {
          fail('budget must be lowerCost, standard, or flexible');
        }
        budget = budgetRaw == 'lowerCost'
            ? PlanBudget.lowerCost
            : budgetRaw == 'standard'
                ? PlanBudget.standard
                : PlanBudget.flexible;
      }
      List<String> idList(String key) {
        final raw = map[key];
        if (raw == null) return const <String>[];
        final list = _asList(raw, key);
        final out = <String>[];
        for (final e in list) {
          if (e is! String || e.isEmpty) fail('$key entries must be nonempty strings');
          final String s = e as String;
          if (out.contains(s)) fail('duplicate $key: $s');
          out.add(s);
        }
        return out;
      }

      changes = PlanChangeSuggestion(
        scope: scope,
        slotIds: slotIds,
        coldLunches: coldRaw as bool?,
        maximumCookingMinutes: cooking,
        budget: budget,
        avoidFoodIds: idList('avoidFoodIds'),
        likedRecipeIds: idList('likedRecipeIds'),
        dislikedRecipeIds: idList('dislikedRecipeIds'),
      );
    }
    if (action == PlanAssistanceAction.explain) {
      if (changes != null) fail('explain must have changes: null');
      if (ranks.isNotEmpty) fail('explain must have empty recipeRanks');
      if (questionRaw != null) fail('explain must have question: null');
    } else if (action == PlanAssistanceAction.clarify) {
      if (changes != null) fail('clarify must have changes: null');
      if (ranks.isNotEmpty) fail('clarify must have empty recipeRanks');
      if (questionRaw is! String || questionRaw.trim().isEmpty) {
        fail('clarify requires one nonempty question');
      }
    } else {
      if (changes == null) fail('proposePlanChange requires changes');
      if (questionRaw != null) fail('proposePlanChange must have question: null');
      final c = changes;
      if (c != null && !c.hasPreferenceChange && ranks.isEmpty) {
        fail('proposePlanChange requires at least one actual change');
      }
    }
    return PlanAssistanceSuggestion(
      action: action,
      message: message,
      question: questionRaw,
      recipeRanks: List<RecipeRankSuggestion>.unmodifiable(ranks),
      changes: changes,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': 1,
        'action': action.name,
        'message': message,
        'question': question,
        'recipeRanks':
            <Map<String, Object?>>[for (final r in recipeRanks) r.toJson()],
        'changes': changes?.toJson(),
      };
}
