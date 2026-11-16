import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import 'batches_screen.dart';
import '../../ui_support.dart';
import 'grocery_labels.dart';

class PlanScreen extends ConsumerStatefulWidget {
  const PlanScreen({super.key});
  @override
  ConsumerState<PlanScreen> createState() => _PlanState();
}

/// Planner inputs the user owns: schedule, exact tight portions and the hard
/// constraints they explicitly chose. Persisted as plan-document metadata so a
/// constraint change is always one reviewed, revision-checked write.
final class _PlannerSettings {
  _PlannerSettings({
    required this.startDate,
    required this.days,
    required this.label,
    required List<Exact> portions,
    List<String> excludedSlotIds = const [],
    List<String> unavailableFoodIds = const [],
    this.maximumMinutes,
    this.maximumRepeats,
    this.energyMinimum,
    this.energyMaximum,
    this.constraintRevision = 1,
    List<Map<String, Object?>> relaxations = const [],
    List<PlannerRelaxation> acceptedRelaxations = const [],
    List<String> preferredRecipeIds = const [],
    Map<String, Object?> otherPreferences = const {},
  })  : portions = List.unmodifiable(portions),
        excludedSlotIds = List.unmodifiable(excludedSlotIds),
        unavailableFoodIds = List.unmodifiable(unavailableFoodIds),
        relaxations = List.unmodifiable(relaxations),
        acceptedRelaxations = List.unmodifiable(acceptedRelaxations),
        preferredRecipeIds = List.unmodifiable(
            [...preferredRecipeIds.toSet()]..sort()),
        otherPreferences = Map.unmodifiable(otherPreferences);

  factory _PlannerSettings.defaults(String today) => _PlannerSettings(
      startDate: today, days: 7, label: 'dinner', portions: [Exact.one]);

  factory _PlannerSettings.fromDocument(Map<String, Object?> document,
      {required String fallbackDate}) {
    Map<String, Object?> map(Object? value) =>
        value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};
    final rawSchedule = document['schedule'];
    // The shared parser owns the schedule/exclusion shape. Malformed,
    // duplicate, foreign-label or out-of-range exclusions fail closed instead
    // of silently restoring a day the user removed.
    final scheduleMetadata =
        rawSchedule == null ? null : PlanSchedule.fromMetadata(rawSchedule);
    final schedule = map(rawSchedule);
    final rawConstraints = document['constraints'];
    final constraints = rawConstraints == null
        ? <String, Object?>{}
        : rawConstraints is Map
            ? Map<String, Object?>.from(rawConstraints)
            : throw const PlanException('PLAN_CONTEXT_INVALID',
                'The saved plan constraints are invalid; review and save the planner inputs again.');
    // `constraints.unavailableFoodIds` is an optional unique list of stable
    // food ids. Absence alone means none, so a legacy plan never implies an
    // inventory. A present but malformed value fails closed exactly like the
    // transactional data validator; it is never silently read as an empty
    // availability declaration.
    final unavailableFoodIds = <String>[];
    if (constraints.containsKey('unavailableFoodIds')) {
      final rawUnavailable = constraints['unavailableFoodIds'];
      if (rawUnavailable is! List) {
        throw const PlanException('PLAN_CONTEXT_INVALID',
            'The saved unavailable food ids are invalid; review and save the planner inputs again.');
      }
      final seen = <String>{};
      for (final value in rawUnavailable) {
        if (value is! String ||
            value.isEmpty ||
            value.trim() != value ||
            !seen.add(value)) {
          throw const PlanException('PLAN_CONTEXT_INVALID',
              'The saved unavailable food ids are invalid; review and save the planner inputs again.');
        }
        unavailableFoodIds.add(value);
      }
    }
    // `preferences.preferredRecipeIds` is optional soft metadata: absence
    // (including legacy plans) means no preference, while a present but
    // malformed value fails closed instead of silently clearing a reviewed
    // choice. Other preference keys are preserved verbatim.
    final rawPreferences = document['preferences'];
    final preferenceDocument = rawPreferences == null
        ? <String, Object?>{}
        : rawPreferences is Map
            ? Map<String, Object?>.from(rawPreferences)
            : throw const PlanException('PLAN_CONTEXT_INVALID',
                'The saved plan preferences are invalid; review and save the planner inputs again.');
    final preferredRecipeIds = <String>[];
    if (preferenceDocument.containsKey('preferredRecipeIds')) {
      final rawPreferred = preferenceDocument['preferredRecipeIds'];
      if (rawPreferred is! List) {
        throw const PlanException('PLAN_CONTEXT_INVALID',
            'The saved preferred recipe ids are invalid; review and save the planner inputs again.');
      }
      final seen = <String>{};
      for (final value in rawPreferred) {
        if (value is! String ||
            value.isEmpty ||
            value.trim() != value ||
            !seen.add(value)) {
          throw const PlanException('PLAN_CONTEXT_INVALID',
              'The saved preferred recipe ids are invalid; review and save the planner inputs again.');
        }
        preferredRecipeIds.add(value);
      }
      preferredRecipeIds.sort();
    }
    final otherPreferences = <String, Object?>{...preferenceDocument}
      ..remove('preferredRecipeIds');
    final portions = <Exact>[];
    for (final raw in schedule['portions'] as List? ?? const []) {
      try {
        final value = Exact.fromJson(Map<String, Object?>.from(raw as Map));
        if (value.positive) portions.add(value);
      } catch (_) {
        // An unreadable portion is ignored rather than replacing the defaults.
      }
    }
    final relaxations = <Map<String, Object?>>[];
    for (final raw in document['relaxations'] as List? ?? const []) {
      if (raw is Map) relaxations.add(Map<String, Object?>.from(raw));
    }
    final acceptedRelaxations = <PlannerRelaxation>[];
    for (final raw in document['acceptedRelaxations'] as List? ?? const []) {
      if (raw is! Map) continue;
      try {
        acceptedRelaxations
            .add(PlannerRelaxation.fromJson(Map<String, Object?>.from(raw)));
      } catch (_) {
        // A codec change must not prevent the rest of the plan from loading.
      }
    }
    final start = schedule['startDate'];
    final days = schedule['days'];
    final label = schedule['label'];
    final minutes = constraints['maximumMinutes'];
    final repeats = constraints['maximumRepeats'];
    Exact? exact(Object? value) {
      if (value is! Map) return null;
      try {
        return Exact.fromJson(Map<String, Object?>.from(value));
      } catch (_) {
        return null;
      }
    }

    final revision = document['constraintRevision'];
    var effectiveRevision = revision is int && revision >= 1 ? revision : 1;
    for (final change in acceptedRelaxations) {
      if (change.baseRevision >= effectiveRevision) {
        effectiveRevision = change.baseRevision + 1;
      }
    }
    return _PlannerSettings(
      startDate: scheduleMetadata?.startDate ??
          (start is String && _isIsoDate(start) ? start : fallbackDate),
      days: scheduleMetadata?.days ??
          (days is int && days >= 1 && days <= 31 ? days : 7),
      label: scheduleMetadata?.labels.first ??
          (label is String && label.trim().isNotEmpty
              ? label.trim()
              : 'dinner'),
      portions: portions.isEmpty ? [Exact.one] : portions,
      excludedSlotIds: scheduleMetadata?.excludedSlotIds ?? const [],
      unavailableFoodIds: unavailableFoodIds,
      maximumMinutes: minutes is int && minutes > 0 ? minutes : null,
      maximumRepeats: repeats is int && repeats > 0 ? repeats : null,
      energyMinimum: exact(constraints['energyMinimum']),
      energyMaximum: exact(constraints['energyMaximum']),
      constraintRevision: effectiveRevision,
      relaxations: relaxations,
      acceptedRelaxations: acceptedRelaxations,
      preferredRecipeIds: preferredRecipeIds,
      otherPreferences: otherPreferences,
    );
  }

  final String startDate;
  final int days;
  final String label;
  final List<Exact> portions;

  /// Generated slot ids the user explicitly removed from the effective
  /// schedule. Slot ids and dates of every retained day stay unchanged.
  final List<String> excludedSlotIds;

  /// Ingredients the user explicitly declared unavailable. This is a hard
  /// planning constraint, never a pantry inventory and never inferred.
  final List<String> unavailableFoodIds;
  final int? maximumMinutes;
  final int? maximumRepeats;
  final Exact? energyMinimum;
  final Exact? energyMaximum;
  final int constraintRevision;
  final List<Map<String, Object?>> relaxations;
  final List<PlannerRelaxation> acceptedRelaxations;

  /// Explicit soft recipe preferences by stable recipe id. Sorted and unique.
  /// They are a tie-breaker for new selections only and never bypass strict
  /// exclusions, unavailable ingredients or pinned meals.
  final List<String> preferredRecipeIds;

  /// Other top-level `preferences` keys preserved verbatim so planning never
  /// drops sibling preferences it does not own.
  final Map<String, Object?> otherPreferences;

  bool get hasEnergyRange => energyMinimum != null && energyMaximum != null;

  List<NumericConstraint> get numericConstraints => [
        if (hasEnergyRange &&
            energyMinimum!.compareTo(energyMaximum!) <= 0)
          NumericConstraint(
              NutrientKey.energyKcal, energyMinimum!, energyMaximum!)
      ];

  Map<String, Object?> metadata(
      {int? revision, ConditionGuidanceInput? conditionGuidance}) => {
        if (conditionGuidance != null)
          'conditionGuidance': conditionGuidance.toJson(),
        'schedule': {
          'startDate': startDate,
          'days': days,
          'label': label,
          'portions': [for (final p in portions) p.toJson()],
          'excludedSlotIds': excludedSlotIds
        },
        'constraints': {
          'maximumMinutes': maximumMinutes,
          'maximumRepeats': maximumRepeats,
          'energyMinimum': energyMinimum?.toJson(),
          'energyMaximum': energyMaximum?.toJson(),
          'unavailableFoodIds': unavailableFoodIds
        },
        'constraintRevision': revision ?? constraintRevision,
        'relaxations': relaxations,
        'acceptedRelaxations': [
          for (final change in acceptedRelaxations) change.toJson()
        ],
        // Always written so clearing a preference is an explicit reviewed
        // state instead of silently retaining an older selection.
        'preferences': {
          ...otherPreferences,
          'preferredRecipeIds': preferredRecipeIds
        }
      };

  _PlannerSettings withRevision(int revision) => _PlannerSettings(
        startDate: startDate,
        days: days,
        label: label,
        portions: portions,
        excludedSlotIds: excludedSlotIds,
        unavailableFoodIds: unavailableFoodIds,
        maximumMinutes: maximumMinutes,
        maximumRepeats: maximumRepeats,
        energyMinimum: energyMinimum,
        energyMaximum: energyMaximum,
        constraintRevision: revision,
        relaxations: relaxations,
        acceptedRelaxations: acceptedRelaxations,
        preferredRecipeIds: preferredRecipeIds,
        otherPreferences: otherPreferences,
      );

  /// Persists a deliberate change to the set of removed days under a new
  /// constraint revision. Slot ids and dates of retained days never move.
  _PlannerSettings withExclusions(List<String> excluded,
          {required int revision}) =>
      _PlannerSettings(
        startDate: startDate,
        days: days,
        label: label,
        portions: portions,
        excludedSlotIds: excluded,
        unavailableFoodIds: unavailableFoodIds,
        maximumMinutes: maximumMinutes,
        maximumRepeats: maximumRepeats,
        energyMinimum: energyMinimum,
        energyMaximum: energyMaximum,
        constraintRevision: revision,
        relaxations: relaxations,
        acceptedRelaxations: acceptedRelaxations,
        preferredRecipeIds: preferredRecipeIds,
        otherPreferences: otherPreferences,
      );

  bool sameInputs(_PlannerSettings other) {
    final excluded = excludedSlotIds.toSet();
    final otherExcluded = other.excludedSlotIds.toSet();
    return startDate == other.startDate &&
        days == other.days &&
        label == other.label &&
        maximumMinutes == other.maximumMinutes &&
        maximumRepeats == other.maximumRepeats &&
        energyMinimum == other.energyMinimum &&
        energyMaximum == other.energyMaximum &&
        portions.length == other.portions.length &&
        [
          for (var i = 0; i < portions.length; i++)
            portions[i] == other.portions[i]
        ].every((same) => same) &&
        excluded.length == otherExcluded.length &&
        excluded.containsAll(otherExcluded) &&
        unavailableFoodIds.toSet().length ==
            other.unavailableFoodIds.toSet().length &&
        unavailableFoodIds.toSet().containsAll(other.unavailableFoodIds) &&
        preferredRecipeIds.length == other.preferredRecipeIds.length &&
        preferredRecipeIds.toSet().containsAll(other.preferredRecipeIds);
  }

  /// Legacy plan documents predate stored planner inputs. Reconstruct the
  /// schedule from their meals so a reviewed action keeps matching slots
  /// instead of committing today's defaults over an older plan.
  _PlannerSettings derivedFromMeals(List<PlannedMeal> meals) {
    if (meals.isEmpty) return this;
    final dates = meals.map((m) => m.slot.date).toList()..sort();
    final start = DateTime.parse('${dates.first}T00:00:00Z');
    final end = DateTime.parse('${dates.last}T00:00:00Z');
    var days = end.difference(start).inDays + 1;
    if (days < 1) days = 1;
    if (days > 31) days = 31;
    final distinct = <Exact>[];
    for (final meal in meals) {
      if (!distinct.contains(meal.portions)) distinct.add(meal.portions);
    }
    distinct.sort();
    final storedLabel = meals.first.slot.label.trim();
    return _PlannerSettings(
      startDate: dates.first,
      days: days,
      label: storedLabel.isEmpty ? 'meal' : storedLabel,
      portions: distinct.isEmpty ? [Exact.one] : distinct,
      unavailableFoodIds: unavailableFoodIds,
      maximumMinutes: maximumMinutes,
      maximumRepeats: maximumRepeats,
      energyMinimum: energyMinimum,
      energyMaximum: energyMaximum,
      constraintRevision: constraintRevision,
      relaxations: relaxations,
      acceptedRelaxations: acceptedRelaxations,
      preferredRecipeIds: preferredRecipeIds,
      otherPreferences: otherPreferences,
    );
  }

  /// Applies exactly the proposal the user reviewed. Strict exclusions,
  /// dietary declarations and allergens never appear here.
  _PlannerSettings accepted(PlannerRelaxation change,
      {required int revision, required String acceptedAt}) {
    var minutes = maximumMinutes;
    var repeats = maximumRepeats;
    var nextPortions = portions;
    var energyMin = energyMinimum;
    var energyMax = energyMaximum;
    if (change.kind == PlannerRelaxationKind.maximumMinutes) {
      minutes = change.maximumMinutes;
    } else if (change.kind == PlannerRelaxationKind.maximumRepeats) {
      repeats = change.maximumRepeats;
    } else if (change.kind == PlannerRelaxationKind.portions) {
      final proposed = change.portions;
      nextPortions = proposed == null || proposed.isEmpty
          ? [Exact.one]
          : List.unmodifiable(proposed);
    } else if (change.kind == PlannerRelaxationKind.numericConstraint &&
        (change.constraintNutrient == null ||
            change.constraintNutrient == NutrientKey.energyKcal)) {
      energyMin = change.constraint?.minimum;
      energyMax = change.constraint?.maximum;
    }
    return _PlannerSettings(
      startDate: startDate,
      days: days,
      label: label,
      portions: nextPortions,
      excludedSlotIds: excludedSlotIds,
      unavailableFoodIds: unavailableFoodIds,
      maximumMinutes: minutes,
      maximumRepeats: repeats,
      energyMinimum: energyMin,
      energyMaximum: energyMax,
      constraintRevision: revision,
      relaxations: [
        ...relaxations,
        {
          'kind': change.kind.name,
          'reason': change.reason,
          'slotId': change.slotId,
          'previousMaximumMinutes': maximumMinutes,
          'maximumMinutes': minutes,
          'previousMaximumRepeats': maximumRepeats,
          'maximumRepeats': repeats,
          'previousPortions': [for (final p in portions) p.toJson()],
          'portions': [for (final p in nextPortions) p.toJson()],
          'previousEnergyMinimum': energyMinimum?.toJson(),
          'previousEnergyMaximum': energyMaximum?.toJson(),
          'energyMinimum': energyMin?.toJson(),
          'energyMaximum': energyMax?.toJson(),
          'acceptedAt': acceptedAt
        }
      ],
      acceptedRelaxations: [...acceptedRelaxations, change],
      preferredRecipeIds: preferredRecipeIds,
      otherPreferences: otherPreferences,
    );
  }
}

bool _isIsoDate(String value) =>
    RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) &&
    DateTime.tryParse('${value}T00:00:00Z') != null;

String _isoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Exact quantities are never re-rounded through the shortest double string.
String _exactLabel(Exact value) {
  var text = value.toDouble().toStringAsFixed(3);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  text = text.replaceFirst(RegExp(r'\.$'), '');
  return text.isEmpty ? '0' : text;
}

Exact _parseExact(String input) => Exact.parse(input.trim().replaceAll(',', '.'));

Exact _parseExactInput(BuildContext c, String input) {
  try {
    return _parseExact(input);
  } catch (_) {
    throw FormatException(
        tr(c, 'Enter a valid number', 'Introduz um número válido'));
  }
}

String _preparationLabel(BuildContext c, Preparation preparation) =>
    switch (preparation) {
      Preparation.raw => tr(c, 'raw', 'cru'),
      Preparation.cooked => tr(c, 'cooked', 'confeccionado'),
      Preparation.unspecified => tr(c, 'state unspecified', 'estado não especificado')
    };

String _grams(Exact value) => '${_exactLabel(value)} g';

final class _MealEdit {
  const _MealEdit(this.recipe, this.portions);
  final RecipeVersion recipe;
  final Exact portions;
}

/// Reviewed cooked-batch input. Gram stock stores a measured finished weight;
/// serving stock stores an exact equal-serving count and no invented weight.
final class _BatchDraft {
  const _BatchDraft(this.unit, this.amount);
  final FoodUnit unit;
  final Exact amount;

  Map<String, Object?> document(RecipeVersion recipe, String createdAt) => {
        'recipe': recipeSnapshot(recipe),
        'available': amount.toJson(),
        if (unit == FoodUnit.g) 'finishedWeightG': amount.toJson(),
        'unit': unit.name,
        'allocations': <Object?>[],
        'createdAt': createdAt
      };
}

final class _GroceryEdit {
  const _GroceryEdit(this.name, this.grams);
  final String name;
  final Exact? grams;
}

final class _GroceryRow {
  const _GroceryRow(
      this.key, this.name, this.grams, this.preparation, this.checked);
  final String key;
  final String name;
  final Exact grams;
  final Preparation preparation;
  final bool checked;
}

class _PlanState extends ConsumerState<PlanScreen> {
  List<RecipeVersion> recipes = [];
  List<PlannedMeal> meals = [];
  List<BatchStockView> batches = [];
  Map<String, Map<String, Object?>> generatedGroceries = {};
  Map<String, Map<String, Object?>> manualGroceries = {};
  Set<String> strictExclusions = {};

  /// Current declarations read from `health-declaration/current`, the inputs
  /// the applied plan was generated under, and the resulting assessment.
  ConditionGuidanceInput? conditionInput;
  ConditionGuidanceInput? appliedConditionInput;
  ConditionGuidanceAssessment? conditionAssessment;
  ConditionGuidanceReport? conditionReport;

  /// The applied plan predates the current declarations or experimental
  /// policy version; it may only be written again after a repair.
  bool conditionInputStale = false;
  _PlannerSettings settings = _PlannerSettings.defaults('1970-01-01');
  _PlannerSettings appliedSettings = _PlannerSettings.defaults('1970-01-01');
  bool legacyInputs = false;

  /// A pending preferences document exists but cannot be read safely. It is
  /// surfaced and never normalized or applied; the applied plan remains the
  /// displayed source of truth until the user reviews and saves new inputs.
  bool settingsDraftInvalid = false;
  int planRevision = 0;
  bool loaded = false;
  bool busy = false;
  String? status;
  String? _today;
  PlannerContext? pendingContext;

  /// Meals the pending search was allowed to preserve. When declarations
  /// changed this is only pins/consumed history, so accepting a relaxation
  /// cannot silently retain meals ranked under the old conditions.
  List<PlannedMeal> pendingExisting = const [];
  PlannerStatus? pendingStatus;
  List<PlannerRelaxation> relaxations = [];
  List<String> diagnostics = [];

  PlanService get plans => PlanService(ref.read(databaseProvider),
      ref.read(clockProvider), ref.read(idGeneratorProvider));
  LocalWorkspace get store => LocalWorkspace(ref.read(databaseProvider));

  @override
  void initState() {
    super.initState();
    _today = _todayIso();
    settings = _PlannerSettings.defaults(_today!);
    _load();
  }

  String _todayIso() {
    final now = ref.read(clockProvider).nowUtc();
    return DiaryDate.assign(
            EventStamp(instant: now, offsetMinutes: currentOffsetMinutes()))
        .toIso();
  }

  static Map<String, Object?> _groceryItem(Object? raw) {
    if (raw is Map) return Map<String, Object?>.from(raw);
    // Legacy documents stored a bare checked flag per generated line.
    if (raw is bool) return {'checked': raw};
    return <String, Object?>{};
  }

  Future<SafetyProfile> _readSafety() async {
    final doc = await store.read('profile', 'safety');
    return doc == null ? const SafetyProfile() : SafetyProfile.fromJson(doc.data);
  }

  /// Whether a plan's recorded condition inputs match the current declaration
  /// and the current experimental policy. Legality is decided from the stored
  /// declarations, never from a `guidancePolicy` label.
  bool _conditionInputCurrent(
      ConditionGuidanceInput? saved, ConditionGuidanceInput current) {
    if (saved == null) {
      return current.declared.isEmpty && current.unrecognizedDeclared.isEmpty;
    }
    return saved.policyVersion == ConditionGuidancePolicy.version &&
        saved.sameDeclaration(current);
  }

  ConditionGuidanceReport _reportFor(
          ConditionGuidanceAssessment assessment, List<PlannedMeal> selected) =>
      conditionGuidanceReportFor(assessment, selected);

  /// Reads a pending planner-input document. A malformed document is never
  /// interpreted as empty availability: the caller surfaces the invalid draft
  /// and leaves the stored preferences untouched for an explicit review.
  _PlannerSettings? _readDraftSettings(Map<String, Object?> data) {
    try {
      return _PlannerSettings.fromDocument(data,
          fallbackDate: _today ?? _todayIso());
    } catch (_) {
      return null;
    }
  }

  String _invalidDraftMessage(BuildContext c) => tr(
      c,
      'Saved planner inputs are invalid and were not applied. Review and save them in Edit schedule and constraints before planning.',
      'Os dados guardados do planeador são inválidos e não foram aplicados. Revê-os e guarda-os em Editar horário e restrições antes de planear.');

  Future<void> _load() async {
    try {
      final docs = await store.list('recipe');
      final latest = <String, RecipeVersion>{};
      for (final d in docs) {
        final r = recipeFromSnapshot(d.data);
        if ((latest[r.id]?.revision ?? 0) < r.revision) latest[r.id] = r;
      }
      final stored = await plans.load();
      final pending = await store.read('preferences', 'planner');
      final groceries = await store.read('groceries', 'current');
      final manual = await store.read('groceries', 'manual');
      final safety = await _readSafety();
      final currentConditions = await plans.readConditionGuidanceInput();
      final assessment = ConditionGuidancePolicy.assess(
          input: currentConditions,
          strictExclusions: safety.strictExclusions,
          eatingConcern: safety.eatingConcern == true);
      final batchDocs = await store.list('batch');
      final views = <BatchStockView>[];
      for (final d in batchDocs) {
        try {
          views.add(BatchStockView(d));
        } catch (_) {
          // A document that no longer parses is not shown as reservable stock.
        }
      }
      if (!mounted) return;
      final appliedConditions = stored?.conditionGuidance;
      final staleConditions = stored != null &&
          stored.meals.isNotEmpty &&
          !_conditionInputCurrent(appliedConditions, currentConditions);
      var applied = _PlannerSettings.fromDocument(
          stored?.document ?? const {},
          fallbackDate: _today ?? _todayIso());
      if (stored != null &&
          stored.meals.isNotEmpty &&
          stored.document['schedule'] is! Map) {
        applied = applied.derivedFromMeals(stored.meals);
      }
      final draft = pending == null
          ? null
          : _readDraftSettings(pending.data);
      final legacy = stored != null &&
          stored.meals.isNotEmpty &&
          (stored.document['schedule'] is! Map ||
              stored.document['constraints'] is! Map ||
              stored.document['constraintRevision'] is! int ||
              stored.document['relaxations'] is! List ||
              stored.document['acceptedRelaxations'] is! List);
      // A pending edit that has not been applied to a plan survives a reload;
      // once a repair commits it, the plan's applied revision wins.
      final effective = draft != null &&
              draft.constraintRevision > applied.constraintRevision
          ? draft
          : applied;
      final invalidDraft = draft == null && pending != null;
      final invalidDraftMessage =
          invalidDraft ? _invalidDraftMessage(context) : null;
      setState(() {
        recipes = latest.values.toList()
          ..sort((a, b) => a.name.compareTo(b.name));
        meals = stored?.meals ?? [];
        planRevision = stored?.revision ?? 0;
        appliedSettings = applied;
        settings = effective;
        legacyInputs = legacy;
        settingsDraftInvalid = invalidDraft;
        status = invalidDraftMessage;
        generatedGroceries = {
          for (final e in groceries?.data.entries ??
              <MapEntry<String, Object?>>[])
            e.key: _groceryItem(e.value)
        };
        manualGroceries = {
          for (final e
              in manual?.data.entries ?? <MapEntry<String, Object?>>[])
            e.key: Map<String, Object?>.from(e.value as Map)
        };
        strictExclusions = safety.strictExclusions;
        conditionInput = currentConditions;
        appliedConditionInput = appliedConditions;
        conditionAssessment = assessment;
        conditionInputStale = staleConditions;
        conditionReport = !staleConditions && (stored?.meals.isNotEmpty ?? false)
            ? _reportFor(assessment, stored!.meals)
            : null;
        batches = views..sort((a, b) => a.recipe.name.compareTo(b.recipe.name));
        pendingContext = null;
        pendingExisting = const [];
        pendingStatus = null;
        relaxations = [];
        diagnostics = [];
        loaded = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() => loaded = true);
        showFailure(context, e);
      }
    }
  }

  Future<void> _reloadBatches() async {
    final docs = await store.list('batch');
    final views = <BatchStockView>[];
    for (final d in docs) {
      try {
        views.add(BatchStockView(d));
      } catch (_) {
        // See _load.
      }
    }
    if (mounted) {
      setState(() => batches = views
        ..sort((a, b) => a.recipe.name.compareTo(b.recipe.name)));
    }
  }

  BatchStockView? _batchById(String id) =>
      batches.where((b) => b.document.id == id).firstOrNull;

  int get _nextRevision {
    final current = settings.constraintRevision >
            appliedSettings.constraintRevision
        ? settings.constraintRevision
        : appliedSettings.constraintRevision;
    return current + 1;
  }

  bool _staleRecipe(PlannedMeal meal) {
    final current =
        recipes.where((r) => r.id == meal.recipe.id).firstOrNull;
    return current == null ||
        current.revision != meal.recipe.revision ||
        current != meal.recipe;
  }

  void _showPlanFailure(BuildContext c, Object error) {
    if (error is PlanException && error.cause != null) {
      showFailure(c, '${error.message} (${error.cause})');
    } else {
      showFailure(c, error);
    }
  }

  /// A reservation is still spendable only when the batch and its planned
  /// allocation exist at the exact amount this meal would consume.
  bool _liveReservation(PlannedMeal meal) {
    final use = meal.batchUse;
    if (use == null) return false;
    final batch = _batchById(use.batchId);
    final allocation = batch?.allocations
        .where((a) => a.id == use.allocationId)
        .firstOrNull;
    return batch != null &&
        allocation != null &&
        allocation.status == 'planned' &&
        allocation.amount == batch.amountForPortions(meal.portions);
  }

  /// True when this meal's stock allocation exists and is no longer a
  /// reservation. Consumed allocations are accounting history and must stay
  /// in the plan exactly once. A missing allocation has no history to lose.
  bool _holdsConsumedHistory(PlannedMeal meal) {
    final use = meal.batchUse;
    if (use == null) return false;
    final batch = _batchById(use.batchId);
    final allocation = batch?.allocations
        .where((a) => a.id == use.allocationId)
        .firstOrNull;
    return allocation != null && allocation.status != 'planned';
  }

  /// One transactional plan write. Batch reservations are derived from the
  /// stored plan by [PlanService]; this screen never edits batch documents.
  ///
  /// [inputs] commits a newly applied schedule/constraint revision with the
  /// meals generated under it. Ordinary plan actions keep the applied inputs
  /// so a pending, unrepaired edit cannot change the plan's recorded context.
  Future<void> _persistPlan(List<PlannedMeal> next,
      {_PlannerSettings? inputs,
      bool applyInputs = false,
      ConditionGuidanceInput? conditionInput}) async {
    var recorded = applyInputs ? inputs! : appliedSettings;
    // A plan write may only record the declarations the meals were generated
    // under. If the user edited conditions since, the screen refuses the write
    // and asks for a repair instead of silently mixing old meals with new
    // declarations.
    final currentConditions = await plans.readConditionGuidanceInput();
    final expectedConditions = conditionInput ?? appliedConditionInput;
    if (!_conditionInputCurrent(expectedConditions, currentConditions)) {
      throw const PlanException('PLAN_CONDITION_INPUT_STALE',
          'Declared conditions changed since this plan was generated; reload and repair the plan before saving.');
    }
    final recordedConditions = expectedConditions ?? currentConditions;
    final bumpLegacy = !applyInputs &&
        legacyInputs &&
        settings.constraintRevision <= appliedSettings.constraintRevision;
    if (bumpLegacy) recorded = recorded.withRevision(_nextRevision);
    final metadata =
        recorded.metadata(conditionGuidance: recordedConditions);
    // Preserve preference keys written by other features that are present in
    // the stored plan but not in this screen's reviewed inputs.
    final priorPreferences = (await plans.load())?.document['preferences'];
    if (priorPreferences is Map) {
      metadata['preferences'] = {
        ...Map<String, Object?>.from(priorPreferences),
        ...(metadata['preferences']! as Map<String, Object?>)
      };
    }
    final result = await plans.save(
        requestId: ref.read(idGeneratorProvider).next(),
        expectedPlanRevision: planRevision,
        meals: next,
        metadata: metadata,
        seed: 7,
        policyVersion: 'planner-v3');
    if (!mounted) return;
    final savedSafety = await _readSafety();
    if (!mounted) return;
    final assessment = ConditionGuidancePolicy.assess(
        input: currentConditions,
        strictExclusions: savedSafety.strictExclusions,
        eatingConcern: savedSafety.eatingConcern == true);
    final report = _reportFor(assessment, result.meals);
    setState(() {
      planRevision = result.revision;
      meals = result.meals;
      strictExclusions = savedSafety.strictExclusions;
      conditionInput = currentConditions;
      appliedConditionInput = result.conditionGuidance ?? recordedConditions;
      conditionAssessment = assessment;
      conditionReport = report;
      conditionInputStale = false;
      // Any saved plan write invalidates proposals computed against the
      // previous meals or schedule. Accepting one afterwards must re-plan
      // from current state, not install a stale context.
      pendingContext = null;
      pendingExisting = const [];
      pendingStatus = null;
      relaxations = [];
      diagnostics = [];
      if (applyInputs) {
        appliedSettings = recorded;
        settings = recorded;
        legacyInputs = false;
      } else if (bumpLegacy) {
        appliedSettings = recorded;
        legacyInputs = false;
      }
    });
    await _reloadBatches();
  }

  /// Persists an unrepaired schedule/constraint revision. It is not written
  /// into the plan document until a repair commits meals generated under it.
  Future<void> _saveInputs(_PlannerSettings next) async {
    final old = await store.read('preferences', 'planner');
    final metadata = next.metadata();
    final data = <String, Object?>{...?old?.data, ...metadata};
    // Keep sibling preference keys that were already in the draft even when
    // this screen only reviewed the preferred recipe ids.
    final oldPreferences = old?.data['preferences'];
    if (oldPreferences is Map) {
      data['preferences'] = {
        ...Map<String, Object?>.from(oldPreferences),
        ...(metadata['preferences']! as Map<String, Object?>)
      };
    }
    await store.put(
        requestId: ref.read(idGeneratorProvider).next(),
        collection: 'preferences',
        id: 'planner',
        expectedRevision: old?.revision ?? 0,
        data: data);
    if (!mounted) return;
    setState(() => settings = next);
  }

  /// The shared schedule parser owns generated ids, dates and exclusions so
  /// this screen can never disagree with the transactional save.
  PlanSchedule _scheduleOf(_PlannerSettings chosen) {
    final schedule = PlanSchedule.fromMetadata({
      'startDate': chosen.startDate,
      'days': chosen.days,
      'label': chosen.label,
      'excludedSlotIds': chosen.excludedSlotIds,
    });
    if (schedule == null) {
      throw StateError('A planner schedule is required');
    }
    return schedule;
  }

  List<MealSlot> _slots(_PlannerSettings chosen) => _scheduleOf(chosen).slots;

  List<String> _excludedSlotDates(_PlannerSettings chosen) {
    final excluded = chosen.excludedSlotIds.toSet();
    return [
      for (final slot in _scheduleOf(chosen).generatedSlots)
        if (excluded.contains(slot.id)) slot.date
    ];
  }

  /// Ingredient choices offered by the unavailable-food editor. Only foods
  /// that actually occur in planner candidates (the current catalogue and
  /// pinned recipe versions) are offered. This is not a pantry: nothing is
  /// inferred, and a selected id is retained even when its food is no longer
  /// present in any candidate.
  Map<String, String> _unavailableFoodChoices() {
    final choices = <String, String>{};
    void add(RecipeVersion recipe) {
      for (final ingredient in recipe.ingredients) {
        final id = ingredient.food.id;
        if (id.isEmpty) continue;
        final name = ingredient.food.name.trim();
        choices.putIfAbsent(id, () => name.isEmpty ? id : name);
      }
    }

    for (final recipe in recipes) {
      add(recipe);
    }
    for (final meal in meals) {
      if (meal.pinned) add(meal.recipe);
    }
    return choices;
  }

  /// Actual current recipe candidates (latest revision per id plus pinned
  /// revisions), keyed by stable recipe id. This is never a generated list:
  /// only recipes that really exist can be preferred, and a selected id that
  /// no longer exists is retained by the editor rather than discarded.
  Map<String, String> _preferredRecipeChoices() {
    final choices = <String, String>{};
    void add(RecipeVersion recipe) {
      if (recipe.id.isEmpty) return;
      final name = recipe.name.trim();
      choices.putIfAbsent(recipe.id, () => name.isEmpty ? recipe.id : name);
    }

    for (final recipe in recipes) {
      add(recipe);
    }
    for (final meal in meals) {
      if (meal.pinned) add(meal.recipe);
    }
    return choices;
  }

  @override
  Widget build(BuildContext c) => DefaultTabController(
      length: 3,
      child: Column(children: [
        TabBar(tabs: [
          Tab(text: tr(c, 'Recipes', 'Receitas')),
          Tab(text: tr(c, 'Plan', 'Plano')),
          Tab(text: tr(c, 'Groceries', 'Compras'))
        ]),
        Expanded(
            child: !loaded
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(children: [
                    _recipesTab(c),
                    _planTab(c),
                    _groceriesTab(c)
                  ]))
      ]));

  // ---------------------------------------------------------------------------
  // Recipes
  // ---------------------------------------------------------------------------

  Widget _recipesTab(BuildContext c) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton.icon(
                icon: const Icon(Icons.add),
                label: Text(tr(c, 'Create recipe', 'Criar receita')),
                onPressed: () => _recipe(c)),
            Text(tr(
                c,
                'Ingredient calculations do not model cooking losses. Equal servings do not require a finished weight.',
                'Os cálculos dos ingredientes não modelam perdas na confeção. As porções iguais não exigem peso final.')),
            OutlinedButton(
                onPressed: () => Navigator.push<void>(c,
                    MaterialPageRoute(builder: (_) => const BatchesScreen())),
                child: Text(
                    tr(c, 'View cooked batches', 'Ver lotes confecionados'))),
            for (final r in recipes)
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(r.name),
                  subtitle: Text(
                      '${number(r.servings.toDouble())} ${tr(c, 'servings', 'porções')} · ${r.minutes} min · v${r.revision}'),
                  trailing: PopupMenuButton<String>(
                      onSelected: (action) => action == 'log'
                          ? _logRecipe(c, r, Exact.one)
                          : action == 'batch'
                              ? _batch(c, r)
                              : _recipe(c, r),
                      itemBuilder: (c) => [
                            PopupMenuItem(
                                value: 'log',
                                child: Text(tr(c, 'Log a consumed portion',
                                    'Registar uma porção consumida'))),
                            PopupMenuItem(
                                value: 'batch',
                                child: Text(tr(c, 'Record a cooked batch',
                                    'Registar um lote confecionado'))),
                            PopupMenuItem(
                                value: 'edit',
                                child: Text(tr(c, 'Create revised version',
                                    'Criar versão revista')))
                          ]))
          ]);

  Future<void> _recipe(BuildContext c, [RecipeVersion? existing]) async {
    await Navigator.push<void>(c,
        MaterialPageRoute(builder: (_) => _RecipeEditor(existing: existing)));
    await _load();
  }

  Future<void> _logRecipe(BuildContext c, RecipeVersion recipe, Exact initial) async {
    final amount = await askText(c,
        title:
            tr(c, 'Servings actually consumed', 'Porções realmente consumidas'),
        initial: _exactLabel(initial));
    if (amount == null || !c.mounted) return;
    try {
      final portions = _parseExactInput(c, amount);
      if (!c.mounted) return;
      if (!await confirmAction(
          c,
          tr(c, 'Record consumed recipe?', 'Registar receita consumida?'),
          tr(
              c,
              'Only confirm food you actually consumed. This writes intake; the plan itself is not intake. Cooking losses are not modeled.',
              'Confirma apenas o que realmente consumiste. Isto registra consumo; o plano em si não é consumo. As perdas na confeção não são modeladas.'))) {
        return;
      }
      await LogRecipeHandler(ref.read(entryRepositoryProvider),
              ref.read(clockProvider), ref.read(idGeneratorProvider))
          .handle(LogRecipeCommand(
              requestId: ref.read(idGeneratorProvider).next(),
              recipe: recipe,
              portions: portions,
              offsetMinutes: currentOffsetMinutes(),
              confirmed: true,
              channel: EntryChannel.plan));
      ref.invalidate(todayEntriesProvider);
      if (mounted) {
        setState(() => status = tr(
            c,
            'Intake recorded in the diary. The plan entry is unchanged; intake stays separate from planning.',
            'Consumo registado no diário. A entrada do plano mantém-se; o consumo continua separado do planeamento.'));
      }
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _batch(BuildContext c, RecipeVersion recipe) async {
    final draft = await showDialog<_BatchDraft>(
        context: c,
        builder: (_) => _BatchCreateDialog(recipe: recipe));
    if (draft == null || !c.mounted) return;
    try {
      final detail = draft.unit == FoodUnit.g
          ? tr(
              c,
              'Confirm the measured edible ingredients match this recipe version. If ingredients changed, create a revised recipe first. Cooking losses are not modeled.',
              'Confirma que os ingredientes comestíveis medidos correspondem a esta versão da receita. Se mudaram, cria primeiro uma versão revista. As perdas na confeção não são modeladas.')
          : tr(
              c,
              'Confirm the cooked ingredients match this recipe version and the batch is divided into ${_exactLabel(draft.amount)} equal servings. No finished weight is measured or guessed; nutrition per serving uses the recipe total divided by its declared servings. Cooking losses are not modeled.',
              'Confirma que os ingredientes confecionados correspondem a esta versão da receita e que o lote foi dividido em ${_exactLabel(draft.amount)} porções iguais. Não é medido nem presumido qualquer peso final; a nutrição por porção usa o total da receita dividido pelas porções declaradas. As perdas na confeção não são modeladas.');
      if (!await confirmAction(
          c,
          tr(c, 'Confirm batch ingredients', 'Confirmar ingredientes do lote'),
          detail)) {
        return;
      }
      if (!c.mounted) return;
      final id = ref.read(idGeneratorProvider).next();
      await store.put(
          requestId: 'batch:$id',
          collection: 'batch',
          id: id,
          expectedRevision: 0,
          data: draft.document(
              recipe, ref.read(clockProvider).nowUtc().toIso8601String()));
      await _reloadBatches();
      if (!c.mounted) return;
      ScaffoldMessenger.of(c).showSnackBar(SnackBar(
          content:
              Text(tr(c, 'Cooked batch saved', 'Lote confecionado guardado'))));
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  // ---------------------------------------------------------------------------
  // Plan
  // ---------------------------------------------------------------------------

  Widget _planTab(BuildContext c) {
    final slots = _slots(settings);
    final slotDates = {for (final slot in slots) slot.id: slot.date};
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(tr(
          c,
          'Plans organize future meals. Nothing here counts as consumed until you confirm it, and no diary entry is written by planning.',
          'Os planos organizam refeições futuras. Nada conta como consumido até à tua confirmação, e o planeamento não escreve no diário.')),
      const SizedBox(height: 12),
      _conditionGuidanceCard(c),
      const SizedBox(height: 12),
      _scheduleCard(c),
      if (status != null) ...[
        const SizedBox(height: 12),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(status!,
                    style: Theme.of(c).textTheme.bodyMedium))),
      ],
      if (pendingStatus != null) ...[
        const SizedBox(height: 12),
        _relaxationCard(c),
      ],
      if (meals.isEmpty)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(slots.isEmpty
                ? tr(
                    c,
                    'Every day in the current schedule is excluded, so there is no slot to plan. Edit the schedule to restore an excluded day.',
                    'Todos os dias do horário atual estão excluídos, por isso não há espaço para planear. Edita o horário para restaurar um dia excluído.')
                : tr(
                    c,
                    'No meals are planned yet. Build a plan from the recipe catalogue or change the schedule.',
                    'Ainda não há refeições planeadas. Cria um plano a partir das receitas ou altera o horário.'))),
      for (final meal in meals)
        _mealCard(c, meal, slotDates, conditionReport),
      if (meals.isNotEmpty)
        Text(tr(
            c,
            'Recipe revisions and batches stay immutable; changing an ingredient requires a new recipe version.',
            'As versões das receitas e os lotes são imutáveis; alterar um ingrediente exige uma nova versão da receita.'),
            style: Theme.of(c).textTheme.bodySmall),
    ]);
  }

  Widget _scheduleCard(BuildContext c) {
    final slots = _slots(settings);
    final excludedDates = _excludedSlotDates(settings);
    final unavailableNames = _unavailableFoodChoices();
    final preferredNames = _preferredRecipeChoices();
    return Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tr(c, 'Schedule and hard constraints',
                        'Horário e restrições rígidas'),
                    style: Theme.of(c).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                    '${settings.days} ${tr(c, 'days from', 'dias desde')} ${settings.startDate} · ${settings.label}'),
                Text(
                    '${tr(c, 'Portion options', 'Opções de porção')}: ${settings.portions.map(_exactLabel).join(', ')}'),
                if (excludedDates.isNotEmpty)
                  Text(
                      '${tr(c, 'Excluded days (no meal is planned)', 'Dias excluídos (sem refeição planeada)')}: ${excludedDates.join(', ')}'),
                if (settings.maximumMinutes != null)
                  Text(
                      '${tr(c, 'Maximum cooking time', 'Tempo máximo de confeção')}: ${settings.maximumMinutes} min'),
                if (settings.maximumRepeats != null)
                  Text(
                      '${tr(c, 'Maximum repeats of one recipe', 'Repetições máximas de uma receita')}: ${settings.maximumRepeats}'),
                if (settings.hasEnergyRange)
                  Text(
                      '${tr(c, 'Binding daily energy range', 'Intervalo energético diário obrigatório')}: ${_exactLabel(settings.energyMinimum!)}–${_exactLabel(settings.energyMaximum!)} kcal'),
                if (settings.preferredRecipeIds.isNotEmpty)
                  Text(
                      '${tr(c, 'Preferred recipes (soft; never overrides allergies, availability or pins)', 'Receitas preferidas (suave; nunca sobrepõe alergias, disponibilidade ou fixações)')}: ${([for (final id in settings.preferredRecipeIds) preferredNames[id] ?? id]..sort()).join(', ')}',
                      style: Theme.of(c).textTheme.bodySmall),
                if (settings.unavailableFoodIds.isNotEmpty)
                  Text(
                      '${tr(c, 'Unavailable ingredients (hard constraint; never relaxed automatically)', 'Ingredientes indisponíveis (restrição rígida; nunca relaxada automaticamente)')}: ${([for (final id in settings.unavailableFoodIds) unavailableNames[id] ?? id]..sort()).join(', ')}',
                      style: Theme.of(c).textTheme.bodySmall)
                else
                  Text(
                      tr(
                          c,
                          'No ingredients are marked unavailable. Salu never guesses pantry stock; only ingredients you explicitly select become unavailable.',
                          'Não há ingredientes marcados como indisponíveis. O Salu nunca presume stock da despensa; só os ingredientes que selecionares explicitamente ficam indisponíveis.'),
                      style: Theme.of(c).textTheme.bodySmall),
                if (settings.constraintRevision >
                    appliedSettings.constraintRevision)
                  Text(
                      tr(
                          c,
                          'These inputs are saved but only apply after you repair the plan.',
                          'Estes dados estão guardados mas só são aplicados depois de reparares o plano.'),
                      style: Theme.of(c).textTheme.bodySmall),
                if (slots.isEmpty)
                  Text(
                      tr(
                          c,
                          'All days are excluded. Restore an excluded day in the schedule before building or repairing a plan.',
                          'Todos os dias estão excluídos. Restaura um dia excluído no horário antes de criar ou reparar um plano.'),
                      style: Theme.of(c).textTheme.bodySmall),
                const SizedBox(height: 8),
                Text(
                    strictExclusions.isEmpty
                        ? tr(
                            c,
                            'No strict exclusions are declared. Medical and allergy exclusions are immutable safety constraints when declared.',
                            'Não há exclusões rígidas declaradas. Quando declaradas, as exclusões médicas e de alergias são restrições de segurança imutáveis.')
                        : '${tr(c, 'Strict exclusions from your safety declarations (immutable)', 'Exclusões rígidas das tuas declarações de segurança (imutáveis)')}: ${(strictExclusions.toList()..sort()).join(', ')}',
                    style: Theme.of(c).textTheme.bodySmall),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                      icon: const Icon(Icons.tune),
                      label: Text(tr(c, 'Edit schedule and constraints',
                          'Editar horário e restrições')),
                      onPressed: busy ? null : () => _editSchedule(c)),
                  FilledButton.icon(
                      icon: const Icon(Icons.calendar_month_outlined),
                      label: Text(meals.isEmpty
                          ? tr(c, 'Build plan', 'Criar plano')
                          : tr(c, 'Repair plan', 'Reparar plano')),
                      onPressed: busy || recipes.isEmpty || slots.isEmpty
                          ? null
                          : () => _generate())
                ])
              ])));
  }

  Widget _relaxationCard(BuildContext c) {
    final original = pendingStatus == PlannerStatus.proposedRelaxation
        ? null
        : pendingStatus;
    return Card(
        color: Theme.of(c).colorScheme.surfaceContainerHighest,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr(c, 'No plan was installed', 'Nenhum plano foi instalado'),
                  style: Theme.of(c).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(tr(
                  c,
                  'Choose at most one adjustment to review. Medical exclusions, declared diet restrictions, allergens, unknown allergen status and unavailable ingredients are never relaxed.',
                  'Escolhe no máximo um ajuste para rever. As exclusões médicas, as restrições alimentares declaradas, os alergénios, o estado desconhecido de alergénios e os ingredientes indisponíveis nunca são relaxados.')),
              if (original != null)
                Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        '${tr(c, 'Result', 'Resultado')}: ${original.name}')),
              if (diagnostics.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(diagnostics.join('; '),
                        style: Theme.of(c).textTheme.bodySmall)),
              for (final change in relaxations)
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_relaxationLabel(c, change)),
                    subtitle: Text(_reasonLabel(c, change.reason)),
                    trailing: TextButton(
                        onPressed: busy ? null : () => _accept(c, change),
                        child: Text(tr(c, 'Review', 'Rever')))),
              if (relaxations.isEmpty && original != null)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(tr(
                        c,
                        'No non-medical adjustment can resolve this with the current recipe catalogue and pins.',
                        'Nenhum ajuste não médico resolve isto com o catálogo de receitas e as fixações atuais.'))),
            ])));
  }

  Widget _mealCard(BuildContext c, PlannedMeal meal,
      Map<String, String> slotDates, ConditionGuidanceReport? guidance) {
    final batch = meal.batchUse == null
        ? null
        : _batchById(meal.batchUse!.batchId);
    final allocation = batch?.allocations
        .where((a) => a.id == meal.batchUse!.allocationId)
        .firstOrNull;
    // A matching id with a different date is still outside the schedule: a
    // schedule edit must never be read as if the saved meal had moved with it.
    final outsideSchedule = slotDates[meal.slot.id] != meal.slot.date;
    final staleRecipe = _staleRecipe(meal);
    final conditionValues = <String>[];
    if (guidance != null) {
      for (final key in guidance.displayNutrients) {
        final sum = meal.nutrients[key];
        final known = sum != null &&
            sum.knownEntries > 0 &&
            sum.isComplete &&
            !sum.includesEstimate;
        conditionValues.add(known
            ? '${nutrientLabel(c, key.wire)} ${_exactLabel(sum.exactValue)} ${key.unit}'
            : '${nutrientLabel(c, key.wire)} ${tr(c, 'unknown', 'desconhecido')}');
      }
    }
    final conditionLine = conditionValues.isEmpty
        ? null
        : '${tr(c, 'Condition data (experimental)', 'Dados por condição (experimental)')}: ${conditionValues.join(' · ')}';
    final reservationText = meal.batchUse == null
        ? null
        : batch == null || allocation == null
            ? tr(c,
                'Reserved batch stock is no longer available. Remove this meal before repairing.',
                'O stock reservado já não está disponível. Remove esta refeição antes de reparar.')
            : allocation.status != 'planned'
                ? tr(c,
                    'This stock was recorded as consumed and is counted once. It is never returned to stock.',
                    'Este stock foi registado como consumido e é contado uma vez. Nunca regressa ao stock.')
                : allocation.amount != batch.amountForPortions(meal.portions)
                    ? tr(c,
                        'The reservation no longer matches this portion. Review the meal before repairing.',
                        'A reserva já não corresponde a esta porção. Revê a refeição antes de reparar.')
                    : '${tr(c, 'Reserved', 'Reservado')} ${batchAmountLabel(c, batch.unit, batch.amountForPortions(meal.portions))} · ${tr(c, 'batch remaining', 'restante no lote')} ${batchAmountLabel(c, batch.unit, batch.remaining)}';
    final live = meal.batchUse == null || _liveReservation(meal);
    return Card(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
          leading: IconButton(
              tooltip: meal.pinned
                  ? tr(c, 'Unpin meal', 'Desafixar refeição')
                  : tr(c, 'Pin meal', 'Fixar refeição'),
              icon: Icon(
                  meal.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              onPressed: busy ? null : () => _pin(c, meal)),
          title: Text(meal.recipe.name),
          subtitle: Text([
            '${meal.slot.date} · ${meal.slot.label} · ${_exactLabel(meal.portions)} ${tr(c, 'servings', 'porções')}',
            if (reservationText != null) reservationText,
            if (conditionLine != null) conditionLine,
            if (staleRecipe)
              tr(c,
                  'This saved recipe revision is not current; repair the plan before changing meals or stock.',
                  'Esta revisão guardada da receita já não está atual; repara o plano antes de alterar refeições ou stock.'),
            if (meal.pinned && outsideSchedule)
              tr(c,
                  'Pinned outside the current schedule. Unpin or remove it before repairing.',
                  'Fixada fora do horário atual. Desafixa ou remove antes de reparar.'),
            if (outsideSchedule &&
                !meal.pinned &&
                allocation != null &&
                allocation.status != 'planned')
              tr(c,
                  'This consumed meal is outside the current schedule; repair would drop it from the plan. Restore its day first. The consumed stock is never returned.',
                  'Esta refeição consumida está fora do horário atual; a reparação iria removê-la do plano. Restaura o dia primeiro. O stock consumido nunca regressa.')
          ].join('\n')),
          isThreeLine: reservationText != null ||
              outsideSchedule ||
              staleRecipe ||
              conditionLine != null,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: tr(c, 'Confirm actual intake',
                    'Confirmar consumo real'),
                icon: const Icon(Icons.restaurant_outlined),
                onPressed: busy || !live ? null : () => _consume(c, meal)),
            PopupMenuButton<String>(
                tooltip: tr(c, 'Meal options', 'Opções da refeição'),
                onSelected: (action) => _mealAction(c, meal, action),
                itemBuilder: (_) => [
                      PopupMenuItem(
                          value: 'edit',
                          child: Text(tr(c, 'Edit recipe or portions',
                              'Editar receita ou porções'))),
                      if (meal.batchUse == null)
                        PopupMenuItem(
                            value: 'reserve',
                            child: Text(tr(c, 'Reserve cooked batch stock',
                                'Reservar stock de lote confecionado'))),
                      if (meal.batchUse != null && live)
                        PopupMenuItem(
                            value: 'release',
                            child: Text(tr(c, 'Release reservation',
                                'Libertar reserva'))),
                      PopupMenuItem(
                          value: 'remove',
                          child: Text(tr(c, 'Remove from plan',
                              'Remover do plano')))
                    ])
          ])),
    ]));
  }

  Future<void> _pin(BuildContext c, PlannedMeal selected) async {
    try {
      await _persistPlan([
        for (final m in meals)
          m.slot.id == selected.slot.id
              ? PlannedMeal(m.slot, m.recipe, m.portions,
                  pinned: !m.pinned, batchUse: m.batchUse)
              : m
      ]);
    } catch (e) {
      if (!c.mounted) return;
      _showPlanFailure(c, e);
      await _load();
    }
  }

  Future<void> _editSchedule(BuildContext c) async {
    final safety = await _readSafety();
    if (!c.mounted) return;
    final next = await showDialog<_PlannerSettings>(
        context: c,
        builder: (_) => _ScheduleEditor(
            initial: settings,
            strictExclusions: safety.strictExclusions,
            unavailableFoodChoices: _unavailableFoodChoices(),
            recipeChoices: _preferredRecipeChoices()));
    if (next == null || !c.mounted) return;
    // Saving is the recovery path for an invalid pending document even when
    // the reviewed values match the applied plan: the write replaces the
    // unreadable draft with a valid, explicitly reviewed revision.
    if (!settingsDraftInvalid && next.sameInputs(settings)) return;
    setState(() => busy = true);
    try {
      await _saveInputs(next);
      if (!c.mounted) return;
      setState(() {
        settingsDraftInvalid = false;
        status = tr(
            c,
            'Constraint revision ${next.constraintRevision} saved. Repair the plan to apply it.',
            'Revisão de restrições ${next.constraintRevision} guardada. Repara o plano para aplicá-la.');
        pendingContext = null;
        pendingExisting = const [];
        pendingStatus = null;
        relaxations = [];
        diagnostics = [];
      });
    } catch (e) {
      if (!c.mounted) return;
      showFailure(c, e);
      await _load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<PlannerContext> _plannerContext(
      {SafetyProfile? safety,
      _PlannerSettings? chosen,
      ConditionGuidanceAssessment? conditionGuidance}) async {
    final profile = safety ?? await _readSafety();
    final inputs = chosen ?? settings;
    final candidates = <String, RecipeVersion>{
      for (final r in recipes) '${r.id}:${r.revision}': r
    };
    // A pinned meal keeps its immutable recipe version as a candidate; if the
    // version conflicts with a declared exclusion the planner reports a
    // conflict instead of silently replacing the pin.
    for (final m in meals) {
      if (m.pinned) {
        candidates.putIfAbsent(
            '${m.recipe.id}:${m.recipe.revision}', () => m.recipe);
      }
    }
    // The commit validates against current catalogue definitions. Resolve the
    // same definitions here so repair cannot select a stale ingredient snapshot
    // that save would reject; local/offline recipes keep their snapshots.
    final currentFoods =
        await plans.currentFoodsForRecipes(candidates.values);
    // Active condition guidance is a relative-guidance objective. Rank it
    // before generic data completeness so a known decisive nutrient is not
    // overridden by unrelated known cells; missing data still carries its own
    // penalty inside the guidance score.
    final objectives = conditionGuidance != null &&
            conditionGuidance.directives.isNotEmpty
        ? const [
            PlannerObjective.targetProximity,
            PlannerObjective.guidance,
            PlannerObjective.dataCompleteness,
            PlannerObjective.recipePreference,
            PlannerObjective.cookingEffort,
            PlannerObjective.ingredientReuse,
            PlannerObjective.variety,
          ]
        : defaultPlannerObjectives;
    return PlannerContext(
        slots: _slots(inputs),
        recipes: candidates.values.toList(),
        seed: 7,
        portions: inputs.portions,
        maximumMinutes: inputs.maximumMinutes,
        maximumRepeats: inputs.maximumRepeats,
        strictExclusions: profile.strictExclusions,
        unavailableFoodIds: inputs.unavailableFoodIds.toSet(),
        constraints: inputs.numericConstraints,
        batches: [for (final b in batches) b.cookedBatch],
        revision: inputs.constraintRevision,
        acceptedRelaxations: inputs.acceptedRelaxations,
        currentFoods: currentFoods,
        objectives: objectives,
        // Soft tie-breaker only. Explicit ids never add an ineligible recipe,
        // bypass a pin or relax a safety/availability constraint.
        preferredRecipeIds: inputs.preferredRecipeIds.toSet(),
        // Relative experimental objective only. It cannot make an ineligible
        // recipe feasible and it never writes intake.
        conditionGuidance: conditionGuidance);
  }

  Future<void> _generate() async {
    if (busy) return;
    final build = context;
    if (settingsDraftInvalid) {
      setState(() {
        status = _invalidDraftMessage(build);
        pendingContext = null;
        pendingExisting = const [];
        pendingStatus = null;
        relaxations = [];
        diagnostics = [];
      });
      return;
    }
    if (_slots(settings).isEmpty) {
      setState(() {
        status = tr(
            build,
            'All days are excluded. Restore an excluded day in the schedule before building or repairing a plan.',
            'Todos os dias estão excluídos. Restaura um dia excluído no horário antes de criar ou reparar um plano.');
        pendingContext = null;
        pendingExisting = const [];
        pendingStatus = null;
        relaxations = [];
        diagnostics = [];
      });
      return;
    }
    setState(() {
      busy = true;
      status = null;
      pendingContext = null;
      pendingExisting = const [];
      pendingStatus = null;
      relaxations = [];
      diagnostics = [];
    });
    try {
      final safety = await _readSafety();
      final currentConditions = await plans.readConditionGuidanceInput();
      final assessment = ConditionGuidancePolicy.assess(
          input: currentConditions,
          strictExclusions: safety.strictExclusions,
          eatingConcern: safety.eatingConcern == true);
      final planner = await _plannerContext(
          safety: safety, conditionGuidance: assessment);
      // When declarations changed, or a safety-profile eating concern is
      // active, retain only pins/consumed history. A fully valid old plan would
      // otherwise be returned unchanged and restrictive guidance from an
      // earlier state could survive.
      final conditionsChanged =
          !_conditionInputCurrent(appliedConditionInput, currentConditions) ||
              safety.eatingConcern == true;
      // Preserve pins and meals that hold consumed stock history. Other
      // unchanged meals may be re-ranked; dropping a consumed record would
      // lose accounting that the ordinary remove flow refuses to lose.
      final existing = conditionsChanged
          ? meals
              .where((m) => m.pinned || _holdsConsumedHistory(m))
              .toList()
          : meals;
      final result = const PlannerService().repair(planner, existing);
      if (!build.mounted) return;
      if (result.status == PlannerStatus.validPlan) {
        var commitInputs = settings;
        if (legacyInputs &&
            settings.constraintRevision <= appliedSettings.constraintRevision) {
          commitInputs = settings.withRevision(_nextRevision);
        }
        await _persistPlan(result.meals,
            inputs: commitInputs,
            applyInputs: true,
            conditionInput: currentConditions);
        final firstSlot = _slots(commitInputs).firstOrNull;
        if (firstSlot != null) {
          await store.reward('planning:${firstSlot.date}');
        }
        if (!build.mounted) return;
        setState(() {
          status = tr(
              build,
              'Organization-only plan. No nutritional adequacy claim.',
              'Plano apenas de organização. Sem afirmações de adequação nutricional.');
        });
      } else {
        setState(() {
          conditionInput = currentConditions;
          conditionAssessment = assessment;
          conditionReport = null;
          conditionInputStale =
              !_conditionInputCurrent(appliedConditionInput, currentConditions);
          pendingContext = planner;
          pendingExisting = existing;
          pendingStatus = result.status;
          diagnostics = result.diagnostics;
          relaxations = result.status == PlannerStatus.proposedRelaxation
              ? result.relaxations
              : const [];
          status = _statusLine(build, result);
        });
      }
    } catch (e) {
      if (!build.mounted) return;
      _showPlanFailure(build, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _statusLine(BuildContext c, PlannerResult result) {
    final detail =
        result.diagnostics.map((code) => _diagnosticLabel(c, code)).join('; ');
    final suffix = detail.isEmpty ? '' : ' $detail';
    return switch (result.status) {
      PlannerStatus.proposedRelaxation =>
        tr(c, 'No plan was installed. Review one adjustment below; nothing was relaxed automatically.',
            'Nenhum plano foi instalado. Revê um ajuste abaixo; nada foi relaxado automaticamente.'),
      PlannerStatus.targetConflict => tr(
          c,
          'A hard constraint conflicts with the plan. Nothing was written.',
          'Uma restrição rígida entra em conflito com o plano. Nada foi escrito.') +
          suffix,
      PlannerStatus.insufficientData => tr(
          c,
          'A binding nutrient check lacks data. Missing nutrient data was not treated as zero.',
          'Uma verificação nutricional obrigatória não tem dados. Os dados em falta não foram tratados como zero.') +
          suffix,
      PlannerStatus.searchExhausted => tr(
          c,
          'The bounded search ended without a valid plan under the current constraints.',
          'A pesquisa limitada terminou sem um plano válido com as restrições atuais.') +
          suffix,
      PlannerStatus.provenInfeasible => tr(
          c,
          'No combination in the declared recipe and portion space satisfies the hard constraints.',
          'Nenhuma combinação no espaço declarado de receitas e porções satisfaz as restrições rígidas.') +
          suffix,
      PlannerStatus.validPlan => tr(c, 'Plan installed.', 'Plano instalado.')
    };
  }

  String _diagnosticLabel(BuildContext c, String code) => switch (code) {
        'EXCLUSION_CONFLICT' => tr(
            c,
            'A meal conflicts with a strict exclusion.',
            'Uma refeição entra em conflito com uma exclusão rígida.'),
        'ALLERGEN_STATUS_UNKNOWN' => tr(
            c,
            'An ingredient has unknown allergen status, which cannot establish suitability.',
            'Um ingrediente tem estado de alergénios desconhecido, o que não permite estabelecer adequação.'),
        'DIET_CONFLICT' => tr(
            c, 'A meal conflicts with a declared diet restriction.',
            'Uma refeição entra em conflito com uma restrição alimentar declarada.'),
        'INGREDIENT_UNRESOLVED' =>
          tr(c, 'A recipe ingredient is unresolved.',
              'Um ingrediente da receita não está resolvido.'),
        'INGREDIENT_STALE' =>
          tr(c, 'A recipe ingredient snapshot is stale.',
              'A cópia de um ingrediente da receita está desatualizada.'),
        'INGREDIENT_UNAVAILABLE' =>
          tr(c, 'A recipe ingredient is marked unavailable.',
              'Um ingrediente da receita está marcado como indisponível.'),
        'INSUFFICIENT_NUTRIENT_DATA' => tr(
            c,
            'A nutrient needed for the binding range is missing.',
            'Falta um nutriente necessário para o intervalo obrigatório.'),
        'NUMERIC_CONSTRAINT' => tr(
            c, 'The daily binding nutrient range is not met.',
            'O intervalo nutricional diário obrigatório não é cumprido.'),
        'UNRESOLVED_SLOTS' => tr(c, 'Some schedule days have no meal.',
            'Alguns dias do horário não têm refeição.'),
        'SLOT_MISMATCH' =>
          tr(c, 'A meal is outside the current schedule.',
              'Uma refeição está fora do horário atual.'),
        'RECIPE_REVISION_MISMATCH' => tr(
            c, 'A meal recipe revision is no longer current.',
            'A revisão de uma receita já não está atual.'),
        'PORTION_BOUNDS' => tr(
            c, 'A meal portion is outside the chosen portion options.',
            'Uma porção está fora das opções de porção escolhidas.'),
        'COOKING_TIME' => tr(c, 'A meal exceeds the cooking-time limit.',
            'Uma refeição excede o limite de tempo de confeção.'),
        'REPETITION_LIMIT' => tr(
            c, 'A recipe repeats more often than the limit.',
            'Uma receita repete mais do que o limite.'),
        'BATCH_STOCK_EXCEEDED' => tr(
            c, 'Reservations exceed measured cooked stock.',
            'As reservas excedem o stock confecionado medido.'),
        'BATCH_REVISION_MISMATCH' =>
          tr(c, 'A reservation refers to a stale batch revision.',
              'Uma reserva refere uma revisão de lote desatualizada.'),
        'BATCH_ALLOCATION_MISSING' =>
          tr(c, 'A reservation allocation is missing from its batch.',
              'Falta uma alocação de reserva no lote.'),
        'BATCH_ALLOCATION_MISMATCH' =>
          tr(c, 'A reservation allocation does not match the planned meal.',
              'Uma alocação de reserva não corresponde à refeição planeada.'),
        'DUPLICATE_BATCH_USE' => tr(
            c, 'Two meals use the same stock reservation.',
            'Duas refeições usam a mesma reserva de stock.'),
        'BATCH_RECIPE_MISMATCH' => tr(
            c, 'A reserved batch was cooked from a different recipe version.',
            'Um lote reservado foi confecionado com outra versão da receita.'),
        _ => code
      };

  String _conditionLabel(BuildContext c, PlanningCondition condition) =>
      switch (condition) {
        PlanningCondition.highTriglycerides =>
          tr(c, 'High triglycerides', 'Triglicéridos elevados'),
        PlanningCondition.diabetes => tr(c, 'Diabetes', 'Diabetes'),
        PlanningCondition.highCholesterol =>
          tr(c, 'High cholesterol', 'Colesterol elevado'),
        PlanningCondition.lowBloodGlucoseHistoryOrRisk => tr(
            c,
            'History or risk of low blood glucose',
            'Histórico ou risco de glicemia baixa'),
        PlanningCondition.highBloodPressure =>
          tr(c, 'High blood pressure', 'Tensão arterial elevada'),
        PlanningCondition.chronicKidneyDisease =>
          tr(c, 'Chronic kidney disease', 'Doença renal crónica'),
        PlanningCondition.eatingDisorderConcerns =>
          tr(c, 'Eating-disorder concerns', 'Preocupações com perturbações alimentares'),
        PlanningCondition.lactoseIntolerance =>
          tr(c, 'Lactose intolerance', 'Intolerância à lactose'),
        PlanningCondition.gout => tr(c, 'Gout', 'Gota'),
        PlanningCondition.irritableBowelSyndrome =>
          tr(c, 'Irritable bowel syndrome', 'Síndrome do intestino irritável'),
        PlanningCondition.foodAllergy =>
          tr(c, 'Food allergy', 'Alergia alimentar'),
        PlanningCondition.coeliacDisease =>
          tr(c, 'Coeliac disease', 'Doença celíaca'),
      };

  String _guidanceExplanationLabel(BuildContext c, String code) =>
      switch (code) {
        'EATING_DISORDER_CONFLICT_RESTRICTIVE_GUIDANCE' => tr(
            c,
            'Restrictive condition guidance was withheld because an eating-disorder concern is declared.',
            'O aconselhamento restritivo por condição foi retido porque existem preocupações com perturbações alimentares.'),
        'SAFETY_EATING_CONCERN_CONFLICT_RESTRICTIVE_GUIDANCE' => tr(
            c,
            'Restrictive condition guidance was withheld because a safety-profile eating concern is recorded.',
            'O aconselhamento restritivo por condição foi retido porque está registada uma preocupação alimentar no perfil de segurança.'),
        'CHOLESTEROL_LOWER_SATURATED_FAT' => tr(
            c,
            'Prefer lower saturated fat when values are known; total fat is not saturated fat.',
            'Preferir menor gordura saturada quando os valores são conhecidos; a gordura total não é gordura saturada.'),
        'HYPOGLYCAEMIA_CONFLICT_SUGAR_RESTRICTION' => tr(
            c,
            'Sugar-lowering guidance was withheld because a history or risk of low blood glucose is declared.',
            'O aconselhamento para reduzir açúcar foi retido porque existe histórico ou risco de glicemia baixa.'),
        'TRIGLYCERIDES_LOWER_FREE_SUGARS' => tr(
            c,
            'Prefer lower free/added sugars when the source provides them; total sugars are not added sugars.',
            'Preferir menos açúcares livres/adicionados quando a fonte os fornece; os açúcares totais não são açúcares adicionados.'),
        'TRIGLYCERIDES_LOWER_SATURATED_FAT' => tr(
            c,
            'Prefer lower saturated fat; this does not exclude all carbohydrate or fat.',
            'Preferir menor gordura saturada; isto não exclui todos os hidratos de carbono nem toda a gordura.'),
        'DIABETES_SHOW_CARBOHYDRATE' => tr(
            c,
            'Known carbohydrate is shown; no universal carbohydrate target is imposed and whole fruit is not banned.',
            'Os hidratos de carbono conhecidos são mostrados; não é imposta uma meta universal e a fruta inteira não é proibida.'),
        'DIABETES_LOWER_FREE_SUGARS' => tr(
            c,
            'Prefer lower free/added sugars when known; total sugars are not added sugars.',
            'Preferir menos açúcares livres/adicionados quando conhecidos; os açúcares totais não são açúcares adicionados.'),
        'DIABETES_HIGHER_FIBER' => tr(
            c,
            'Prefer fibre-containing choices when fibre is known.',
            'Preferir opções com fibra quando a fibra é conhecida.'),
        'HYPOGLYCAEMIA_NO_BLANKET_RESTRICTION' => tr(
            c,
            'No fasting, skipped meals or blanket sugar avoidance is recommended; timing may depend on treatment.',
            'Não é recomendado jejum, saltar refeições ou evitar açúcar de forma genérica; o horário pode depender do tratamento.'),
        'BLOOD_PRESSURE_KIDNEY_CONFLICT' => tr(
            c,
            'Sodium guidance was withheld because chronic kidney disease is declared; no potassium substitute is recommended.',
            'O aconselhamento sobre sódio foi retido porque foi declarada doença renal crónica; não é recomendado substituto de potássio.'),
        'BLOOD_PRESSURE_LOWER_SODIUM' => tr(
            c,
            'Prefer lower-sodium alternatives when comparable and known. No potassium salt substitute is recommended.',
            'Preferir alternativas com menos sódio quando comparáveis e conhecidas. Não é recomendado substituto de potássio.'),
        'KIDNEY_NO_INFERRED_LIMITS' => tr(
            c,
            'No protein, potassium, phosphorus, sodium or fluid limit is inferred for kidney disease; qualified advice is required.',
            'Não é inferido qualquer limite de proteína, potássio, fósforo, sódio ou líquidos para doença renal; é necessário aconselhamento qualificado.'),
        'EATING_DISORDER_SUPPORTIVE_ONLY' => tr(
            c,
            'Supportive, non-punitive presentation only; no automatic restriction or weight-loss coaching.',
            'Apenas apresentação de apoio e não punitiva; sem restrição automática ou aconselhamento para perda de peso.'),
        'SAFETY_EATING_CONCERN_SUPPORTIVE_ONLY' => tr(
            c,
            'A safety-profile eating concern is recorded: no restrictive condition guidance or calorie-pressure prompts are applied.',
            'Está registada uma preocupação alimentar no perfil de segurança: não é aplicado aconselhamento restritivo por condição nem pressão calórica.'),
        'LACTOSE_NO_AUTOMATIC_EXCLUSION' => tr(
            c,
            'No automatic dairy exclusion; lactose is not modeled and lactose intolerance is not milk allergy.',
            'Sem exclusão automática de laticínios; a lactose não está modelada e a intolerância à lactose não é alergia ao leite.'),
        'LACTOSE_EXCLUSIONS_ENFORCED' => tr(
            c,
            'Your explicit exclusions are enforced; lactose content is not modeled.',
            'As tuas exclusões explícitas são aplicadas; o teor de lactose não está modelado.'),
        'GOUT_NO_PURINE_DATA' => tr(
            c,
            'Purine data and a reviewed beverage classification are unavailable; no protein ban is applied.',
            'Não há dados de purinas nem classificação de bebidas revista; não é aplicada proibição de proteína.'),
        'IBS_NO_UNIVERSAL_TRIGGERS' => tr(
            c,
            'No universal trigger list; no automatic restrictive diet is prescribed.',
            'Não existe lista universal de gatilhos; não é prescrita uma dieta restritiva automática.'),
        'IBS_EXCLUSIONS_ENFORCED' => tr(
            c,
            'Your explicit trigger exclusions are enforced; no universal list is assumed.',
            'As tuas exclusões explícitas de gatilhos são aplicadas; não é assumida uma lista universal.'),
        'ALLERGY_REQUIRES_EXPLICIT_EXCLUSION' => tr(
            c,
            'A declared allergy needs a specific allergen exclusion; none was inferred and this plan is not assessed for it.',
            'Uma alergia declarada exige uma exclusão específica do alergénio; nenhuma foi inferida e este plano não está avaliado para ela.'),
        'ALLERGY_COVERAGE_UNASSESSED' => tr(
            c,
            'Declared exclusions are enforced, but the declaration does not identify the allergen, so coverage is unassessed; no safety is guaranteed.',
            'As exclusões declaradas são aplicadas, mas a declaração não identifica o alergénio, por isso a cobertura não está avaliada; não há garantia de segurança.'),
        'COELIAC_REQUIRES_GLUTEN_EXCLUSION' => tr(
            c,
            'A coeliac declaration needs an explicit gluten/wheat/barley/rye exclusion; none was inferred.',
            'Uma declaração de doença celíaca exige uma exclusão explícita de glúten/trigo/cevada/centeio; nenhuma foi inferida.'),
        'COELIAC_EXCLUSIONS_ENFORCED' => tr(
            c,
            'An explicit gluten-related exclusion is enforced; cross-contact and hidden sources are not certified.',
            'Uma exclusão explícita relacionada com glúten é aplicada; contacto cruzado e fontes ocultas não são certificados.'),
        'CONDITION_GUIDANCE_WITHHELD_CONFLICT' => tr(
            c,
            'Guidance for this condition was withheld because declared conditions conflict; no compromise was invented.',
            'O aconselhamento para esta condição foi retido porque as condições declaradas entram em conflito; não foi inventado qualquer compromisso.'),
        'UNRECOGNIZED_CONDITION_DECLARED' => tr(
            c,
            'A declared condition is not understood by this build and was not treated as absent.',
            'Uma condição declarada não é reconhecida por esta versão e não foi tratada como ausente.'),
        'CONDITION_NUTRIENT_DATA_INSUFFICIENT' => tr(
            c,
            'No selected meal has usable data for this rule; missing is not zero and no tailored recommendation is stated.',
            'Nenhuma refeição selecionada tem dados utilizáveis para esta regra; o que falta não é zero e não é apresentada recomendação adaptada.'),
        'CONDITION_NUTRIENT_DATA_PARTIAL' => tr(
            c,
            'Some selected meals lack usable data for this rule; unknown was not treated as zero or as healthier.',
            'Algumas refeições selecionadas não têm dados utilizáveis para esta regra; o desconhecido não foi tratado como zero nem como mais saudável.'),
        _ => code,
      };

  String _guidanceEvidenceLabel(
          BuildContext c, ConditionGuidanceDirectiveEvidence item) {
    final nutrient = nutrientLabel(c, item.directive.nutrient.wire);
    final direction = item.directive.direction == GuidanceDirection.lower
        ? tr(c, 'lower', 'menor')
        : tr(c, 'higher', 'maior');
    if (item.knownMeals == 0) {
      return tr(
          c,
          '$nutrient ($direction): no usable data in the selected meals; no tailored recommendation.',
          '$nutrient ($direction): sem dados utilizáveis nas refeições selecionadas; sem recomendação adaptada.');
    }
    if (item.unknownMeals > 0) {
      return tr(
          c,
          '$nutrient ($direction): known in ${item.knownMeals}/${item.mealCount} meals; missing data is not zero.',
          '$nutrient ($direction): conhecido em ${item.knownMeals}/${item.mealCount} refeições; os dados em falta não são zero.');
    }
    return tr(
        c,
        '$nutrient ($direction): known in all ${item.mealCount} selected meals.',
        '$nutrient ($direction): conhecido em todas as ${item.mealCount} refeições selecionadas.');
  }

  Widget _conditionGuidanceCard(BuildContext c) {
    final input = conditionInput;
    final assessment = conditionAssessment;
    final report = conditionReport;
    final declared = input?.declared ?? const <PlanningCondition>{};
    final unrecognized =
        input?.unrecognizedDeclared ?? const <String>{};
    final hasDeclared = declared.isNotEmpty || unrecognized.isNotEmpty;
    final reportHasContent = report != null &&
        (report.evidence.isNotEmpty || report.explanations.isNotEmpty);
    final safetyNotice =
        assessment != null && assessment.explanations.isNotEmpty;
    if (!hasDeclared && !conditionInputStale && !reportHasContent &&
        !safetyNotice) {
      return const SizedBox.shrink();
    }
    final explanations = report?.explanations ??
        assessment?.explanations ??
        const <ConditionGuidanceExplanation>[];
    final evidence = report?.evidence ??
        const <ConditionGuidanceDirectiveEvidence>[];
    final untailored = report?.untailoredConditions ??
        assessment?.untailoredConditions ??
        const <PlanningCondition>{};
    final sources = <ConditionGuidanceSource>[];
    for (final explanation in explanations) {
      for (final source in explanation.sources) {
        if (!sources.contains(source)) sources.add(source);
      }
    }
    final abstained = assessment?.abstained ?? false;
    final requiresInput =
        assessment?.requiresExplicitExclusion ?? false;
    return Card(
        color: Theme.of(c).colorScheme.surfaceContainerHighest,
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  tr(c, 'Condition-aware meal planning (experimental)',
                      'Planeamento alimentar por condição (experimental)'),
                  style: Theme.of(c).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(tr(
                  c,
                  'Experimental local-testing guidance: not clinically validated, not medical advice or a diagnosis, and no safety guarantee. Individual conditions, treatment and severity may change the appropriate advice.',
                  'Aconselhamento experimental para testes locais: não validado clinicamente, não é aconselhamento médico nem diagnóstico, e não garante segurança. As condições, o tratamento e a gravidade de cada pessoa podem alterar o aconselhamento adequado.')),
              const SizedBox(height: 4),
              Text(
                  '${tr(c, 'Policy', 'Política')}: ${ConditionGuidancePolicy.version} · ${tr(c, 'scope', 'âmbito')}: ${ConditionGuidancePolicy.scope}',
                  style: Theme.of(c).textTheme.bodySmall),
              if (conditionInputStale) ...[
                const SizedBox(height: 8),
                Text(tr(
                    c,
                    'Declared conditions changed after this plan was generated. Repair the plan before trusting these meals as condition-aware; saving is blocked until then.',
                    'As condições declaradas mudaram depois de este plano ter sido gerado. Repara o plano antes de confiar nestas refeições como adaptadas à condição; guardar está bloqueado até lá.')),
              ],
              if (hasDeclared) ...[
                const SizedBox(height: 8),
                Text(
                    '${tr(c, 'Declared', 'Declaradas')}: '
                    '${[
                      for (final condition in PlanningCondition.values)
                        if (declared.contains(condition))
                          _conditionLabel(c, condition),
                      ...unrecognized,
                    ].join(', ')}'),
              ],
              if (requiresInput) ...[
                const SizedBox(height: 8),
                Text(tr(
                    c,
                    'A declared allergy or coeliac condition has no verified matching explicit strict exclusion. No exclusion was inferred. This plan is unassessed for that condition and is not labelled safe; verify the specific allergen/gluten exclusion in safety declarations.',
                    'Uma alergia ou doença celíaca declarada não tem uma exclusão rígida explícita correspondente verificada. Nenhuma exclusão foi inferida. Este plano não está avaliado para essa condição e não é rotulado como seguro; verifica a exclusão específica do alergénio/glúten nas declarações de segurança.')),
              ],
              if (abstained) ...[
                const SizedBox(height: 8),
                Text(tr(
                    c,
                    'Some declared conditions conflict. No condition-based ranking was applied; the plan is generic organization only, not a compromise or a tailored recommendation.',
                    'Algumas condições declaradas entram em conflito. Não foi aplicada qualquer ordenação por condição; o plano é apenas organização genérica, não um compromisso nem uma recomendação adaptada.')),
              ],
              if (report != null && evidence.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(tr(c, 'Relative preference data in this plan (soft, experimental):',
                    'Dados de preferência relativa neste plano (suaves, experimentais):')),
                for (final item in evidence)
                  Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('• ${_guidanceEvidenceLabel(c, item)}',
                          style: Theme.of(c).textTheme.bodySmall)),
              ],
              if (hasDeclared &&
                  !abstained &&
                  !requiresInput &&
                  report != null &&
                  !report.hasTailoredGuidance) ...[
                const SizedBox(height: 8),
                Text(tr(
                    c,
                    'No suitable tailored recommendation could be made from the available data. These meals are generic organization only and are not presented as tailored or safe.',
                    'Não foi possível fazer uma recomendação adaptada adequada com os dados disponíveis. Estas refeições são apenas organização genérica e não são apresentadas como adaptadas ou seguras.')),
              ],
              if (untailored.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                    '${tr(c, 'No tailored recommendation for', 'Sem recomendação adaptada para')}: '
                    '${(untailored.map((condition) => _conditionLabel(c, condition)).toList()..sort()).join(', ')}',
                    style: Theme.of(c).textTheme.bodySmall),
              ],
              for (final explanation in explanations)
                Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        '• ${_guidanceExplanationLabel(c, explanation.code)}',
                        style: Theme.of(c).textTheme.bodySmall)),
              if (sources.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                    tr(c,
                        'Sources (checked 2026-11-11; not a clinical endorsement)',
                        'Fontes (verificadas em 2026-11-11; não é uma validação clínica)'),
                    style: Theme.of(c).textTheme.bodySmall),
                for (final source in sources)
                  Text('• ${source.label}: ${source.url}',
                      style: Theme.of(c).textTheme.bodySmall),
              ],
            ])));
  }

  String _relaxationLabel(BuildContext c, PlannerRelaxation change) =>
      switch (change.kind) {
        PlannerRelaxationKind.maximumMinutes => change.maximumMinutes == null
            ? tr(c, 'Remove the cooking-time limit',
                'Remover o limite de tempo de confeção')
            : tr(c, 'Allow recipes up to ${change.maximumMinutes} minutes',
                'Permitir receitas até ${change.maximumMinutes} minutos'),
        PlannerRelaxationKind.maximumRepeats => change.maximumRepeats == null
            ? tr(c, 'Remove the repetition limit',
                'Remover o limite de repetições')
            : tr(c, 'Allow a recipe up to ${change.maximumRepeats} times',
                'Permitir uma receita até ${change.maximumRepeats} vezes'),
        PlannerRelaxationKind.portions =>
          change.portions == null || change.portions!.isEmpty
              ? tr(c, 'Remove the portion options',
                  'Remover as opções de porção')
              : '${tr(c, 'Allow these portion options', 'Permitir estas opções de porção')}: ${change.portions!.map(_exactLabel).join(', ')}',
        PlannerRelaxationKind.numericConstraint => change.constraint == null
            ? tr(c, 'Remove the binding nutrient range',
                'Remover o intervalo nutricional obrigatório')
            : '${tr(c, 'Change the binding range', 'Alterar o intervalo obrigatório')} (${nutrientLabel(c, (change.constraintNutrient ?? NutrientKey.energyKcal).wire)}): ${_exactLabel(change.constraint!.minimum)}–${_exactLabel(change.constraint!.maximum)}',
        PlannerRelaxationKind.pin => tr(
            c,
            'Unpin ${change.slotId ?? 'the conflicting meal'} so repair can replace it',
            'Desafixar ${change.slotId ?? 'a refeição em conflito'} para permitir a reparação'),
      };

  String _reasonLabel(BuildContext c, String reason) => switch (reason) {
        'NO_RECIPE_WITHIN_TIME' =>
          tr(c, 'No eligible recipe fits the cooking-time limit.',
              'Nenhuma receita elegível cabe no limite de tempo.'),
        'REPEAT_LIMIT_BLOCKS_SLOTS' =>
          tr(c, 'The repetition limit prevents filling every slot.',
              'O limite de repetições impede preencher todos os espaços.'),
        'NUMERIC_RANGE_UNSATISFIED' =>
          tr(c, 'The binding nutrient range cannot be met with complete data.',
              'O intervalo nutricional obrigatório não é atingível com dados completos.'),
        'PIN_TIME_CONFLICT' =>
          tr(c, 'A pinned meal exceeds the cooking-time limit.',
              'Uma refeição fixada excede o limite de tempo.'),
        'PIN_PORTION_OUTSIDE_OPTIONS' =>
          tr(c, 'A pinned meal uses a portion outside the selected options.',
              'Uma refeição fixada usa uma porção fora das opções escolhidas.'),
        'PIN_NUMERIC_CONFLICT' =>
          tr(c, 'A pinned meal conflicts with the binding nutrient range.',
              'Uma refeição fixada entra em conflito com o intervalo nutricional obrigatório.'),
        'PIN_REPEAT_CONFLICT' =>
          tr(c, 'A pinned meal conflicts with the repetition limit.',
              'Uma refeição fixada entra em conflito com o limite de repetições.'),
        'PIN_LIMITS_SEARCH' =>
          tr(c, 'The pins leave too few feasible combinations for the bounded search.',
              'As fixações deixam poucas combinações viáveis para a pesquisa limitada.'),
        'PIN_CONFLICT' =>
          tr(c, 'A pinned meal no longer fits the current constraints.',
              'Uma refeição fixada já não cumpre as restrições atuais.'),
        _ => reason
      };

  Future<void> _accept(BuildContext c, PlannerRelaxation change) async {
    final planner = pendingContext;
    if (planner == null || busy) return;
    final confirmed = await confirmAction(
        c,
        tr(c, 'Apply this reviewed change?',
            'Aplicar esta alteração revista?'),
        '${_relaxationLabel(c, change)}\n\n${tr(c, 'This creates a visible constraint revision and re-runs the bounded search. Strict exclusions, diet restrictions, unknown allergen status and unavailable ingredients are never changed. The plan stays separate from intake.', 'Isto cria uma revisão visível das restrições e volta a executar a pesquisa limitada. As exclusões rígidas, as restrições alimentares, o estado desconhecido de alergénios e os ingredientes indisponíveis nunca são alterados. O plano continua separado do consumo.')}');
    if (!confirmed || !mounted) return;
    setState(() => busy = true);
    try {
      final acceptance = const PlannerService().acceptRelaxation(
          planner, change,
          confirmed: true,
          expectedRevision: planner.revision,
          existing: pendingExisting);
      final accepted = settings.accepted(change,
          revision: acceptance.context.revision,
          acceptedAt: ref.read(clockProvider).nowUtc().toIso8601String());
      List<PlannedMeal> next;
      if (acceptance.result.status == PlannerStatus.validPlan) {
        next = acceptance.result.meals;
      } else if (change.kind == PlannerRelaxationKind.pin &&
          change.slotId != null) {
        next = [
          for (final m in meals)
            m.slot.id == change.slotId
                ? PlannedMeal(m.slot, m.recipe, m.portions,
                    pinned: false, batchUse: m.batchUse)
                : m
        ];
      } else {
        next = meals;
      }
      // The fallback saves existing meals; record the declarations they were
      // actually generated under. If declarations changed since, the save is
      // rejected as stale and the user must repair instead.
      await _persistPlan(next,
          inputs: accepted,
          applyInputs: true,
          conditionInput: planner.conditionGuidance?.input);
      if (!c.mounted) return;
      if (acceptance.result.status == PlannerStatus.validPlan) {
        final firstSlot = _slots(accepted).firstOrNull;
        if (firstSlot != null) {
          await store.reward('planning:${firstSlot.date}');
        }
        if (!c.mounted) return;
        setState(() {
          pendingContext = acceptance.context;
          pendingStatus = null;
          relaxations = [];
          diagnostics = [];
          status = tr(
              c,
              'Reviewed constraint revision ${accepted.constraintRevision}. Organization-only plan; no nutritional adequacy claim.',
              'Revisão de restrições revista ${accepted.constraintRevision}. Plano apenas de organização; sem afirmações de adequação nutricional.');
        });
      } else {
        setState(() {
          pendingContext = acceptance.context;
          pendingStatus = acceptance.result.status;
          diagnostics = acceptance.result.diagnostics;
          relaxations = acceptance.result.relaxations;
          status = _statusLine(c, acceptance.result);
        });
      }
    } catch (e) {
      if (!c.mounted) return;
      _showPlanFailure(c, e);
      await _load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _mealAction(
      BuildContext c, PlannedMeal meal, String action) async {
    if (action == 'edit') return _editMeal(c, meal);
    if (action == 'reserve') return _reserve(c, meal);
    if (action == 'release') return _release(c, meal);
    if (action == 'remove') return _removeMeal(c, meal);
  }

  Future<void> _editMeal(BuildContext c, PlannedMeal meal) async {
    if (settingsDraftInvalid) {
      showFailure(c, StateError(_invalidDraftMessage(c)));
      return;
    }
    await _reloadBatches();
    if (!c.mounted) return;
    final eligible = [
      for (final r in recipes)
        if (r.eligible(strictExclusions, const {},
                unavailableFoodIds: appliedSettings.unavailableFoodIds.toSet()) &&
            (appliedSettings.maximumMinutes == null ||
                r.minutes <= appliedSettings.maximumMinutes!))
          r
    ];
    if (!eligible.any(
        (r) => r.id == meal.recipe.id && r.revision == meal.recipe.revision)) {
      eligible.add(meal.recipe);
    }
    final edit = await showDialog<_MealEdit>(
        context: c,
        builder: (_) => _MealEditDialog(
            meal: meal,
            recipes: eligible,
            portions: appliedSettings.portions));
    if (edit == null || !c.mounted) return;
    var use = meal.batchUse;
    if (use != null) {
      if (edit.recipe != meal.recipe) {
        // A changed recipe releases the old planned allocation; no automatic
        // reservation is invented for the replacement.
        use = null;
      } else if (edit.portions != meal.portions) {
        final batch = _batchById(use.batchId);
        if (batch == null) {
          showFailure(c,
              StateError(tr(c, 'The reserved batch is no longer available.',
                  'O lote reservado já não está disponível.')));
          return;
        }
        // A changed amount needs a new allocation id so the transaction can
        // release the old hold and reserve the new amount in one step. The
        // revision is the one shown before the reviewed edit; if the batch has
        // advanced, the save fails closed instead of re-pointing silently.
        use = PlannedBatchUse(
            use.batchId, batch.revision, ref.read(idGeneratorProvider).next());
      }
    }
    try {
      await _persistPlan([
        for (final m in meals)
          m.slot.id == meal.slot.id
              ? PlannedMeal(m.slot, edit.recipe, edit.portions,
                  pinned: m.pinned, batchUse: use)
              : m
      ]);
      if (!c.mounted) return;
      setState(() => status = tr(
          c,
          'Meal updated. Reserved stock is kept or released as reviewed; repair the plan to recheck every hard constraint.',
          'Refeição atualizada. O stock reservado é mantido ou libertado conforme revisto; repara o plano para reverificar todas as restrições rígidas.'));
    } catch (e) {
      if (!c.mounted) return;
      _showPlanFailure(c, e);
      await _load();
    }
  }

  Future<void> _reserve(BuildContext c, PlannedMeal meal) async {
    if (meal.batchUse != null) return;
    await _reloadBatches();
    if (!c.mounted) return;
    final candidates = [
      for (final b in batches)
        if (b.recipe == meal.recipe &&
            b.remaining.compareTo(b.amountForPortions(meal.portions)) >= 0)
          b
    ];
    if (candidates.isEmpty) {
      showFailure(
          c,
          StateError(tr(
              c,
              'No cooked batch of this recipe has enough unreserved stock. Record a measured gram batch or an equal-serving batch first.',
              'Nenhum lote confecionado desta receita tem stock não reservado suficiente. Registra primeiro um lote de gramas medidas ou de porções iguais.')));
      return;
    }
    final chosen = await showDialog<BatchStockView>(
        context: c,
        builder: (_) => _BatchPickerDialog(
            batches: candidates, meal: meal));
    if (chosen == null || !c.mounted) return;
    final amount = chosen.amountForPortions(meal.portions);
    final label = batchAmountLabel(c, chosen.unit, amount);
    final detail = chosen.unit == FoodUnit.serving
        ? tr(
            c,
            'Reserve $label from this batch for ${meal.slot.date} ${meal.slot.label}? No gram equivalent is available because no finished weight was measured. Stock is held for the plan and is not recorded as intake. It can be released until it is consumed.',
            'Reservar $label deste lote para ${meal.slot.date} ${meal.slot.label}? Não existe equivalente em gramas porque não foi medido qualquer peso final. O stock fica retido para o plano e não é registado como consumo. Pode ser libertado até ser consumido.')
        : tr(
            c,
            'Reserve $label from this batch for ${meal.slot.date} ${meal.slot.label}? Stock is held for the plan and is not recorded as intake. It can be released until it is consumed.',
            'Reservar $label deste lote para ${meal.slot.date} ${meal.slot.label}? O stock fica retido para o plano e não é registado como consumo. Pode ser libertado até ser consumido.');
    if (!await confirmAction(
        c,
        tr(c, 'Reserve cooked stock?', 'Reservar stock confecionado?'),
        detail)) {
      return;
    }
    final use = PlannedBatchUse(chosen.document.id, chosen.revision,
        ref.read(idGeneratorProvider).next());
    try {
      await _persistPlan([
        for (final m in meals)
          m.slot.id == meal.slot.id
              ? PlannedMeal(m.slot, m.recipe, m.portions,
                  pinned: m.pinned, batchUse: use)
              : m
      ]);
      if (!c.mounted) return;
      setState(() => status = tr(
          c,
          'Reserved $label from cooked stock. No intake was recorded.',
          'Reservado $label de stock confecionado. Nenhum consumo foi registado.'));
    } catch (e) {
      if (!c.mounted) return;
      _showPlanFailure(c, e);
      await _load();
    }
  }

  Future<void> _release(BuildContext c, PlannedMeal meal) async {
    final use = meal.batchUse;
    if (use == null) return;
    final batch = _batchById(use.batchId);
    final allocation = batch?.allocations
        .where((a) => a.id == use.allocationId)
        .firstOrNull;
    if (allocation != null && allocation.status != 'planned') {
      showFailure(
          c,
          StateError(tr(
              c,
              'This reservation was already consumed. Consumed stock is never released; remove the meal instead.',
              'Esta reserva já foi consumida. O stock consumido nunca é libertado; remove antes a refeição.')));
      return;
    }
    if (!await confirmAction(
        c,
        tr(c, 'Release reserved stock?', 'Libertar stock reservado?'),
        tr(
            c,
            'The reserved stock becomes available to other meals. Nothing is recorded as consumed.',
            'O stock reservado fica disponível para outras refeições. Nada é registado como consumo.'))) {
      return;
    }
    try {
      await _persistPlan([
        for (final m in meals)
          m.slot.id == meal.slot.id
              ? PlannedMeal(m.slot, m.recipe, m.portions,
                  pinned: m.pinned, batchUse: null)
              : m
      ]);
      if (!c.mounted) return;
      setState(() => status = tr(
          c,
          'Reservation released. The stock is available again and no intake was recorded.',
          'Reserva libertada. O stock está novamente disponível e nenhum consumo foi registado.'));
    } catch (e) {
      if (!c.mounted) return;
      _showPlanFailure(c, e);
      await _load();
    }
  }

  Future<void> _removeMeal(BuildContext c, PlannedMeal meal) async {
    if (settings.constraintRevision > appliedSettings.constraintRevision) {
      showFailure(
          c,
          StateError(tr(
              c,
              'Apply the saved constraint revision with Repair before removing meals.',
              'Aplica a revisão de restrições guardada com Reparar antes de remover refeições.')));
      return;
    }
    // Read the current stock state before deciding whether this meal holds
    // consumed history; a stale screen must never remove a consumed record.
    await _reloadBatches();
    if (!c.mounted) return;
    if (_holdsConsumedHistory(meal)) {
      showFailure(
          c,
          StateError(tr(
              c,
              'This meal holds consumed stock history. It stays in the plan so the record is not lost.',
              'Esta refeição contém histórico de stock consumido. Permanece no plano para não perder o registo.')));
      return;
    }
    final appliedSlots = _slots(appliedSettings);
    // Only an id and date that still name a generated slot becomes an
    // exclusion. A meal saved under an older schedule is removed on its own so
    // it can never hide the newly scheduled day that reuses its id.
    final scheduled = appliedSlots
        .where((slot) =>
            slot.id == meal.slot.id && slot.date == meal.slot.date)
        .firstOrNull;
    final remaining = [
      for (final m in meals)
        if (m.slot.id != meal.slot.id) m
    ];
    final excluded = [...appliedSettings.excludedSlotIds];
    if (scheduled != null && !excluded.contains(scheduled.id)) {
      excluded.add(scheduled.id);
    }
    final empty = remaining.isEmpty &&
        (scheduled == null ? appliedSlots.isEmpty : appliedSlots.length == 1);
    final pinnedNote = meal.pinned
        ? tr(c, ' This pinned meal will be removed from the plan.',
            ' Esta refeição fixada será removida do plano.')
        : '';
    final detail = scheduled == null
        ? tr(
            c,
            'This meal is outside the current schedule and will be removed. No other meal, pin, date or portion moves. Any unconsumed reservation for this meal is released; diary intake and consumed stock are unchanged.$pinnedNote',
            'Esta refeição está fora do horário atual e será removida. Nenhuma outra refeição, fixação, data ou porção se move. Qualquer reserva não consumida desta refeição é libertada; o diário e o stock consumido não são alterados.$pinnedNote')
        : empty
            ? tr(
                c,
                '${scheduled.date} will be excluded and this is the last active day, so the plan will have no meals until a day is restored. No other meal, pin, date or portion moves. Any unconsumed reservation for this meal is released; diary intake and consumed stock are unchanged.$pinnedNote',
                '${scheduled.date} será excluído e este é o último dia ativo, por isso o plano ficará sem refeições até restaurar um dia. Nenhuma outra refeição, fixação, data ou porção se move. Qualquer reserva não consumida desta refeição é libertada; o diário e o stock consumido não são alterados.$pinnedNote')
            : tr(
                c,
                '${scheduled.date} will be excluded from the schedule. Every retained meal keeps its slot, date, portion and pin. Any unconsumed reservation for this meal is released; diary intake and consumed stock are unchanged.$pinnedNote',
                '${scheduled.date} será excluído do horário. Todas as refeições retidas mantêm o espaço, a data, a porção e a fixação. Qualquer reserva não consumida desta refeição é libertada; o diário e o stock consumido não são alterados.$pinnedNote');
    if (!await confirmAction(
        c,
        tr(c, 'Remove this planned meal?', 'Remover esta refeição planeada?'),
        detail)) {
      return;
    }
    // Re-check after the confirmation so stock consumed while the dialog was
    // open cannot be dropped from the plan.
    await _reloadBatches();
    if (!c.mounted) return;
    if (_holdsConsumedHistory(meal)) {
      showFailure(
          c,
          StateError(tr(
              c,
              'This meal holds consumed stock history. It stays in the plan so the record is not lost.',
              'Esta refeição contém histórico de stock consumido. Permanece no plano para não perder o registo.')));
      return;
    }
    final next = scheduled == null
        ? appliedSettings
        : appliedSettings.withExclusions(excluded, revision: _nextRevision);
    try {
      await _persistPlan(remaining, inputs: next, applyInputs: true);
      if (!c.mounted) return;
      setState(() => status = empty
          ? tr(
              c,
              'Last meal removed. All days are excluded and no meal remains until you restore an excluded day in the schedule. No intake changed.',
              'Última refeição removida. Todos os dias estão excluídos e não resta nenhuma refeição até restaurares um dia excluído no horário. Nenhum consumo foi alterado.')
          : scheduled == null
              ? tr(
                  c,
                  'Meal outside the schedule removed. No retained meal, pin, date or portion moved; no intake changed.',
                  'Refeição fora do horário removida. Nenhuma refeição retida, fixação, data ou porção se moveu; nenhum consumo foi alterado.')
              : tr(
                  c,
                  'Meal removed. ${scheduled.date} is excluded from the schedule; no retained meal, pin, date or portion moved. Any unconsumed reservation for the removed meal was released; intake is unchanged.',
                  'Refeição removida. ${scheduled.date} está excluído do horário; nenhuma refeição retida, fixação, data ou porção se moveu. Qualquer reserva não consumida da refeição removida foi libertada; o consumo não foi alterado.'));
    } catch (e) {
      if (!c.mounted) return;
      _showPlanFailure(c, e);
      await _load();
    }
  }

  Future<void> _consume(BuildContext c, PlannedMeal meal) async {
    if (meal.batchUse != null) return _consumeReserved(c, meal);
    return _logRecipe(c, meal.recipe, meal.portions);
  }

  Future<void> _consumeReserved(BuildContext c, PlannedMeal meal) async {
    final use = meal.batchUse!;
    await _reloadBatches();
    if (!c.mounted) return;
    final batch = _batchById(use.batchId);
    final allocation = batch?.allocations
        .where((a) => a.id == use.allocationId)
        .firstOrNull;
    if (batch == null || allocation == null) {
      showFailure(
          c,
          StateError(tr(
              c,
              'The reserved batch stock can no longer be found. Reload the plan before recording intake.',
              'O stock reservado do lote já não existe. Recarrega o plano antes de registar consumo.')));
      return;
    }
    if (allocation.status != 'planned') {
      showFailure(
          c,
          StateError(tr(
              c,
              'This reservation was already consumed. Stock is used exactly once.',
              'Esta reserva já foi consumida. O stock é usado exatamente uma vez.')));
      return;
    }
    final amount = batch.amountForPortions(meal.portions);
    if (allocation.amount != amount) {
      showFailure(
          c,
          StateError(tr(
              c,
              'The reservation no longer matches the planned portion. Review the meal before recording intake.',
              'A reserva já não corresponde à porção planeada. Revê a refeição antes de registar consumo.')));
      return;
    }
    final label = batchAmountLabel(c, batch.unit, amount);
    final detail = batch.unit == FoodUnit.serving
        ? tr(
            c,
            'Record $label from this cooked batch as consumed for ${meal.slot.date}? No gram equivalent is available because no finished weight was measured. This uses the reserved stock exactly once, never returns it, and does not assess storage safety.',
            'Registar $label deste lote confecionado para consumo em ${meal.slot.date}? Não existe equivalente em gramas porque não foi medido qualquer peso final. Isto usa o stock reservado exatamente uma vez, nunca o devolve e não avalia a segurança de conservação.')
        : tr(
            c,
            'Record $label from this cooked batch as consumed for ${meal.slot.date}? This uses the reserved stock exactly once, never returns it, and does not assess storage safety.',
            'Registar $label deste lote confecionado como consumidos em ${meal.slot.date}? Isto usa o stock reservado exatamente uma vez, nunca o devolve e não avalia a segurança de conservação.');
    if (!await confirmAction(
        c,
        tr(c, 'Record consumed batch portion?',
            'Registar porção consumida do lote?'),
        detail)) {
      return;
    }
    try {
      await BatchService(ref.read(databaseProvider), ref.read(clockProvider),
              ref.read(idGeneratorProvider))
          .consumeAmount(
              requestId: ref.read(idGeneratorProvider).next(),
              batchId: batch.document.id,
              expectedRevision: batch.revision,
              amount: amount,
              unit: batch.unit,
              offsetMinutes: currentOffsetMinutes(),
              confirmed: true,
              reservedAllocationId: use.allocationId);
      ref.invalidate(todayEntriesProvider);
      await _reloadBatches();
      if (!c.mounted) return;
      setState(() => status = tr(
          c,
          'Batch portion recorded in the diary. The consumed allocation stays in the plan once and is never returned to stock.',
          'Porção do lote registada no diário. A alocação consumida permanece no plano uma única vez e nunca regressa ao stock.'));
    } catch (e) {
      if (!c.mounted) return;
      _showPlanFailure(c, e);
      await _load();
    }
  }

  // ---------------------------------------------------------------------------
  // Groceries
  // ---------------------------------------------------------------------------

  Widget _groceriesTab(BuildContext c) {
    final visible = <_GroceryRow>[];
    final removed = <_GroceryRow>[];
    for (final line in groceriesFor(meals)) {
      final key = '${line.foodId}|${line.preparation.name}';
      final item = generatedGroceries[key] ?? const <String, Object?>{};
      final override = item['grams'];
      Exact grams = line.grams;
      if (override is Map) {
        try {
          grams = Exact.fromJson(Map<String, Object?>.from(override));
        } catch (_) {
          grams = line.grams;
        }
      }
      final row = _GroceryRow(
          key,
          item['name'] is String && (item['name']! as String).trim().isNotEmpty
              ? (item['name']! as String).trim()
              : groceryShoppingName(c, line.foodId, line.name),
          grams,
          line.preparation,
          item['checked'] == true);
      if (item['removed'] == true) {
        removed.add(row);
      } else {
        visible.add(row);
      }
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(tr(
          c,
          'Quantities use the ingredient preparation state recorded in each recipe. No raw/cooked conversion is invented. Meals backed by cooked stock are excluded from generated requirements.',
          'As quantidades usam o estado de preparação registado na receita. Não são inventadas conversões entre cru e confecionado. As refeições com stock confecionado ficam fora das necessidades geradas.')),
      const SizedBox(height: 12),
      OutlinedButton.icon(
          onPressed: () => _editManualGrocery(c),
          icon: const Icon(Icons.add),
          label: Text(tr(c, 'Add grocery item', 'Adicionar artigo'))),
      if (visible.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(tr(c, 'From the plan', 'Do plano'),
            style: Theme.of(c).textTheme.titleSmall),
        for (final row in visible) _generatedGroceryTile(c, row)
      ],
      if (manualGroceries.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(tr(c, 'Added by you', 'Adicionados por ti'),
            style: Theme.of(c).textTheme.titleSmall),
        for (final item in manualGroceries.entries)
          ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Checkbox(
                  value: item.value['checked'] == true,
                  onChanged: (value) => _writeManualGrocery(
                      item.key, {...item.value, 'checked': value == true})),
              title: Text(item.value['name'] as String),
              trailing: Wrap(children: [
                IconButton(
                    tooltip: tr(c, 'Edit grocery item', 'Editar artigo'),
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () =>
                        _editManualGrocery(c, item.key, item.value)),
                IconButton(
                    tooltip: tr(c, 'Remove grocery item', 'Remover artigo'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _writeManualGrocery(item.key, null))
              ]))
      ],
      if (removed.isNotEmpty)
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                onPressed: () => _restoreRemoved(removed),
                child: Text(tr(
                    c,
                    'Restore removed grocery items (${removed.length})',
                    'Restaurar artigos removidos (${removed.length})'))))
    ]);
  }

  Widget _generatedGroceryTile(BuildContext c, _GroceryRow row) {
    final item = generatedGroceries[row.key] ?? const <String, Object?>{};
    return CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: row.checked,
        onChanged: (value) =>
            _writeGenerated(row.key, {...item, 'checked': value == true}),
        title: Text(row.name),
        subtitle: Text(
            '${_grams(row.grams)} · ${_preparationLabel(c, row.preparation)}'
            '${groceryPreparationNote(c, row.key.split('|').first) == null ? '' : '\n${groceryPreparationNote(c, row.key.split('|').first)}'}'),
        secondary: PopupMenuButton<String>(
            tooltip: tr(c, 'Grocery item options', 'Opções do artigo'),
            onSelected: (action) => action == 'edit'
                ? _editGenerated(c, row)
                : _removeGenerated(row),
            itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'edit',
                      child:
                          Text(tr(c, 'Edit grocery item', 'Editar artigo'))),
                  PopupMenuItem(
                      value: 'remove',
                      child:
                          Text(tr(c, 'Remove grocery item', 'Remover artigo')))
                ]));
  }

  Future<void> _editGenerated(BuildContext c, _GroceryRow row) async {
    final base = generatedGroceries[row.key] ?? const <String, Object?>{};
    final override = base['grams'];
    Exact? current;
    if (override is Map) {
      try {
        current = Exact.fromJson(Map<String, Object?>.from(override));
      } catch (_) {
        current = null;
      }
    }
    final edit = await showDialog<_GroceryEdit>(
        context: c,
        builder: (_) => _GroceryDialog(
            title: tr(c, 'Grocery item', 'Artigo de compras'),
            initialName: row.name,
            initialGrams: current,
            planGrams: row.grams,
            preparation: row.preparation,
            allowQuantity: true));
    if (edit == null || !mounted) return;
    final next = <String, Object?>{
      'checked': base['checked'] == true,
      if ((base['name'] is String && (base['name']! as String).trim().isNotEmpty) ||
          edit.name.trim() != row.name) 'name': edit.name,
      'removed': false
    };
    if (edit.grams != null) next['grams'] = edit.grams!.toJson();
    await _writeGenerated(row.key, next);
  }

  Future<void> _removeGenerated(_GroceryRow row) async {
    final base = generatedGroceries[row.key] ?? const <String, Object?>{};
    await _writeGenerated(row.key, {...base, 'removed': true});
  }

  Future<void> _restoreRemoved(List<_GroceryRow> rows) async {
    try {
      final old = await store.read('groceries', 'current');
      final next = <String, Object?>{
        for (final e in old?.data.entries ?? <MapEntry<String, Object?>>[])
          e.key: _groceryItem(e.value)
      };
      for (final row in rows) {
        final item = next[row.key];
        if (item is Map) {
          next[row.key] = Map<String, Object?>.from(item)
            ..['removed'] = false;
        } else {
          next[row.key] = {'removed': false};
        }
      }
      await store.put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'groceries',
          id: 'current',
          expectedRevision: old?.revision ?? 0,
          data: next);
      if (!mounted) return;
      setState(() => generatedGroceries = {
            for (final e in next.entries)
              e.key: Map<String, Object?>.from(e.value as Map)
          });
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> _writeGenerated(
      String key, Map<String, Object?> item) async {
    try {
      final old = await store.read('groceries', 'current');
      final next = <String, Object?>{
        for (final e in old?.data.entries ?? <MapEntry<String, Object?>>[])
          e.key: _groceryItem(e.value)
      };
      next[key] = item;
      await store.put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'groceries',
          id: 'current',
          expectedRevision: old?.revision ?? 0,
          data: next);
      if (!mounted) return;
      setState(() => generatedGroceries = {
            for (final e in next.entries)
              e.key: Map<String, Object?>.from(e.value as Map)
          });
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> _editManualGrocery(BuildContext c,
      [String? id, Map<String, Object?>? item]) async {
    final edit = await showDialog<_GroceryEdit>(
        context: c,
        builder: (_) => _GroceryDialog(
            title: tr(c, 'Grocery item', 'Artigo de compras'),
            initialName: item?['name'] as String? ?? ''));
    if (edit == null || !mounted) return;
    await _writeManualGrocery(id ?? ref.read(idGeneratorProvider).next(), {
      'name': edit.name,
      'checked': item?['checked'] == true
    });
  }

  Future<void> _writeManualGrocery(
      String id, Map<String, Object?>? item) async {
    try {
      final old = await store.read('groceries', 'manual');
      final next = <String, Object?>{...?old?.data};
      if (item == null) {
        next.remove(id);
      } else {
        next[id] = item;
      }
      await store.put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'groceries',
          id: 'manual',
          expectedRevision: old?.revision ?? 0,
          data: next);
      if (!mounted) return;
      setState(() => manualGroceries = {
            for (final e in next.entries)
              e.key: Map<String, Object?>.from(e.value as Map)
          });
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }
}

/// Reviewed schedule and hard-constraint editor. Saving is the visible
/// constraint revision; nothing here can change medical exclusions.
class _ScheduleEditor extends StatefulWidget {
  const _ScheduleEditor(
      {required this.initial,
      required this.strictExclusions,
      required this.unavailableFoodChoices,
      required this.recipeChoices});
  final _PlannerSettings initial;
  final Set<String> strictExclusions;

  /// Actual current recipe candidates keyed by stable recipe id. Selecting one
  /// marks a soft preference; it cannot make an ineligible recipe feasible.
  final Map<String, String> recipeChoices;

  /// Actual ingredient foods present in the planner candidates, keyed by
  /// stable food id. This is never a pantry: only what the user checks here
  /// becomes unavailable.
  final Map<String, String> unavailableFoodChoices;
  @override
  State<_ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends State<_ScheduleEditor> {
  late String startDate;
  late final TextEditingController days;
  late final TextEditingController label;
  late final TextEditingController minutes;
  late final TextEditingController repeats;
  late final TextEditingController energyMin;
  late final TextEditingController energyMax;
  late final TextEditingController portionInput;
  late List<Exact> portions;
  late List<String> initialExclusions;
  late List<String> unavailableFoodIds;
  late Set<String> preferredRecipeIds;
  bool restoreExcluded = false;

  @override
  void initState() {
    super.initState();
    startDate = widget.initial.startDate;
    days = TextEditingController(text: '${widget.initial.days}');
    label = TextEditingController(text: widget.initial.label);
    minutes = TextEditingController(
        text: widget.initial.maximumMinutes?.toString() ?? '');
    repeats = TextEditingController(
        text: widget.initial.maximumRepeats?.toString() ?? '');
    energyMin = TextEditingController(
        text: widget.initial.energyMinimum == null
            ? ''
            : _exactLabel(widget.initial.energyMinimum!));
    energyMax = TextEditingController(
        text: widget.initial.energyMaximum == null
            ? ''
            : _exactLabel(widget.initial.energyMaximum!));
    portionInput = TextEditingController();
    portions = [...widget.initial.portions];
    initialExclusions = [...widget.initial.excludedSlotIds];
    unavailableFoodIds = [...widget.initial.unavailableFoodIds];
    preferredRecipeIds = {...widget.initial.preferredRecipeIds};
  }

  @override
  void dispose() {
    days.dispose();
    label.dispose();
    minutes.dispose();
    repeats.dispose();
    energyMin.dispose();
    energyMax.dispose();
    portionInput.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final current =
        DateTime.tryParse('${startDate}T00:00:00Z') ?? DateTime.now().toUtc();
    final picked = await showDatePicker(
        context: context,
        initialDate: current,
        firstDate: DateTime.utc(2020),
        lastDate: DateTime.utc(2035));
    if (picked != null) setState(() => startDate = _isoDate(picked.toUtc()));
  }

  void _addPortion() {
    final text = portionInput.text.trim();
    if (text.isEmpty) return;
    try {
      final value = _parseExactInput(context, text);
      if (portions.any((p) => p == value)) {
        portionInput.clear();
        return;
      }
      setState(() {
        portions = [...portions, value]..sort();
        portionInput.clear();
      });
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  /// Offers each actual candidate ingredient once, then retains any selected
  /// id whose food is no longer present in the current candidates.
  List<MapEntry<String, String>> _unavailableOptions() {
    final options = <MapEntry<String, String>>[
      ...widget.unavailableFoodChoices.entries
    ];
    final known = widget.unavailableFoodChoices.keys.toSet();
    for (final id in unavailableFoodIds) {
      if (!known.contains(id)) options.add(MapEntry(id, id));
    }
    options.sort((a, b) {
      final byName = a.value.toLowerCase().compareTo(b.value.toLowerCase());
      return byName != 0 ? byName : a.key.compareTo(b.key);
    });
    return options;
  }

  /// Offers each actual recipe candidate once, then retains a selected id
  /// whose recipe is no longer in the current catalogue so a missing
  /// preference is shown and can be reviewed instead of silently dropped.
  List<MapEntry<String, String>> _preferenceOptions() {
    final options = <MapEntry<String, String>>[
      ...widget.recipeChoices.entries
    ];
    final known = widget.recipeChoices.keys.toSet();
    for (final id in preferredRecipeIds) {
      if (!known.contains(id)) options.add(MapEntry(id, id));
    }
    options.sort((a, b) {
      final byName = a.value.toLowerCase().compareTo(b.value.toLowerCase());
      return byName != 0 ? byName : a.key.compareTo(b.key);
    });
    return options;
  }

  Future<void> _save() async {
    try {
      final dayCount = int.tryParse(days.text.trim());
      if (dayCount == null || dayCount < 1 || dayCount > 31) {
        throw FormatException(tr(context,
            'Choose between 1 and 31 days', 'Escolhe entre 1 e 31 dias'));
      }
      final name = label.text.trim();
      if (name.isEmpty) {
        throw FormatException(tr(context, 'A meal label is required',
            'O nome da refeição é obrigatório'));
      }
      final maxMinutes = minutes.text.trim().isEmpty
          ? null
          : int.tryParse(minutes.text.trim());
      if (minutes.text.trim().isNotEmpty &&
          (maxMinutes == null || maxMinutes < 1)) {
        throw FormatException(tr(context, 'Cooking time must be a positive number of minutes',
            'O tempo de confeção deve ser um número positivo de minutos'));
      }
      final maxRepeats = repeats.text.trim().isEmpty
          ? null
          : int.tryParse(repeats.text.trim());
      if (repeats.text.trim().isNotEmpty &&
          (maxRepeats == null || maxRepeats < 1)) {
        throw FormatException(tr(context, 'Repeats must be a positive whole number',
            'As repetições devem ser um número inteiro positivo'));
      }
      Exact? minEnergy;
      Exact? maxEnergy;
      final minText = energyMin.text.trim();
      final maxText = energyMax.text.trim();
      if (minText.isNotEmpty || maxText.isNotEmpty) {
        if (minText.isEmpty || maxText.isEmpty) {
          throw FormatException(tr(
              context,
              'Enter both daily energy bounds or neither',
              'Introduz os dois limites energéticos diários ou nenhum'));
        }
        minEnergy = _parseExactInput(context, minText);
        maxEnergy = _parseExactInput(context, maxText);
        if (!minEnergy.positive || !maxEnergy.positive) {
          throw FormatException(tr(context, 'Energy bounds must be positive',
              'Os limites energéticos devem ser positivos'));
        }
        if (minEnergy.compareTo(maxEnergy) > 0) {
          throw FormatException(tr(
              context,
              'The minimum energy bound exceeds the maximum',
              'O limite energético mínimo excede o máximo'));
        }
      }
      final changedIdentity = startDate != widget.initial.startDate ||
          name != widget.initial.label;
      if (changedIdentity &&
          initialExclusions.isNotEmpty &&
          !restoreExcluded) {
        final confirmed = await confirmAction(
            context,
            tr(context, 'Restore excluded days with this schedule change?',
                'Restaurar dias excluídos com esta alteração de horário?'),
            tr(
                context,
                'Changing the start date or meal label restores every excluded day in the same revision. No retained meal is moved automatically; repair plans the new schedule and reports pinned meals that no longer fit.',
                'Alterar a data de início ou o nome da refeição restaura todos os dias excluídos na mesma revisão. Nenhuma refeição retida se move automaticamente; a reparação planeia o novo horário e reporta as refeições fixadas que já não encaixam.'));
        if (!confirmed) return;
        if (!mounted) return;
      }
      var excluded = const <String>[];
      if (!restoreExcluded && !changedIdentity) {
        final parsed = PlanSchedule.fromMetadata({
          'startDate': startDate,
          'days': dayCount,
          'label': name,
          'excludedSlotIds': const <String>[],
        });
        if (parsed == null) {
          throw StateError('A planner schedule is required');
        }
        excluded = [
          for (final id in initialExclusions)
            if (parsed.generatedSlotIds.contains(id)) id
        ];
      }
      Navigator.pop(
          context,
          _PlannerSettings(
            startDate: startDate,
            days: dayCount,
            label: name,
            portions: portions,
            excludedSlotIds: excluded,
            unavailableFoodIds: unavailableFoodIds,
            maximumMinutes: maxMinutes,
            maximumRepeats: maxRepeats,
            energyMinimum: minEnergy,
            energyMaximum: maxEnergy,
            constraintRevision: widget.initial.constraintRevision + 1,
            relaxations: widget.initial.relaxations,
            acceptedRelaxations: widget.initial.acceptedRelaxations,
            preferredRecipeIds: preferredRecipeIds.toList()..sort(),
            otherPreferences: widget.initial.otherPreferences,
          ));
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  String _excludedDatesLabel() {
    final parsed = PlanSchedule.fromMetadata({
      'startDate': widget.initial.startDate,
      'days': widget.initial.days,
      'label': widget.initial.label,
      'excludedSlotIds': const <String>[],
    });
    if (parsed == null) return '';
    final excluded = initialExclusions.toSet();
    return [
      for (final slot in parsed.generatedSlots)
        if (excluded.contains(slot.id)) slot.date
    ].join(', ');
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title:
              Text(tr(c, 'Schedule and constraints', 'Horário e restrições')),
          content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    OutlinedButton.icon(
                        key: const Key('scheduleStartDate'),
                        icon: const Icon(Icons.event),
                        label: Text(startDate),
                        onPressed: _pickDate),
                    TextField(
                        key: const Key('scheduleDaysField'),
                        controller: days,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText:
                                tr(c, 'Number of days', 'Número de dias'))),
                    TextField(
                        key: const Key('scheduleLabelField'),
                        controller: label,
                        decoration: InputDecoration(
                            labelText: tr(c, 'Meal label', 'Nome da refeição'))),
                    const SizedBox(height: 12),
                    Text(tr(c, 'Exact portion options (servings)',
                        'Opções exatas de porção (porções)')),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final p in portions)
                        InputChip(
                            label: Text(_exactLabel(p)),
                            onDeleted: portions.length > 1
                                ? () => setState(() =>
                                    portions = [...portions]
                                      ..removeWhere((v) => v == p))
                                : null)
                    ]),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              key: const Key('portionInputField'),
                              controller: portionInput,
                              keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true),
                              decoration: InputDecoration(
                                  labelText: tr(c, 'Add portion',
                                      'Adicionar porção')))),
                      IconButton(
                          tooltip: tr(c, 'Add portion', 'Adicionar porção'),
                          icon: const Icon(Icons.add),
                          onPressed: _addPortion)
                    ]),
                    TextField(
                        key: const Key('scheduleMaxMinutesField'),
                        controller: minutes,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: tr(
                                c,
                                'Maximum cooking time (minutes, optional)',
                                'Tempo máximo de confeção (minutos, opcional)'))),
                    TextField(
                        key: const Key('scheduleMaxRepeatsField'),
                        controller: repeats,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                            labelText: tr(
                                c,
                                'Maximum repeats of one recipe (optional)',
                                'Repetições máximas de uma receita (opcional)'))),
                    TextField(
                        key: const Key('scheduleEnergyMinField'),
                        controller: energyMin,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(
                            labelText: tr(c, 'Daily energy minimum (kcal, optional)',
                                'Energia diária mínima (kcal, opcional)'))),
                    TextField(
                        key: const Key('scheduleEnergyMaxField'),
                        controller: energyMax,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: InputDecoration(
                            labelText: tr(c, 'Daily energy maximum (kcal, optional)',
                                'Energia diária máxima (kcal, opcional)'))),
                    const SizedBox(height: 8),
                    Text(
                        tr(
                            c,
                            'A binding energy range is enforced exactly. Missing nutrient data is never treated as zero, and no nutritional adequacy is claimed.',
                            'Um intervalo energético obrigatório é aplicado exatamente. Dados nutricionais em falta nunca são tratados como zero, e não é feita qualquer afirmação de adequação nutricional.'),
                        style: Theme.of(c).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Semantics(
                        header: true,
                        child: Text(tr(c, 'Preferred recipes (optional, soft)',
                            'Receitas preferidas (opcional, suave)'))),
                    Text(
                        tr(
                            c,
                            'Choose recipes you would like Salu to favor when more than one plan fits. This is a soft preference only: it never overrides allergies, declared diet restrictions, unavailable ingredients or pinned meals, and it never changes intake. A selected recipe missing from the current catalogue stays selected by id until you clear it.',
                            'Escolhe receitas que gostarias que o Salu favorecesse quando mais do que um plano é válido. Isto é apenas uma preferência suave: nunca sobrepõe alergias, restrições alimentares declaradas, ingredientes indisponíveis ou refeições fixadas, e nunca altera o consumo. Uma receita selecionada que já não esteja no catálogo atual mantém-se selecionada pelo id até a limpares.'),
                        style: Theme.of(c).textTheme.bodySmall),
                    if (_preferenceOptions().isEmpty)
                      Text(
                          tr(
                              c,
                              'No recipes are available to prefer yet. Create or import a recipe first.',
                              'Ainda não há receitas para preferir. Cria ou importa primeiro uma receita.'),
                          style: Theme.of(c).textTheme.bodySmall)
                    else
                      for (final entry in _preferenceOptions())
                        CheckboxListTile(
                            key: Key('preferredRecipe:${entry.key}'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: preferredRecipeIds.contains(entry.key),
                            onChanged: (checked) => setState(() {
                                  if (checked == true) {
                                    preferredRecipeIds = {
                                      ...preferredRecipeIds,
                                      entry.key
                                    };
                                  } else {
                                    preferredRecipeIds = {
                                      ...preferredRecipeIds
                                    }..remove(entry.key);
                                  }
                                }),
                            title: Text(entry.value),
                            subtitle: widget.recipeChoices
                                    .containsKey(entry.key)
                                ? null
                                : Text(tr(
                                    c,
                                    'Not in the current recipe catalogue; the preference is kept.',
                                    'Já não está no catálogo de receitas; a preferência é mantida.'))),
                    const SizedBox(height: 12),
                    Semantics(
                        header: true,
                        child: Text(tr(c,
                            'Unavailable ingredients (hard constraint)',
                            'Ingredientes indisponíveis (restrição rígida)'))),
                    Text(
                        tr(
                            c,
                            'Select only ingredients you know are unavailable. This is a hard constraint, not a pantry inventory: Salu never guesses what you have, recipes containing a selected ingredient are not proposed, and this constraint is never relaxed automatically.',
                            'Seleciona apenas ingredientes que sabes estarem indisponíveis. Isto é uma restrição rígida, não um inventário da despensa: o Salu nunca presume o que tens, as receitas com um ingrediente selecionado não são propostas, e esta restrição nunca é relaxada automaticamente.'),
                        style: Theme.of(c).textTheme.bodySmall),
                    if (_unavailableOptions().isEmpty)
                      Text(
                          tr(
                              c,
                              'No recipe ingredients are available to review yet. A selected ingredient is kept even when it is no longer in the current recipe catalogue.',
                              'Ainda não há ingredientes de receitas para rever. Um ingrediente selecionado é mantido mesmo que já não esteja no catálogo atual de receitas.'),
                          style: Theme.of(c).textTheme.bodySmall)
                    else
                      for (final entry in _unavailableOptions())
                        CheckboxListTile(
                            key: Key('unavailableFood:${entry.key}'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            value: unavailableFoodIds.contains(entry.key),
                            onChanged: (checked) => setState(() {
                                  if (checked == true) {
                                    if (!unavailableFoodIds
                                        .contains(entry.key)) {
                                      unavailableFoodIds = [
                                        ...unavailableFoodIds,
                                        entry.key
                                      ];
                                    }
                                  } else {
                                    unavailableFoodIds = [
                                      ...unavailableFoodIds
                                    ]..remove(entry.key);
                                  }
                                }),
                            title: Text(entry.value),
                            subtitle: widget.unavailableFoodChoices
                                    .containsKey(entry.key)
                                ? null
                                : Text(tr(
                                    c,
                                    'Not in the current recipe catalogue; the selection is kept.',
                                    'Já não está no catálogo de receitas; a seleção é mantida.'))),
                    if (initialExclusions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                          '${tr(c, 'Excluded days (no meal is planned)', 'Dias excluídos (sem refeição planeada)')}: ${_excludedDatesLabel()}'),
                      CheckboxListTile(
                          key: const Key('restoreExcludedDays'),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: restoreExcluded,
                          onChanged: (value) => setState(
                              () => restoreExcluded = value == true),
                          title: Text(tr(c, 'Restore excluded days',
                              'Restaurar dias excluídos')),
                          subtitle: Text(tr(
                              c,
                              'Saving with this checked puts every excluded day back in the schedule. No retained meal moves; repair only fills the restored days.',
                              'Guardar com esta opção marcada repõe todos os dias excluídos no horário. Nenhuma refeição retida se move; a reparação preenche apenas os dias restaurados.'))),
                      Text(
                          tr(
                              c,
                              'Changing the start date or meal label restores all excluded days in the same revision; no meal is moved automatically.',
                              'Alterar a data de início ou o nome da refeição restaura todos os dias excluídos na mesma revisão; nenhuma refeição se move automaticamente.'),
                          style: Theme.of(c).textTheme.bodySmall),
                    ],
                    const SizedBox(height: 8),
                    Text(
                        widget.strictExclusions.isEmpty
                            ? tr(
                                c,
                                'No strict exclusions are declared. Declared medical and allergy exclusions are immutable and cannot be edited here.',
                                'Não há exclusões rígidas declaradas. As exclusões médicas e de alergias declaradas são imutáveis e não podem ser editadas aqui.')
                            : '${tr(c, 'Strict exclusions (immutable)', 'Exclusões rígidas (imutáveis)')}: ${(widget.strictExclusions.toList()..sort()).join(', ')}',
                        style: Theme.of(c).textTheme.bodySmall)
                  ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(c, 'Cancel', 'Cancelar'))),
            FilledButton(
                key: const Key('saveScheduleButton'),
                onPressed: _save,
                child: Text(tr(c, 'Save constraint revision',
                    'Guardar revisão de restrições')))
          ]);
}

class _MealEditDialog extends StatefulWidget {
  const _MealEditDialog(
      {required this.meal, required this.recipes, required this.portions});
  final PlannedMeal meal;
  final List<RecipeVersion> recipes;
  final List<Exact> portions;
  @override
  State<_MealEditDialog> createState() => _MealEditDialogState();
}

class _MealEditDialogState extends State<_MealEditDialog> {
  late String recipeKey;
  late List<Exact> options;
  late int portionIndex;

  @override
  void initState() {
    super.initState();
    recipeKey = '${widget.meal.recipe.id}:${widget.meal.recipe.revision}';
    options = [...widget.portions];
    final index = options.indexWhere((p) => p == widget.meal.portions);
    if (index == -1) options.add(widget.meal.portions);
    portionIndex = index == -1 ? options.length - 1 : index;
  }

  @override
  Widget build(BuildContext c) {
    final choices = {for (final r in widget.recipes) '${r.id}:${r.revision}': r};
    if (!choices.containsKey(recipeKey)) {
      choices[recipeKey] = widget.meal.recipe;
    }
    return AlertDialog(
        title: Text(tr(c, 'Edit planned meal', 'Editar refeição planeada')),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                  initialValue: recipeKey,
                  isExpanded: true,
                  decoration: InputDecoration(
                      labelText: tr(c, 'Recipe version', 'Versão da receita')),
                  items: [
                    for (final entry in choices.entries)
                      DropdownMenuItem(
                          value: entry.key,
                          child: Text(
                              '${entry.value.name} · v${entry.value.revision} · ${entry.value.minutes} min',
                              overflow: TextOverflow.ellipsis))
                  ],
                  onChanged: (value) =>
                      setState(() => recipeKey = value ?? recipeKey)),
              DropdownButtonFormField<String>(
                  initialValue: '$portionIndex',
                  decoration: InputDecoration(
                      labelText: tr(c, 'Exact portion', 'Porção exata')),
                  items: [
                    for (var i = 0; i < options.length; i++)
                      DropdownMenuItem(
                          value: '$i',
                          child: Text(
                              '${_exactLabel(options[i])} ${tr(c, 'servings', 'porções')}'))
                  ],
                  onChanged: (value) => setState(
                      () => portionIndex = int.parse(value ?? '$portionIndex'))),
              const SizedBox(height: 8),
              Text(
                  tr(
                      c,
                      'Only recipes compatible with strict exclusions are offered. Cooking-time and repetition limits are rechecked when you repair the plan.',
                      'Apenas são oferecidas receitas compatíveis com as exclusões rígidas. Os limites de tempo e repetições são reverificados quando reparas o plano.'),
                  style: Theme.of(c).textTheme.bodySmall)
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: Text(tr(c, 'Cancel', 'Cancelar'))),
          FilledButton(
              onPressed: () => Navigator.pop(
                  c, _MealEdit(choices[recipeKey]!, options[portionIndex])),
              child: Text(tr(c, 'Save meal', 'Guardar refeição')))
        ]);
  }
}

class _BatchCreateDialog extends StatefulWidget {
  const _BatchCreateDialog({required this.recipe});
  final RecipeVersion recipe;

  @override
  State<_BatchCreateDialog> createState() => _BatchCreateDialogState();
}

class _BatchCreateDialogState extends State<_BatchCreateDialog> {
  FoodUnit unit = FoodUnit.g;
  final weight = TextEditingController();
  late final TextEditingController servings;
  String? error;

  @override
  void initState() {
    super.initState();
    servings =
        TextEditingController(text: _exactLabel(widget.recipe.servings));
  }

  @override
  void dispose() {
    weight.dispose();
    servings.dispose();
    super.dispose();
  }

  void _save() {
    try {
      if (unit == FoodUnit.g) {
        final grams = _parseExact(weight.text);
        if (!grams.positive) throw const FormatException('positive');
        Navigator.pop(context, _BatchDraft(FoodUnit.g, grams));
        return;
      }
      final count = _parseExact(servings.text);
      if (!count.positive) throw const FormatException('positive');
      Navigator.pop(context, _BatchDraft(FoodUnit.serving, count));
    } catch (_) {
      setState(() => error = unit == FoodUnit.g
          ? tr(context, 'Enter a positive measured weight in grams.',
              'Introduz um peso medido positivo em gramas.')
          : tr(context, 'Enter a positive number of equal servings.',
              'Introduz um número positivo de porções iguais.'));
    }
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
      title:
          Text(tr(c, 'Record a cooked batch', 'Registar um lote confecionado')),
      content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<FoodUnit>(
                segments: [
                  ButtonSegment(
                      value: FoodUnit.g,
                      icon: const Icon(Icons.scale_outlined),
                      label: Text(tr(c, 'Measured grams', 'Gramas medidas'))),
                  ButtonSegment(
                      value: FoodUnit.serving,
                      icon: const Icon(Icons.pie_chart_outline),
                      label:
                          Text(tr(c, 'Equal servings', 'Porções iguais')))
                ],
                selected: {unit},
                onSelectionChanged: (values) => setState(() {
                      unit = values.single;
                      error = null;
                    })),
            const SizedBox(height: 16),
            if (unit == FoodUnit.g)
              TextField(
                  controller: weight,
                  autofocus: true,
                  decoration: InputDecoration(
                      labelText: tr(c, 'Measured finished weight (g)',
                          'Peso final medido (g)')))
            else ...[
              TextField(
                  controller: servings,
                  autofocus: true,
                  decoration: InputDecoration(
                      labelText: tr(c, 'Equal servings in this batch',
                          'Porções iguais neste lote'))),
              const SizedBox(height: 8),
              Text(
                  tr(
                      c,
                      'One recipe execution defaults to the recipe\'s ${_exactLabel(widget.recipe.servings)} declared servings. A different positive count is allowed only for equal-sized portions; nutrition per serving uses the recipe total divided by its declared servings. No finished weight is measured or guessed.',
                      'Uma execução da receita corresponde por omissão às ${_exactLabel(widget.recipe.servings)} porções declaradas. Um número diferente só é permitido para porções de tamanho igual; a nutrição por porção usa o total da receita dividido pelas porções declaradas. Não é medido nem presumido qualquer peso final.'),
                  style: Theme.of(c).textTheme.bodySmall)
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!,
                  style: TextStyle(color: Theme.of(c).colorScheme.error))
            ]
          ]))),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c),
            child: Text(tr(c, 'Cancel', 'Cancelar'))),
        FilledButton(
            onPressed: _save,
            child: Text(tr(c, 'Create batch', 'Criar lote')))
      ]);
}

class _BatchPickerDialog extends StatelessWidget {
  const _BatchPickerDialog({required this.batches, required this.meal});
  final List<BatchStockView> batches;
  final PlannedMeal meal;
  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text(tr(c, 'Choose cooked stock', 'Escolher stock confecionado')),
          content: SizedBox(
              width: 420,
              child: ListView(shrinkWrap: true, children: [
                for (final b in batches)
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: Text(
                          '${b.recipe.name} · v${b.recipe.revision}'),
                      subtitle: Text(
                          '${tr(c, 'Remaining', 'Restante')}: ${batchAmountLabel(c, b.unit, b.remaining)} · ${tr(c, 'planned portion', 'porção planeada')}: ${batchAmountLabel(c, b.unit, b.amountForPortions(meal.portions))}'),
                      onTap: () => Navigator.pop(c, b))
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(c, 'Cancel', 'Cancelar')))
          ]);
}

class _GroceryDialog extends StatefulWidget {
  const _GroceryDialog(
      {required this.title,
      this.initialName = '',
      this.initialGrams,
      this.planGrams,
      this.preparation,
      this.allowQuantity = false});
  final String title;
  final String initialName;
  final Exact? initialGrams;
  final Exact? planGrams;
  final Preparation? preparation;
  final bool allowQuantity;
  @override
  State<_GroceryDialog> createState() => _GroceryDialogState();
}

class _GroceryDialogState extends State<_GroceryDialog> {
  late final TextEditingController name;
  late final TextEditingController grams;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.initialName);
    grams = TextEditingController(
        text: widget.initialGrams == null ? '' : _exactLabel(widget.initialGrams!));
  }

  @override
  void dispose() {
    name.dispose();
    grams.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final value = name.text.trim();
      if (value.isEmpty) {
        throw FormatException(tr(
            context, 'An item name is required', 'O nome do artigo é obrigatório'));
      }
      Exact? quantity;
      final text = grams.text.trim();
      if (text.isNotEmpty) {
        quantity = _parseExactInput(context, text);
        if (!quantity.positive) {
          throw FormatException(tr(context, 'Quantity must be positive',
              'A quantidade deve ser positiva'));
        }
      }
      Navigator.pop(context, _GroceryEdit(value, quantity));
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: name,
                    autofocus: true,
                    decoration: InputDecoration(
                        labelText: tr(c, 'Item name', 'Nome do artigo'))),
                if (widget.allowQuantity) ...[
                  if (widget.planGrams != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                            '${tr(c, 'Plan quantity', 'Quantidade do plano')}: ${_grams(widget.planGrams!)}'
                            '${widget.preparation == null ? '' : ' · ${_preparationLabel(c, widget.preparation!)}'}',
                            style: Theme.of(c).textTheme.bodySmall)),
                  TextField(
                      controller: grams,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      decoration: InputDecoration(
                          labelText: tr(c, 'Your quantity (g, optional)',
                              'A tua quantidade (g, opcional)'),
                          hintText: tr(c, 'Leave empty to use the plan quantity',
                              'Deixa vazio para usar a quantidade do plano'))),
                  Text(
                      tr(
                          c,
                          'Only grams in the recorded preparation state are accepted. No unit or raw/cooked conversion is invented.',
                          'Só são aceites gramas no estado de preparação registado. Não é inventada qualquer conversão de unidade ou entre cru e confecionado.'),
                      style: Theme.of(c).textTheme.bodySmall)
                ]
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(c, 'Cancel', 'Cancelar'))),
            FilledButton(
                onPressed: _save, child: Text(tr(c, 'Continue', 'Continuar')))
          ]);
}

class _RecipeEditor extends ConsumerStatefulWidget {
  const _RecipeEditor({this.existing});
  final RecipeVersion? existing;
  @override
  ConsumerState<_RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends ConsumerState<_RecipeEditor> {
  final name = TextEditingController(),
      servings = TextEditingController(text: '1'),
      minutes = TextEditingController(text: '20');
  List<RecipeIngredient> ingredients = [];
  List<Food> matches = [];
  bool saving = false;
  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    if (r != null) {
      name.text = r.name;
      servings.text = r.servings.toDouble().toString();
      minutes.text = '${r.minutes}';
      ingredients = [...r.ingredients];
    }
  }

  @override
  void dispose() {
    name.dispose();
    servings.dispose();
    minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: Text(tr(c, 'Recipe version', 'Versão da receita'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
            controller: name,
            decoration: InputDecoration(
                labelText: tr(c, 'Recipe name', 'Nome da receita'))),
        TextField(
            controller: servings,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr(c, 'Equal servings in this recipe',
                    'Porções iguais nesta receita'))),
        TextField(
            controller: minutes,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: tr(c, 'Cooking time (minutes)',
                    'Tempo de confeção (minutos)'))),
        for (var i = 0; i < ingredients.length; i++)
          ListTile(
              title: Text(ingredients[i].food.name),
              subtitle: Text('${number(ingredients[i].grams.toDouble())} g'),
              trailing: IconButton(
                  tooltip: tr(c, 'Remove ingredient', 'Remover ingrediente'),
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() => ingredients.removeAt(i)))),
        TextField(
            decoration: InputDecoration(
                labelText: tr(c, 'Search ingredient', 'Pesquisar ingrediente')),
            onChanged: (q) async {
              final result = q.length < 2
                  ? <Food>[]
                  : await ref.read(foodRepositoryProvider).search(q);
              if (mounted) {
                setState(() => matches =
                    result.where((f) => f.basisUnit == FoodUnit.g).toList());
              }
            }),
        for (final f in matches)
          ListTile(
              title: Text(f.name),
              onTap: () async {
                final text = await askText(c,
                    title: tr(c, 'Edible ingredient grams',
                        'Gramas comestíveis do ingrediente'));
                if (text == null || !c.mounted) return;
                try {
                  final ingredient =
                      RecipeIngredient(f, _parseExactInput(c, text));
                  setState(() {
                    ingredients.add(ingredient);
                    matches = [];
                  });
                } catch (e) {
                  if (c.mounted) showFailure(c, e);
                }
              }),
        const SizedBox(height: 16),
        Text(tr(
            c,
            'Enter actual edible quantities. Cooking losses are not modeled. Allergen metadata remains unknown if any ingredient is unknown.',
            'Introduz quantidades comestíveis reais. As perdas na confeção não são modeladas. Os alergénios permanecem desconhecidos se algum ingrediente for desconhecido.')),
        FilledButton(
            onPressed: saving ? null : _save,
            child: Text(tr(c, 'Save immutable recipe version',
                'Guardar versão imutável da receita')))
      ]));

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      final id = widget.existing?.id ?? ref.read(idGeneratorProvider).next();
      final version = (widget.existing?.revision ?? 0) + 1;
      final r = RecipeVersion(
          id: id,
          revision: version,
          name: name.text.trim(),
          ingredients: ingredients,
          servings: _parseExactInput(context, servings.text),
          minutes: int.parse(minutes.text),
          allergens: ingredients.any((i) => i.food.allergens == null)
              ? null
              : ingredients.expand((i) => i.food.allergens!).toSet());
      if (r.name.isEmpty) throw ArgumentError('Recipe name required');
      await LocalWorkspace(ref.read(databaseProvider)).put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'recipe',
          id: '$id:$version',
          expectedRevision: 0,
          data: recipeSnapshot(r));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}
