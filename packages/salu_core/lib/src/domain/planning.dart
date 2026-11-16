import 'dart:convert';
import 'condition_guidance.dart';
import 'food.dart';
import 'nutrients.dart';
import 'nutrition_contract.dart';

/// Definition-integrity fields that planning treats as safety relevant.
///
/// A recipe stores a frozen food snapshot. When [PlannerContext.currentFoods]
/// is supplied, planning only accepts a snapshot whose defining fields still
/// match the current record; nutrient edits, allergen changes, basis changes
/// and preparation changes all invalidate the old snapshot instead of silently
/// planning against stale data.
String _foodSignature(Food food) => jsonEncode({
      'id': food.id,
      'basisUnit': food.basisUnit.name,
      'basisValue': food.basisValue,
      'state': food.preparation.name,
      'allergens':
          food.allergens == null ? null : (food.allergens!.toList()..sort()),
      'nutrients': {
        for (final key in NutrientKey.values)
          if (food.per100g.values.containsKey(key))
            key.wire: food.per100g[key].toJson()
      },
    });

/// Whether a food snapshot has a usable edible-mass basis for a recipe.
bool _hasMassBasis(Food food) {
  if (food.basisUnit != FoodUnit.g) return false;
  try {
    return Exact.parse(food.basisValue).positive;
  } on FormatException {
    return false;
  }
}

final class RecipeIngredient {
  RecipeIngredient(Food food, this.grams,
      {Set<String>? declaredAllergens, String? allergenDeclarationSource})
      : declaredAllergens = declaredAllergens == null
            ? null
            : Set.unmodifiable(declaredAllergens),
        allergenDeclarationSource = allergenDeclarationSource,
        food = Food(
            id: food.id,
            name: food.name,
            per100g: food.per100g,
            source: food.source,
            portions: food.portions,
            quality: food.quality,
            preparation: food.preparation,
            allergens: food.allergens == null
                ? null
                : Set.unmodifiable(food.allergens!),
            dietaryTags: Set.unmodifiable(food.dietaryTags),
            isComposite: food.isComposite,
            basisUnit: food.basisUnit,
            basisValue: food.basisValue,
            aliases: List.unmodifiable(food.aliases),
            barcodes: List.unmodifiable(food.barcodes),
            regions: List.unmodifiable(food.regions),
            observations: List.unmodifiable(food.observations)) {
    if (!grams.positive) {
      throw ArgumentError('Ingredient amount must be positive');
    }
    if ((declaredAllergens == null) !=
        (allergenDeclarationSource == null)) {
      throw ArgumentError('declaredAllergens and '
          'allergenDeclarationSource must be provided together');
    }
    if (declaredAllergens != null &&
        allergenDeclarationSource!.trim().isEmpty) {
      throw ArgumentError('allergenDeclarationSource must be nonempty');
    }
    if (declaredAllergens != null &&
        declaredAllergens.any((a) => a.trim().isEmpty)) {
      throw ArgumentError('declared allergens must be nonempty');
    }
  }

  final Food food;
  final Exact grams;

  /// Salu's recipe-composition assessment for this ingredient, or null when no
  /// composition declaration exists. This is new information at the recipe
  /// level; it never rewrites the imported [Food] row.
  final Set<String>? declaredAllergens;
  final String? allergenDeclarationSource;

  /// Effective allergens for exclusion checks.
  ///
  /// With a declaration, the union of the declaration and any source-known
  /// allergens; without one, [Food.allergens] unchanged (null stays null, so
  /// unknown status still fails exclusions). Known allergens are never erased.
  Set<String>? get effectiveAllergens {
    final declared = declaredAllergens;
    if (declared == null) return food.allergens;
    final known = food.allergens;
    if (known == null) return Set.unmodifiable(declared);
    return Set.unmodifiable({...known, ...declared});
  }

  NutrientProfile get nutrients => food.nutrientsForExactGrams(grams);
}

/// Immutable definition, deliberately distinct from finite cooked stock.
final class RecipeVersion {
  RecipeVersion(
      {required this.id,
      required this.revision,
      required this.name,
      required List<RecipeIngredient> ingredients,
      required this.servings,
      required this.minutes,
      Set<String>? allergens,
      Set<String> dietaryTags = const {}})
      : ingredients = List.unmodifiable(ingredients),
        allergens = allergens == null ? null : Set.unmodifiable(allergens),
        dietaryTags = Set.unmodifiable(dietaryTags) {
    if (id.isEmpty ||
        revision < 1 ||
        ingredients.isEmpty ||
        !servings.positive ||
        minutes < 0) {
      throw ArgumentError('Invalid recipe');
    }
  }
  final String id, name;
  final int revision, minutes;
  final Exact servings;
  final List<RecipeIngredient> ingredients;
  final Set<String>? allergens;
  final Set<String> dietaryTags;

  /// True when every ingredient carries a stable id and a mass basis.
  ///
  /// Recipe quantities are edible grams, so a volume/serving-based snapshot is
  /// unresolved for planning rather than silently converted with an invented
  /// density or piece weight.
  bool get ingredientsResolved => ingredients
      .every((i) => i.food.id.isNotEmpty && _hasMassBasis(i.food));

  late final String definitionSignature = _buildDefinitionSignature();

  String _buildDefinitionSignature() {
    final ingredientMaps = <Map<String, Object?>>[
      for (final i in ingredients)
        {
          'id': i.food.id,
          'name': i.food.name,
          'quantity': i.grams.toJson(),
          'basisUnit': i.food.basisUnit.name,
          'basisValue': i.food.basisValue,
          'source': i.food.source.toString(),
          'state': i.food.preparation.name,
          'allergens': i.food.allergens == null
              ? null
              : (i.food.allergens!.toList()..sort()),
          if (i.declaredAllergens != null) ...{
            'declaredAllergens': (i.declaredAllergens!.toList()..sort()),
            'allergenDeclarationSource': i.allergenDeclarationSource,
          },
          'nutrients': {
            for (final key in NutrientKey.values)
              if (i.food.per100g.values.containsKey(key))
                key.wire: i.food.per100g[key].toJson()
          }
        }
    ];
    return jsonEncode({
      'id': id,
      'revision': revision,
      'name': name,
      'servings': servings.toJson(),
      'minutes': minutes,
      'allergens': allergens == null ? null : (allergens!.toList()..sort()),
      'diet': dietaryTags.toList()..sort(),
      'ingredients': ingredientMaps,
    });
  }
  @override
  bool operator ==(Object other) =>
      other is RecipeVersion &&
      definitionSignature == other.definitionSignature;
  @override
  int get hashCode => definitionSignature.hashCode;
  late final Map<NutrientKey, NutrientSum> totals = Map.unmodifiable(
      NutrientProfile.combine(ingredients.map((i) => i.nutrients)));

  /// Cooking losses are not modeled. Missing nutrients stay partial.
  Map<NutrientKey, NutrientSum> perServing(Exact portion) {
    final scale = portion / servings;
    return totals.map((key, s) => MapEntry(
        key,
        NutrientSum(
            value: (s.exactValue * scale).toDouble(),
            exact: s.exactValue * scale,
            knownEntries: s.knownEntries,
            isComplete: s.isComplete,
            includesTrace: s.includesTrace,
            includesEstimate: s.includesEstimate)));
  }

  /// Immutable hard constraints: explicit diet, strict exclusions and current
  /// ingredient availability.
  ///
  /// When [exclusions] is non-empty, an unknown recipe or ingredient effective
  /// allergen set fails the requirement. Unknown status never establishes
  /// suitability. A recipe-level aggregate ([allergens]) never establishes an
  /// ingredient's own status: only ingredient effective sets are consulted.
  bool eligible(Set<String> exclusions, Set<String> diet,
      {Set<String> unavailableFoodIds = const {}}) {
    if (!ingredientsResolved) return false;
    if (ingredients.any((i) => unavailableFoodIds.contains(i.food.id))) {
      return false;
    }
    if (!diet.every(dietaryTags.contains)) return false;
    if (exclusions.isEmpty) return true;
    if (allergens == null || exclusions.any(allergens!.contains)) {
      return false;
    }
    for (final i in ingredients) {
      final effective = i.effectiveAllergens;
      if (effective == null || exclusions.any(effective.contains)) {
        return false;
      }
    }
    return true;
  }

  /// Stable, de-duplicated reasons why [eligible] would reject this recipe.
  ///
  /// Medical/exclusion reasons are never used to propose a relaxation.
  List<String> ineligibilityReasons(Set<String> exclusions, Set<String> diet,
      {Set<String> unavailableFoodIds = const {}}) {
    final reasons = <String>[];
    void add(String reason) {
      if (!reasons.contains(reason)) reasons.add(reason);
    }

    if (!ingredientsResolved) add('INGREDIENT_UNRESOLVED');
    if (ingredients.any((i) => unavailableFoodIds.contains(i.food.id))) {
      add('INGREDIENT_UNAVAILABLE');
    }
    if (!diet.every(dietaryTags.contains)) add('DIET_CONFLICT');
    if (exclusions.isNotEmpty) {
      if (allergens == null) {
        add('ALLERGEN_STATUS_UNKNOWN');
      } else if (exclusions.any(allergens!.contains)) {
        add('EXCLUSION_CONFLICT');
      }
      for (final i in ingredients) {
        final effective = i.effectiveAllergens;
        if (effective == null) {
          add('ALLERGEN_STATUS_UNKNOWN');
        } else if (exclusions.any(effective.contains)) {
          add('EXCLUSION_CONFLICT');
        }
      }
    }
    return reasons;
  }
}

final class BatchAllocation {
  BatchAllocation(this.id, this.amount, this.status, {this.intakeRequestId}) {
    final intake = intakeRequestId;
    if (id.isEmpty ||
        !amount.positive ||
        (status != plannedStatus && status != consumedStatus)) {
      throw ArgumentError('Invalid allocation');
    }
    if (intake != null && intake.isEmpty) {
      throw ArgumentError('Invalid intake request identity');
    }
    if (intake != null && status != consumedStatus) {
      throw ArgumentError('INTAKE_REQUEST_REQUIRES_CONSUMED_ALLOCATION');
    }
  }

  /// Status of stock reserved for a planned meal.
  static const plannedStatus = 'planned';

  /// Status of stock already consumed. The allocation identity is retained so a
  /// saved plan can account for the same stock exactly once.
  static const consumedStatus = 'consumed';

  final String id;
  final Exact amount;
  final String status;

  /// Diary request that consumed this allocation, when known.
  ///
  /// Consumption never changes [id], so a plan's reservation link survives a
  /// later batch revision or intake revision.
  final String? intakeRequestId;

  bool get planned => status == plannedStatus;
  bool get consumed => status == consumedStatus;
}

final class CookedBatch {
  CookedBatch(
      {required this.id,
      required this.recipe,
      required this.revision,
      required this.available,
      required this.unit,
      this.finishedWeightG,
      List<BatchAllocation> allocations = const []})
      : allocations = List.unmodifiable(allocations) {
    if (id.isEmpty ||
        revision < 1 ||
        !available.positive ||
        (unit != FoodUnit.g && unit != FoodUnit.serving)) {
      throw ArgumentError('Invalid batch');
    }
    if (unit == FoodUnit.g &&
        (finishedWeightG == null || !finishedWeightG!.positive)) {
      throw StateError('MEASURED_YIELD_REQUIRED');
    }
    if (allocations.map((a) => a.id).toSet().length != allocations.length) {
      throw StateError('DUPLICATE_ALLOCATION');
    }
    final intakeRequests = allocations
        .map((a) => a.intakeRequestId)
        .whereType<String>()
        .toList();
    if (intakeRequests.toSet().length != intakeRequests.length) {
      throw StateError('DUPLICATE_INTAKE_REQUEST');
    }
    if (allocated.compareTo(available) > 0) {
      throw StateError('BATCH_OVERALLOCATED');
    }
  }
  final String id;
  final RecipeVersion recipe;
  final int revision;
  final Exact available;
  final FoodUnit unit;
  final Exact? finishedWeightG;
  final List<BatchAllocation> allocations;

  Exact get allocated => allocations.fold(Exact.zero, (a, b) => a + b.amount);

  /// Stock still reserved for meals that have not been eaten.
  Exact get plannedAllocated => allocations
      .where((a) => a.planned)
      .fold(Exact.zero, (a, b) => a + b.amount);

  /// Stock already consumed. It remains allocated, so it is never reserved
  /// again or counted as a second intake by the planner.
  Exact get consumedAllocated => allocations
      .where((a) => a.consumed)
      .fold(Exact.zero, (a, b) => a + b.amount);

  BatchAllocation? allocation(String allocationId) =>
      allocations.where((a) => a.id == allocationId).firstOrNull;

  CookedBatch allocate(BatchAllocation allocation,
      {required int expectedRevision}) {
    if (expectedRevision != revision) throw StateError('STALE_BATCH');
    return CookedBatch(
        id: id,
        recipe: recipe,
        revision: revision + 1,
        available: available,
        unit: unit,
        finishedWeightG: finishedWeightG,
        allocations: [...allocations, allocation]);
  }

  Map<NutrientKey, NutrientSum> nutrientsFor(Exact amount) {
    if (!amount.positive || amount.compareTo(available) > 0) {
      throw ArgumentError('Invalid portion');
    }
    final factor = unit == FoodUnit.g
        ? amount / finishedWeightG!
        : amount / recipe.servings;
    return recipe.totals.map((k, s) => MapEntry(
        k,
        NutrientSum(
            value: (s.exactValue * factor).toDouble(),
            exact: s.exactValue * factor,
            knownEntries: s.knownEntries,
            isComplete: s.isComplete,
            includesTrace: s.includesTrace,
            includesEstimate: s.includesEstimate)));
  }
}

final class MealSlot {
  const MealSlot(this.id, this.date, this.label);
  final String id, date, label;
}

/// Reservation of finite cooked stock. The allocation ID links a meal to an
/// existing reservation, allowing it to be counted exactly once across weeks.
///
/// [batchRevision] records the batch document revision used to create the
/// reservation. Allocations are append-only, so a later reservation or
/// consumption only proves the batch moved forward; the reservation remains
/// valid while [allocationId] still resolves to the same amount. A recorded
/// revision from the future is rejected.
final class PlannedBatchUse {
  PlannedBatchUse(this.batchId, this.batchRevision, this.allocationId) {
    if (batchId.isEmpty || batchRevision < 1 || allocationId.isEmpty) {
      throw ArgumentError('Invalid planned batch use');
    }
  }
  final String batchId, allocationId;
  final int batchRevision;
}

final class PlannedMeal {
  PlannedMeal(this.slot, this.recipe, this.portions,
      {this.pinned = false, this.batchUse}) {
    if (!portions.positive) throw ArgumentError('Portions must be positive');
  }
  final MealSlot slot;
  final RecipeVersion recipe;
  final Exact portions;
  final bool pinned;

  /// Present only when this meal consumes existing cooked stock. A plan never
  /// creates intake; consuming a stocked meal is a separate confirmed command.
  final PlannedBatchUse? batchUse;
  late final Map<NutrientKey, NutrientSum> nutrients =
      Map.unmodifiable(recipe.perServing(portions));
}

final class NumericConstraint {
  NumericConstraint(this.nutrient, this.minimum, this.maximum) {
    if (minimum.compareTo(maximum) > 0 || minimum.compareTo(Exact.zero) < 0) {
      throw ArgumentError('TARGET_CONFLICT');
    }
  }
  final NutrientKey nutrient;
  final Exact minimum, maximum;

  Exact get center => (minimum + maximum) / Exact.parse('2');
  Exact get span => maximum - minimum;
}

/// Ordered soft objectives. Earlier entries dominate later ones after hard
/// feasibility and preservation of pins/unchanged meals.
///
/// The default order follows the nutrition contract: target proximity, data
/// completeness, relative guidance, explicit recipe preference, cooking
/// effort, ingredient reuse, variety.
/// [PlannerObjective.guidance] is inert until the caller supplies
/// [PlannerContext.guidanceNutrients] or an experimental
/// [PlannerContext.conditionGuidance] assessment with relative directives; no
/// sodium/saturated-fat/free-sugar threshold is invented. Unknown decisive
/// nutrients are penalized as unknown, never as zero.
/// [PlannerObjective.recipePreference] is inert until the caller supplies
/// [PlannerContext.preferredRecipeIds] and only counts
/// explicit stable recipe ids. Budget estimates, food-group metadata and
/// learned preference weights are not modeled here, so no guessed price, group
/// or inferred preference policy is applied.
enum PlannerObjective {
  practicalPreference,
  targetProximity,
  dataCompleteness,
  guidance,
  recipePreference,
  cookingEffort,
  ingredientReuse,
  variety,
}

const List<PlannerObjective> defaultPlannerObjectives = [
  PlannerObjective.targetProximity,
  PlannerObjective.dataCompleteness,
  PlannerObjective.guidance,
  PlannerObjective.recipePreference,
  PlannerObjective.cookingEffort,
  PlannerObjective.ingredientReuse,
  PlannerObjective.variety,
];

enum PlannerRelaxationKind {
  maximumMinutes,
  maximumRepeats,
  portions,
  numericConstraint,
  pin,
}

/// A user-confirmable, non-medical change to user-hard planning constraints.
///
/// A null [maximumMinutes] or [maximumRepeats] removes that limit. A null
/// [constraint] with a non-null [constraintNutrient] removes that numeric
/// range. Medical exclusions, diet restrictions, allergen status and catalogue
/// identity have no representation here and can never be relaxed.
final class PlannerRelaxation {
  PlannerRelaxation({
    required this.kind,
    required this.reason,
    required this.baseRevision,
    this.maximumMinutes,
    this.maximumRepeats,
    List<Exact>? portions,
    this.constraintNutrient,
    this.constraint,
    this.slotId,
  })  : portions = portions == null
            ? null
            : List<Exact>.unmodifiable(portions) {
    final minutes = maximumMinutes;
    final repeats = maximumRepeats;
    final portionValues = portions;
    final nutrient = constraintNutrient;
    final numeric = constraint;
    final pinSlot = slotId;
    if (reason.isEmpty || baseRevision < 1) {
      throw ArgumentError('Invalid relaxation');
    }
    switch (kind) {
      case PlannerRelaxationKind.maximumMinutes:
        if (minutes != null && minutes < 0) {
          throw ArgumentError('Invalid relaxation');
        }
        _requireOnly(minutes: true);
        break;
      case PlannerRelaxationKind.maximumRepeats:
        if (repeats != null && repeats < 1) {
          throw ArgumentError('Invalid relaxation');
        }
        _requireOnly(repeats: true);
        break;
      case PlannerRelaxationKind.portions:
        if (portionValues == null ||
            portionValues.isEmpty ||
            portionValues.any((p) => !p.positive)) {
          throw ArgumentError('Invalid relaxation');
        }
        _requireOnly(portions: true);
        break;
      case PlannerRelaxationKind.numericConstraint:
        if (nutrient == null ||
            (numeric != null && numeric.nutrient != nutrient)) {
          throw ArgumentError('Invalid relaxation');
        }
        _requireOnly(constraint: true);
        break;
      case PlannerRelaxationKind.pin:
        if (pinSlot == null || pinSlot.isEmpty) {
          throw ArgumentError('Invalid relaxation');
        }
        _requireOnly(pin: true);
        break;
    }
  }

  final PlannerRelaxationKind kind;
  final String reason;
  final int baseRevision;
  final int? maximumMinutes;
  final int? maximumRepeats;
  final List<Exact>? portions;
  final NutrientKey? constraintNutrient;
  final NumericConstraint? constraint;
  final String? slotId;

  void _requireOnly(
      {bool minutes = false,
      bool repeats = false,
      bool portions = false,
      bool constraint = false,
      bool pin = false}) {
    if ((!minutes && maximumMinutes != null) ||
        (!repeats && maximumRepeats != null) ||
        (!portions && this.portions != null) ||
        (!constraint && (constraintNutrient != null || this.constraint != null)) ||
        (!pin && slotId != null)) {
      throw ArgumentError('Invalid relaxation');
    }
  }

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'reason': reason,
        'baseRevision': baseRevision,
        'maximumMinutes': maximumMinutes,
        'maximumRepeats': maximumRepeats,
        'portions': portions?.map((p) => p.toJson()).toList(),
        'constraintNutrient': constraintNutrient?.wire,
        'constraintMinimum': constraint?.minimum.toJson(),
        'constraintMaximum': constraint?.maximum.toJson(),
        'slotId': slotId,
      };

  factory PlannerRelaxation.fromJson(Map<String, Object?> json) {
    final nutrientWire = json['constraintNutrient'] as String?;
    final nutrient =
        nutrientWire == null ? null : NutrientKey.fromWire(nutrientWire);
    if (nutrientWire != null && nutrient == null) {
      throw const FormatException('Unknown nutrient');
    }
    final minimum = json['constraintMinimum'];
    final maximum = json['constraintMaximum'];
    NumericConstraint? constraint;
    if (nutrient != null && minimum is Map && maximum is Map) {
      constraint = NumericConstraint(
          nutrient,
          Exact.fromJson(Map<String, Object?>.from(minimum)),
          Exact.fromJson(Map<String, Object?>.from(maximum)));
    }
    return PlannerRelaxation(
        kind: PlannerRelaxationKind.values.byName(json['kind']! as String),
        reason: json['reason']! as String,
        baseRevision: json['baseRevision']! as int,
        maximumMinutes: json['maximumMinutes'] as int?,
        maximumRepeats: json['maximumRepeats'] as int?,
        portions: (json['portions'] as List?)
            ?.map((p) =>
                Exact.fromJson(Map<String, Object?>.from(p as Map)))
            .toList(),
        constraintNutrient: nutrient,
        constraint: constraint,
        slotId: json['slotId'] as String?);
  }

  String get signature => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      other is PlannerRelaxation && other.signature == signature;
  @override
  int get hashCode => signature.hashCode;
}

final class PlannerContext {
  PlannerContext(
      {required List<MealSlot> slots,
      required List<RecipeVersion> recipes,
      required this.seed,
      this.catalogueVersion = 'local',
      this.policyVersion = 'planner-v3',
      this.maxNodes = 2000,
      this.maximumMinutes,
      this.maximumRepeats,
      Set<String> strictExclusions = const {},
      Set<String> dietaryTags = const {},
      List<NumericConstraint> constraints = const [],
      List<CookedBatch> batches = const [],
      List<Exact>? portions,
      this.revision = 1,
      List<PlannerRelaxation> acceptedRelaxations = const [],
      Map<String, Food>? currentFoods,
      Set<String> unavailableFoodIds = const {},
      List<PlannerObjective> objectives = defaultPlannerObjectives,
      Set<NutrientKey> guidanceNutrients = const {},
      Set<String> preferredRecipeIds = const {},
      Map<String, Set<String>> recipeIdsBySlot = const {},
      Map<NutrientKey, Exact> targetGoals = const {},
      Map<String, int> recipePreferenceRanks = const {},
      this.conditionGuidance})
      : slots = List.unmodifiable(slots),
        recipes = List.unmodifiable(recipes),
        batches = List.unmodifiable(batches),
        portions = List.unmodifiable(portions ?? [Exact.one]),
        strictExclusions = Set<String>.unmodifiable(strictExclusions),
        dietaryTags = Set<String>.unmodifiable(dietaryTags),
        constraints = List<NumericConstraint>.unmodifiable(constraints),
        acceptedRelaxations = List<PlannerRelaxation>.unmodifiable(acceptedRelaxations),
        unavailableFoodIds = Set<String>.unmodifiable(unavailableFoodIds),
        objectives = List<PlannerObjective>.unmodifiable(objectives),
        guidanceNutrients = Set<NutrientKey>.unmodifiable(guidanceNutrients),
        preferredRecipeIds = Set<String>.unmodifiable(preferredRecipeIds),
        recipeIdsBySlot = Map.unmodifiable(recipeIdsBySlot.map(
            (key, value) => MapEntry(key, Set<String>.unmodifiable(value)))),
        targetGoals = Map.unmodifiable(targetGoals),
        recipePreferenceRanks = Map.unmodifiable(recipePreferenceRanks),
        currentFoods = currentFoods == null
            ? null
            : Map<String, Food>.unmodifiable(currentFoods) {
    final minutes = maximumMinutes;
    final repeats = maximumRepeats;
    if (maxNodes < 1 ||
        revision < 1 ||
        (minutes != null && minutes < 0) ||
        (repeats != null && repeats < 1) ||
        slots.map((s) => s.id).toSet().length != slots.length ||
        this.portions.isEmpty ||
        this.portions.any((p) => !p.positive) ||
        batches.map((b) => b.id).toSet().length != batches.length ||
        this.objectives.toSet().length != this.objectives.length ||
        this.preferredRecipeIds.any((id) => id.trim().isEmpty) ||
        recipeIdsBySlot.entries.any((entry) =>
            !slots.any((slot) => slot.id == entry.key) ||
            entry.value.any((id) => !recipes.any((recipe) => recipe.id == id))) ||
        targetGoals.values.any((value) => !value.positive) ||
        recipePreferenceRanks.entries.any((entry) =>
            entry.value < 0 || !recipes.any((recipe) => recipe.id == entry.key)) ||
        this.acceptedRelaxations.any((r) => r.baseRevision >= revision) ||
        this.currentFoods != null &&
            this.currentFoods!.entries
                .any((e) => e.key.isEmpty || e.key != e.value.id) ||
        conditionGuidance != null &&
            conditionGuidance!.strictExclusionFingerprint !=
                ConditionGuidancePolicy.exclusionFingerprint(
                    strictExclusions)) {
      throw ArgumentError('Invalid planner context');
    }
  }
  final List<MealSlot> slots;
  final List<RecipeVersion> recipes;
  final List<CookedBatch> batches;
  final List<Exact> portions;
  /// [maxNodes] counts visited search nodes, including the empty root prefix.
  final int seed, maxNodes;
  final String catalogueVersion, policyVersion;
  final int? maximumMinutes, maximumRepeats;
  final Set<String> strictExclusions, dietaryTags;
  final List<NumericConstraint> constraints;

  /// Explicit user-hard constraint revision. Accepted relaxations increment it.
  final int revision;
  final List<PlannerRelaxation> acceptedRelaxations;

  /// Current catalogue definitions keyed by food id, or `null` when planning
  /// makes no catalogue-resolution claim. Supplying a map turns missing or
  /// changed ingredient definitions into hard errors.
  final Map<String, Food>? currentFoods;

  /// Ingredients the user has declared unavailable.
  final Set<String> unavailableFoodIds;
  final List<PlannerObjective> objectives;
  final Set<NutrientKey> guidanceNutrients;

  /// Explicit soft preferences keyed by stable recipe id.
  ///
  /// Only the recipe id matters: names are not identities. Preferences never
  /// relax strict exclusions, diet tags, allergen status, unavailable
  /// ingredients, current catalogue revisions or pinned meals, and they never
  /// write intake. An empty set leaves planning unchanged.
  final Set<String> preferredRecipeIds;
  final Map<String, Set<String>> recipeIdsBySlot;
  final Map<NutrientKey, Exact> targetGoals;
  final Map<String, int> recipePreferenceRanks;

  /// Experimental condition assessment over the current declarations.
  ///
  /// It contributes relative soft directives to
  /// [PlannerObjective.guidance]: no nutrient threshold, target, diagnosis,
  /// medication or severity is inferred. Unknown decisive nutrients are
  /// penalized as unknown in ranking, never read as zero or as healthier.
  /// Hard exclusions and allergen handling stay in [strictExclusions] and the
  /// recipe eligibility checks, and this assessment cannot relax them.
  final ConditionGuidanceAssessment? conditionGuidance;
}

enum PlannerStatus {
  validPlan,
  targetConflict,
  insufficientData,
  searchExhausted,
  provenInfeasible,
  proposedRelaxation
}

final class PlannerQuality {
  const PlannerQuality(
      {required this.preservedMeals,
      required this.scores,
      required this.canonical});
  final int preservedMeals;
  final Map<PlannerObjective, Exact> scores;
  final String canonical;
}

/// Typed planning outcome.
///
/// A plan is organization only: no member of this result writes intake. Meals
/// with [PlannedMeal.batchUse] refer to existing stock, and consumed allocations
/// are accounted once rather than treated as a new reservation.
final class PlannerResult {
  PlannerResult(this.status, List<PlannedMeal> meals, List<String> diagnostics,
      {this.visited = 0,
      this.quality,
      List<PlannerRelaxation> relaxations = const [],
      this.originalStatus})
      : meals = List.unmodifiable(meals),
        diagnostics = List.unmodifiable(diagnostics),
        relaxations = List.unmodifiable(relaxations);
  final PlannerStatus status;
  final List<PlannedMeal> meals;
  final List<String> diagnostics;
  final int visited;
  final PlannerQuality? quality;
  final List<PlannerRelaxation> relaxations;

  /// Failure status replaced by [PlannerStatus.proposedRelaxation], if any.
  final PlannerStatus? originalStatus;
}

final class PlannerAcceptance {
  const PlannerAcceptance(this.context, this.result);
  final PlannerContext context;
  final PlannerResult result;
}

final class _EvaluatedPlan {
  _EvaluatedPlan(this.meals, this.signature, this.preserved, this.scores);
  final List<PlannedMeal> meals;
  final String signature;
  final int preserved;
  final Map<PlannerObjective, Exact> scores;

  PlannerQuality get quality => PlannerQuality(
      preservedMeals: preserved,
      scores: Map<PlannerObjective, Exact>.unmodifiable(scores),
      canonical: signature);
}

final class _RankedChoice {
  const _RankedChoice(this.index, this.meal, this.score);
  final int index;
  final PlannedMeal meal;
  final Exact score;
}

/// Deterministic planner.
///
/// Search order is seeded construction plus bounded depth-first enumeration
/// over the declared recipe/portion space. Valid plans are compared by staged
/// priorities: preservation of pinned/unchanged meals, then the ordered
/// [PlannerContext.objectives], then a canonical serialization for reproducible
/// ties. No result claims global optimality; [PlannerStatus.searchExhausted]
/// is never reported as proof that no plan exists.
final class PlannerService {
  const PlannerService();

  Map<String, int> _currentRevisions(PlannerContext c) {
    final revisions = <String, int>{};
    for (final recipe in c.recipes) {
      final prior = revisions[recipe.id];
      if (prior == null || recipe.revision > prior) {
        revisions[recipe.id] = recipe.revision;
      }
    }
    return revisions;
  }

  List<String> _recipeBlockers(RecipeVersion recipe, PlannerContext c) {
    final reasons = <String>[];
    void add(String reason) {
      if (!reasons.contains(reason)) reasons.add(reason);
    }

    for (final reason in recipe.ineligibilityReasons(
        c.strictExclusions, c.dietaryTags,
        unavailableFoodIds: c.unavailableFoodIds)) {
      add(reason);
    }
    if (c.currentFoods != null) {
      for (final ingredient in recipe.ingredients) {
        final current = c.currentFoods![ingredient.food.id];
        if (current == null) {
          add('INGREDIENT_UNRESOLVED');
        } else if (_foodSignature(current) != _foodSignature(ingredient.food)) {
          add('INGREDIENT_STALE');
        }
      }
    }
    final currentRevision = _currentRevisions(c)[recipe.id];
    if (currentRevision != null && recipe.revision != currentRevision) {
      add('STALE_RECIPE_REVISION');
    }
    if (c.maximumMinutes != null && recipe.minutes > c.maximumMinutes!) {
      add('COOKING_TIME');
    }
    return reasons;
  }

  bool _currentDefinition(RecipeVersion recipe, PlannerContext c) =>
      _currentRevisions(c)[recipe.id] == recipe.revision &&
      c.recipes.any((r) => r.id == recipe.id && r.revision == recipe.revision);

  List<String> _mealDefinitionErrors(PlannedMeal meal, PlannerContext c) {
    final errors = <String>[];
    if (!c.slots
        .any((s) => s.id == meal.slot.id && s.date == meal.slot.date)) {
      errors.add('SLOT_MISMATCH');
    }
    final allowed = c.recipeIdsBySlot[meal.slot.id];
    if (allowed != null && !allowed.contains(meal.recipe.id)) {
      errors.add('MEAL_SLOT_RECIPE_CONFLICT');
    }
    final definitions = c.recipes
        .where((r) =>
            r.id == meal.recipe.id && r.revision == meal.recipe.revision)
        .toList();
    if (!_currentDefinition(meal.recipe, c) ||
        definitions.isEmpty ||
        definitions.first != meal.recipe) {
      errors.add('RECIPE_REVISION_MISMATCH');
    }
    for (final reason in _recipeBlockers(meal.recipe, c)) {
      if (reason != 'COOKING_TIME' && reason != 'STALE_RECIPE_REVISION') {
        errors.add(reason);
      }
    }
    if (c.maximumMinutes != null && meal.recipe.minutes > c.maximumMinutes!) {
      errors.add('COOKING_TIME');
    }
    if (!c.portions.contains(meal.portions)) errors.add('PORTION_BOUNDS');
    return errors;
  }

  Exact _batchAmount(CookedBatch batch, PlannedMeal meal) =>
      batch.unit == FoodUnit.g
          ? batch.finishedWeightG! * meal.portions / batch.recipe.servings
          : meal.portions;

  /// Validates hard constraints. Ingredient-resolution and numeric-data checks
  /// live here, not only in search, so a hand-edited or provider-supplied plan
  /// cannot bypass them.
  List<String> validate(List<PlannedMeal> meals, PlannerContext c) {
    final errors = <String>[];
    final extraByBatch = <String, Exact>{};
    final usedAllocations = <String, Set<String>>{};
    if (meals.length != c.slots.length ||
        meals.map((m) => m.slot.id).toSet().length != meals.length ||
        meals.any((m) => !c.slots.any((s) => s.id == m.slot.id))) {
      errors.add('UNRESOLVED_SLOTS');
    }
    for (final meal in meals) {
      errors.addAll(_mealDefinitionErrors(meal, c));
      final use = meal.batchUse;
      if (use != null) {
        final batch = c.batches.where((b) => b.id == use.batchId).firstOrNull;
        if (batch == null || use.batchRevision > batch.revision) {
          errors.add('BATCH_REVISION_MISMATCH');
        } else if (batch.recipe != meal.recipe) {
          errors.add('BATCH_RECIPE_MISMATCH');
        } else {
          final allocation = batch.allocation(use.allocationId);
          final used = usedAllocations.putIfAbsent(batch.id, () => <String>{});
          // The plan identity and the resolved allocation identity can be the
          // same id. Check each distinct identity once; adding the same string
          // twice would falsely report a duplicate for a single valid use.
          final identities = <String>{use.allocationId};
          if (allocation != null) identities.add(allocation.id);
          var duplicate = false;
          for (final identity in identities) {
            if (!used.add(identity)) duplicate = true;
          }
          if (duplicate) errors.add('DUPLICATE_BATCH_USE');
          final amount = _batchAmount(batch, meal);
          if (allocation == null) {
            // A reservation link that no longer resolves cannot be assumed to
            // be consumed. Count it as unreserved stock so overallocation is
            // still rejected, and require an explicit re-reservation.
            errors.add('BATCH_ALLOCATION_MISSING');
            extraByBatch[batch.id] =
                (extraByBatch[batch.id] ?? Exact.zero) + amount;
          } else if (allocation.amount != amount) {
            errors.add('BATCH_ALLOCATION_MISMATCH');
          }
        }
      }
    }
    for (final batch in c.batches) {
      if ((batch.allocated + (extraByBatch[batch.id] ?? Exact.zero))
              .compareTo(batch.available) >
          0) {
        errors.add('BATCH_STOCK_EXCEEDED');
      }
    }
    if (c.maximumRepeats != null) {
      for (final recipeId in c.recipes.map((r) => r.id).toSet()) {
        if (meals.where((m) => m.recipe.id == recipeId).length >
            c.maximumRepeats!) {
          errors.add('REPETITION_LIMIT');
        }
      }
    }
    for (final day in c.slots.map((s) => s.date).toSet()) {
      final dayMeals = meals.where((m) => m.slot.date == day).toList();
      for (final bound in c.constraints) {
        var sum = Exact.zero;
        var complete = dayMeals.isNotEmpty;
        for (final meal in dayMeals) {
          if (!meal.recipe.ingredientsResolved) {
            complete = false;
            continue;
          }
          final nutrient = meal.nutrients[bound.nutrient];
          if (nutrient == null ||
              !nutrient.isComplete ||
              nutrient.includesEstimate) {
            complete = false;
          }
          sum += nutrient?.exactValue ?? Exact.zero;
        }
        if (!complete) {
          errors.add('INSUFFICIENT_NUTRIENT_DATA');
        } else if (sum.compareTo(bound.minimum) < 0 ||
            sum.compareTo(bound.maximum) > 0) {
          errors.add('NUMERIC_CONSTRAINT');
        }
      }
    }
    final seen = <String>{};
    return errors.where(seen.add).toList();
  }

  List<String> _missingNutrientDetails(
      List<PlannedMeal> meals, PlannerContext c) {
    final details = <String>{};
    for (final day in c.slots.map((s) => s.date).toSet()) {
      final dayMeals = meals.where((m) => m.slot.date == day).toList();
      for (final bound in c.constraints) {
        for (final meal in dayMeals) {
          if (!meal.recipe.ingredientsResolved) {
            details.add('${bound.nutrient.wire}@$day:ingredient');
            continue;
          }
          final nutrient = meal.nutrients[bound.nutrient];
          if (nutrient == null ||
              !nutrient.isComplete ||
              nutrient.includesEstimate) {
            details.add('${bound.nutrient.wire}@$day');
          }
        }
      }
    }
    return details.toList();
  }

  bool _resolvedByCurrentFood(RecipeVersion recipe, PlannerContext c) {
    if (c.currentFoods == null) return true;
    for (final ingredient in recipe.ingredients) {
      final current = c.currentFoods![ingredient.food.id];
      if (current == null || _foodSignature(current) != _foodSignature(ingredient.food)) {
        return false;
      }
    }
    return true;
  }

  List<RecipeVersion> _eligibleRecipes(PlannerContext c) {
    final current = _currentRevisions(c);
    final eligible = c.recipes
        .where((recipe) =>
            current[recipe.id] == recipe.revision &&
            recipe.eligible(c.strictExclusions, c.dietaryTags,
                unavailableFoodIds: c.unavailableFoodIds) &&
            _resolvedByCurrentFood(recipe, c) &&
            (c.maximumMinutes == null ||
                recipe.minutes <= c.maximumMinutes!))
        .toList()
      ..sort((a, b) {
        final order = a.id.compareTo(b.id);
        return order == 0 ? a.revision.compareTo(b.revision) : order;
      });
    return eligible;
  }

  List<String> _emptyEligibleDiagnostics(PlannerContext c) {
    final diagnostics = <String>['EMPTY_ELIGIBLE_SET'];
    final recipes = [...c.recipes]..sort((a, b) {
        final order = a.id.compareTo(b.id);
        return order == 0 ? a.revision.compareTo(b.revision) : order;
      });
    for (final recipe in recipes) {
      final reasons = _recipeBlockers(recipe, c);
      if (reasons.isNotEmpty) {
        diagnostics
            .add('${recipe.id}@${recipe.revision}: ${reasons.join('|')}');
      }
    }
    return diagnostics;
  }

  bool _sameBatchUse(PlannedBatchUse? a, PlannedBatchUse? b) =>
      a == null
          ? b == null
          : b != null &&
              a.batchId == b.batchId &&
              a.batchRevision == b.batchRevision &&
              a.allocationId == b.allocationId;

  bool _sameSelection(PlannedMeal a, PlannedMeal b) =>
      a.slot.id == b.slot.id &&
      a.recipe == b.recipe &&
      a.portions == b.portions &&
      _sameBatchUse(a.batchUse, b.batchUse);

  String _selectionKey(PlannedMeal meal) => [
        meal.recipe.id,
        '${meal.recipe.revision}',
        jsonEncode(meal.portions.toJson()),
        meal.batchUse?.batchId ?? '',
        '${meal.batchUse?.batchRevision ?? ''}',
        meal.batchUse?.allocationId ?? ''
      ].join('|');

  String _planSignature(List<PlannedMeal> meals) => jsonEncode([
        for (final meal in meals)
          {
            'slot': meal.slot.id,
            'date': meal.slot.date,
            'recipe': meal.recipe.id,
            'revision': meal.recipe.revision,
            'portions': meal.portions.toJson(),
            'batch': meal.batchUse == null
                ? null
                : {
                    'batchId': meal.batchUse!.batchId,
                    'batchRevision': meal.batchUse!.batchRevision,
                    'allocationId': meal.batchUse!.allocationId,
                  },
          }
      ]);

  Exact _targetProximity(List<PlannedMeal> meals, PlannerContext c) {
    if (c.constraints.isEmpty && c.targetGoals.isEmpty) return Exact.zero;
    var total = Exact.zero;
    for (final day in c.slots.map((s) => s.date).toSet()) {
      final dayMeals = meals.where((m) => m.slot.date == day).toList();
      for (final goal in c.targetGoals.entries) {
        var sum = Exact.zero;
        var complete = dayMeals.isNotEmpty;
        for (final meal in dayMeals) {
          final nutrient = meal.nutrients[goal.key];
          if (nutrient == null || !nutrient.isComplete ||
              nutrient.includesEstimate) {
            complete = false;
            break;
          }
          sum += nutrient.exactValue;
        }
        if (!complete) {
          total += Exact.one;
        } else {
          final difference = sum - goal.value;
          total += (difference.compareTo(Exact.zero) < 0
              ? Exact.zero - difference : difference) / goal.value;
        }
      }
      for (final bound in c.constraints) {
        var sum = Exact.zero;
        var complete = dayMeals.isNotEmpty;
        for (final meal in dayMeals) {
          if (!meal.recipe.ingredientsResolved) {
            complete = false;
            break;
          }
          final nutrient = meal.nutrients[bound.nutrient];
          if (nutrient == null ||
              !nutrient.isComplete ||
              nutrient.includesEstimate) {
            complete = false;
            break;
          }
          sum += nutrient.exactValue;
        }
        if (!complete) continue;
        final deviation = sum.compareTo(bound.center) >= 0
            ? sum - bound.center
            : bound.center - sum;
        final denominator = bound.span.positive
            ? bound.span
            : (bound.center.positive ? bound.center : Exact.one);
        total += deviation / denominator;
      }
    }
    return total;
  }

  Exact _dataCompleteness(List<PlannedMeal> meals) {
    var missing = 0;
    var cells = 0;
    for (final meal in meals) {
      if (!meal.recipe.ingredientsResolved) {
        missing += NutrientKey.values.length;
        cells += NutrientKey.values.length;
        continue;
      }
      final nutrients = meal.nutrients;
      for (final key in NutrientKey.values) {
        cells++;
        final nutrient = nutrients[key];
        if (nutrient == null ||
            !nutrient.isComplete ||
            nutrient.includesEstimate) {
          missing++;
        }
      }
    }
    return cells == 0
        ? Exact.zero
        : Exact.parse('$missing') / Exact.parse('$cells');
  }

  /// Relative guidance. The explicit [PlannerContext.guidanceNutrients] set and
  /// the experimental condition directives are scored separately and added, so
  /// neither can reclassify the other's missing values as zero.
  Exact _guidanceScore(List<PlannedMeal> meals, PlannerContext c) =>
      _explicitGuidanceScore(meals, c) +
      _conditionGuidanceScore(meals, c);

  Exact _explicitGuidanceScore(List<PlannedMeal> meals, PlannerContext c) {
    if (c.guidanceNutrients.isEmpty) return Exact.zero;
    final keys = c.guidanceNutrients.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    var cells = 0;
    var missing = 0;
    var normalized = Exact.zero;
    for (final meal in meals) {
      if (!meal.recipe.ingredientsResolved) {
        cells += keys.length;
        missing += keys.length;
        continue;
      }
      final nutrients = meal.nutrients;
      for (final key in keys) {
        cells++;
        final nutrient = nutrients[key];
        if (nutrient == null ||
            !nutrient.isComplete ||
            nutrient.includesEstimate) {
          missing++;
          continue;
        }
        final value = nutrient.exactValue;
        normalized += value / (value + Exact.one);
      }
    }
    if (cells == 0) return Exact.zero;
    // Missing guidance cells dominate, then the bounded relative amount.
    return Exact.parse('$missing') *
            Exact.parse('${cells + 1}') +
        normalized;
  }

  /// Stable de-duplicated condition directives for ranking.
  ///
  /// Two rules on the same nutrient with the same direction count once; a
  /// nutrient with contradictory directions is excluded rather than resolved
  /// arbitrarily.
  List<ConditionGuidanceDirective> _conditionDirectives(PlannerContext c) {
    final assessment = c.conditionGuidance;
    if (assessment == null) return const [];
    final byNutrient = <NutrientKey, ConditionGuidanceDirective>{};
    final conflicting = <NutrientKey>{};
    for (final directive in assessment.directives) {
      final prior = byNutrient[directive.nutrient];
      if (prior == null) {
        byNutrient[directive.nutrient] = directive;
      } else if (prior.direction != directive.direction) {
        conflicting.add(directive.nutrient);
      }
    }
    final keys = byNutrient.keys
        .where((key) => !conflicting.contains(key))
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return [for (final key in keys) byNutrient[key]!];
  }

  /// Bounded value in `[0, 1]`, lower is better.
  ///
  /// Unknown, incomplete or estimated data scores [Exact.one], which no known
  /// lower-direction value reaches. Unknown is therefore never ranked as
  /// healthier than a known value, and no nutrient amount is synthesized.
  Exact _conditionDirectiveValue(
      PlannedMeal meal, ConditionGuidanceDirective directive) {
    if (!meal.recipe.ingredientsResolved) return Exact.one;
    final nutrient = meal.nutrients[directive.nutrient];
    if (nutrient == null ||
        !nutrient.isComplete ||
        nutrient.includesEstimate ||
        nutrient.knownEntries == 0) {
      return Exact.one;
    }
    final value = nutrient.exactValue;
    final denominator = value + Exact.one;
    return directive.direction == GuidanceDirection.lower
        ? value / denominator
        : Exact.one / denominator;
  }

  Exact _conditionGuidanceScore(List<PlannedMeal> meals, PlannerContext c) {
    final directives = _conditionDirectives(c);
    if (directives.isEmpty) return Exact.zero;
    var score = Exact.zero;
    for (final meal in meals) {
      for (final directive in directives) {
        score += _conditionDirectiveValue(meal, directive);
      }
    }
    return score;
  }

  Exact _cookingEffort(List<PlannedMeal> meals) => Exact.parse(
      '${meals.fold<int>(0, (total, meal) => total + meal.recipe.minutes)}');

  Exact _ingredientReuse(List<PlannedMeal> meals) {
    final foods = <String>{};
    var lines = 0;
    for (final meal in meals) {
      for (final ingredient in meal.recipe.ingredients) {
        foods.add(ingredient.food.id);
        lines++;
      }
    }
    return lines == 0
        ? Exact.zero
        : Exact.parse('${foods.length}') / Exact.parse('$lines');
  }

  Exact _variety(List<PlannedMeal> meals) {
    if (meals.isEmpty) return Exact.zero;
    final recipeIds = meals.map((m) => m.recipe.id).toSet().length;
    return Exact.parse('${meals.length - recipeIds}') /
        Exact.parse('${meals.length}');
  }

  /// Share of planned meals whose stable recipe id is not explicitly
  /// preferred. Exact rational in `[0, 1]`, lower is better; zero when every
  /// meal is preferred or [PlannerContext.preferredRecipeIds] is empty. Only
  /// selections that already passed hard validation are scored, so preference
  /// cannot make an ineligible recipe, stale revision or pinned conflict
  /// feasible.
  Exact _preferenceScore(List<PlannedMeal> meals, PlannerContext c) {
    if (meals.isEmpty || c.preferredRecipeIds.isEmpty) return Exact.zero;
    var notPreferred = 0;
    for (final meal in meals) {
      if (!c.preferredRecipeIds.contains(meal.recipe.id)) notPreferred++;
    }
    return Exact.parse('$notPreferred') / Exact.parse('${meals.length}');
  }

  _EvaluatedPlan _evaluate(
      List<PlannedMeal> meals, PlannerContext c, List<PlannedMeal> existing) {
    var preserved = 0;
    for (final meal in meals) {
      final original =
          existing.where((m) => m.slot.id == meal.slot.id).firstOrNull;
      if (original != null && _sameSelection(original, meal)) preserved++;
    }
    final scores = <PlannerObjective, Exact>{};
    for (final objective in c.objectives) {
      scores[objective] = switch (objective) {
        PlannerObjective.practicalPreference => meals.fold(Exact.zero,
            (sum, meal) => sum + Exact.parse(
                '${c.recipePreferenceRanks[meal.recipe.id] ?? 0}')),
        PlannerObjective.targetProximity => _targetProximity(meals, c),
        PlannerObjective.dataCompleteness => _dataCompleteness(meals),
        PlannerObjective.guidance => _guidanceScore(meals, c),
        PlannerObjective.recipePreference => _preferenceScore(meals, c),
        PlannerObjective.cookingEffort => _cookingEffort(meals),
        PlannerObjective.ingredientReuse => _ingredientReuse(meals),
        PlannerObjective.variety => _variety(meals),
      };
    }
    return _EvaluatedPlan(
        List.unmodifiable(meals),
        _planSignature(meals),
        preserved,
        Map<PlannerObjective, Exact>.unmodifiable(scores));
  }

  int _compareEvaluated(
      _EvaluatedPlan a, _EvaluatedPlan b, PlannerContext c) {
    if (a.preserved != b.preserved) {
      return b.preserved.compareTo(a.preserved);
    }
    for (final objective in c.objectives) {
      final left = a.scores[objective];
      final right = b.scores[objective];
      if (left == null || right == null) continue;
      final order = left.compareTo(right);
      if (order != 0) return order;
    }
    return a.signature.compareTo(b.signature);
  }

  Exact _choiceScore(PlannedMeal meal, MealSlot slot, PlannerContext c) {
    var score = Exact.zero;
    if (c.objectives.contains(PlannerObjective.practicalPreference)) {
      score += Exact.parse('${c.recipePreferenceRanks[meal.recipe.id] ?? 0}');
    }
    if (c.objectives.contains(PlannerObjective.targetProximity) &&
        c.targetGoals.isNotEmpty) {
      const weights = {'breakfast':25, 'lunch':35, 'dinner':30, 'snack':10};
      final daySlots = c.slots.where((s) => s.date == slot.date);
      final totalWeight = daySlots.fold(0,
          (sum, s) => sum + (weights[s.label] ?? 25));
      final weight = Exact.parse('${weights[slot.label] ?? 25}') /
          Exact.parse('$totalWeight');
      for (final goal in c.targetGoals.entries) {
        final share = goal.value * weight;
        final nutrient = meal.nutrients[goal.key];
        if (nutrient == null || !nutrient.isComplete ||
            nutrient.includesEstimate) {
          score += Exact.one;
        } else {
          final difference = nutrient.exactValue - share;
          score += (difference.compareTo(Exact.zero) < 0
              ? Exact.zero - difference : difference) / share;
        }
      }
    }
    if (c.objectives.contains(PlannerObjective.targetProximity) &&
        c.constraints.isNotEmpty) {
      final slotsInDay = c.slots.where((s) => s.date == slot.date).length;
      for (final bound in c.constraints) {
        final share = bound.center / Exact.parse('$slotsInDay');
        final nutrient = meal.nutrients[bound.nutrient];
        if (nutrient == null ||
            !nutrient.isComplete ||
            nutrient.includesEstimate) {
          score += Exact.one;
          continue;
        }
        final deviation = nutrient.exactValue.compareTo(share) >= 0
            ? nutrient.exactValue - share
            : share - nutrient.exactValue;
        final denominator = bound.span.positive
            ? bound.span
            : (share.positive ? share : Exact.one);
        score += deviation / denominator;
      }
    }
    // Condition guidance only orders the bounded search; the staged objective
    // comparison remains the authority on the selected plan.
    if (c.objectives.contains(PlannerObjective.guidance)) {
      for (final directive in _conditionDirectives(c)) {
        score += _conditionDirectiveValue(meal, directive);
      }
    }
    return score;
  }

  List<PlannedMeal> _choicesFor(MealSlot slot, List<PlannedMeal> current,
      PlannerContext c, List<RecipeVersion> rotated, List<PlannedMeal> existing,
      Map<String, Exact> scoreCache) {
    final original =
        existing.where((m) => m.slot.id == slot.id).firstOrNull;
    // Choice scoring depends on a day's labels, not its date or slot IDs.
    // Reuse exact scores across equivalent days in a weekly schedule.
    final dayLabels = c.slots
        .where((candidate) => candidate.date == slot.date)
        .map((candidate) => candidate.label)
        .toList();
    final scorePrefix = jsonEncode([slot.label, dayLabels]);
    final choices = <PlannedMeal>[];
    final choiceKeys = <String>{};
    void add(PlannedMeal meal) {
      if (choiceKeys.add(_selectionKey(meal))) choices.add(meal);
    }

    if (original != null && original.pinned) {
      add(original);
      return choices;
    }
    if (original != null && _mealDefinitionErrors(original, c).isEmpty) {
      add(original);
    }
    for (final recipe in rotated) {
      final allowed = c.recipeIdsBySlot[slot.id];
      if (allowed != null && !allowed.contains(recipe.id)) continue;
      for (final portion in c.portions) {
        add(PlannedMeal(slot, recipe, portion));
      }
    }
    choices.removeWhere((meal) =>
        c.maximumRepeats != null &&
        current.where((m) => m.recipe.id == meal.recipe.id).length >=
            c.maximumRepeats!);
    final ranked = <_RankedChoice>[
      for (var index = 0; index < choices.length; index++)
        _RankedChoice(
            index,
            choices[index],
            scoreCache.putIfAbsent(
                jsonEncode([scorePrefix, choices[index].recipe.definitionSignature,
                  choices[index].portions.toJson()]),
                () => _choiceScore(choices[index], slot, c)))
    ]..sort((a, b) {
        final aOriginal =
            original != null && _sameSelection(a.meal, original);
        final bOriginal =
            original != null && _sameSelection(b.meal, original);
        if (aOriginal != bOriginal) return aOriginal ? -1 : 1;
        final score = a.score.compareTo(b.score);
        if (score != 0) return score;
        return a.index.compareTo(b.index);
      });
    return [for (final choice in ranked) choice.meal];
  }

  PlannerResult plan(PlannerContext c,
      {List<PlannedMeal> existing = const []}) {
    if (existing.length == c.slots.length &&
        validate(existing, c).isEmpty) {
      return PlannerResult(PlannerStatus.validPlan, existing,
          const ['Original plan retained'],
          quality: _evaluate(existing, c, existing).quality);
    }
    final pinned = existing.where((m) => m.pinned).toList();
    if (pinned.map((m) => m.slot.id).toSet().length != pinned.length ||
        pinned.any((m) =>
            existing.where((other) => other.slot.id == m.slot.id).length !=
            1) ||
        pinned.any((m) =>
            !c.slots.any((s) => s.id == m.slot.id && s.date == m.slot.date))) {
      return PlannerResult(
          PlannerStatus.targetConflict, const [],
          const ['Pinned meal slot is missing or duplicated']);
    }
    final eligible = _eligibleRecipes(c);
    for (final meal in pinned) {
      if (!eligible.contains(meal.recipe)) {
        return PlannerResult(
            PlannerStatus.targetConflict,
            const [],
            [
              'Pinned meal conflicts with an immutable or hard constraint',
              ..._recipeBlockers(meal.recipe, c)
            ]);
      }
    }
    final pinnedBatchErrors = validate(pinned, c)
        .where((e) => e.startsWith('BATCH_') || e == 'DUPLICATE_BATCH_USE')
        .toList();
    if (pinnedBatchErrors.isNotEmpty) {
      return PlannerResult(
          PlannerStatus.targetConflict, const [], pinnedBatchErrors);
    }
    if (c.slots.isNotEmpty && eligible.isEmpty) {
      return PlannerResult(
          PlannerStatus.provenInfeasible, const [],
          _emptyEligibleDiagnostics(c));
    }
    final rotated = [...eligible];
    if (rotated.isNotEmpty) {
      // Stable integer rotation: SDK/platform independent tie-breaking.
      final rotation = c.seed.abs() % rotated.length;
      rotated.addAll(rotated.take(rotation).toList());
      rotated.removeRange(0, rotation);
    }
    // Choice nutrition and ordering do not depend on the search prefix.
    final scoreCache = <String, Exact>{};
    final choicesBySlot = {
      for (final slot in c.slots)
        slot.id: _choicesFor(slot, const [], c, rotated, existing, scoreCache)
    };
    var visited = 0;
    var exhausted = false;
    var missingData = false;
    final missingDetails = <String>{};
    final observedErrors = <String>{};
    _EvaluatedPlan? best;
    // Guided plans compare a bounded sample after finding a valid plan.
    // Continue up to maxNodes if none is found, so early stopping cannot turn
    // an unexplored space into a claim of infeasibility. Legacy objective
    // lists retain their original search behavior.
    final guided = c.objectives.isNotEmpty &&
        c.objectives.first == PlannerObjective.practicalPreference;
    const guidedUsefulNodes = 256;
    var stoppedAfterValid = false;
    // Matching the remaining slots to recipe repeat capacity is a necessary
    // condition for any completion. It accounts for overlapping candidate
    // sets (for example, cold lunches sharing recipes with dinners), rather
    // than merely counting candidates in each slot independently. Portions
    // cannot affect this condition, so check each recipe only once per prefix.
    final slotRecipeIds = guided && c.maximumRepeats != null
        ? [
            for (final slot in c.slots)
              choicesBySlot[slot.id]!.map((meal) => meal.recipe.id).toSet()
          ]
        : <Set<String>>[];
    bool canCompleteRepeats(List<PlannedMeal> current, String chosenId) {
      final limit = c.maximumRepeats!;
      final used = <String, int>{};
      for (final meal in current) {
        used.update(meal.recipe.id, (count) => count + 1, ifAbsent: () => 1);
      }
      used.update(chosenId, (count) => count + 1, ifAbsent: () => 1);
      final assigned = <String, List<int>>{};
      bool assign(int slotIndex, Set<String> seen) {
        for (final recipeId in slotRecipeIds[slotIndex]) {
          if (!seen.add(recipeId)) continue;
          final capacity = limit - (used[recipeId] ?? 0);
          if (capacity <= 0) continue;
          final occupants = assigned.putIfAbsent(recipeId, () => <int>[]);
          if (occupants.length < capacity) {
            occupants.add(slotIndex);
            return true;
          }
          for (var i = 0; i < occupants.length; i++) {
            if (assign(occupants[i], seen)) {
              occupants[i] = slotIndex;
              return true;
            }
          }
        }
        return false;
      }
      for (var i = current.length + 1; i < c.slots.length; i++) {
        if (!assign(i, <String>{})) return false;
      }
      return true;
    }
    void search(List<PlannedMeal> current) {
      if (exhausted || stoppedAfterValid) return;
      // The root prefix counts as a visited node so a zero-work budget still
      // reports exhaustion rather than silently succeeding.
      if (++visited > c.maxNodes) {
        exhausted = true;
        return;
      }
      if (current.length == c.slots.length) {
        final errors = validate(current, c);
        if (errors.isNotEmpty) {
          observedErrors.addAll(errors);
          if (errors.contains('INSUFFICIENT_NUTRIENT_DATA')) {
            missingData = true;
            missingDetails.addAll(_missingNutrientDetails(current, c));
          }
          return;
        }
        final evaluated = _evaluate(current, c, existing);
        final prior = best;
        if (prior == null || _compareEvaluated(evaluated, prior, c) < 0) {
          best = evaluated;
        }
        if (guided && visited >= guidedUsefulNodes) stoppedAfterValid = true;
        return;
      }
      final slot = c.slots[current.length];
      final repeatFeasibility = <String, bool>{};
      for (final meal in choicesBySlot[slot.id]!) {
        if (c.maximumRepeats != null &&
            current.where((m) => m.recipe.id == meal.recipe.id).length >=
                c.maximumRepeats!) continue;
        if (guided && c.maximumRepeats != null &&
            !repeatFeasibility.putIfAbsent(meal.recipe.id,
                () => canCompleteRepeats(current, meal.recipe.id))) {
          continue;
        }
        search([...current, meal]);
        if (exhausted || stoppedAfterValid) return;
      }
    }

    search(const []);
    final bestPlan = best;
    if (bestPlan != null) {
      return PlannerResult(PlannerStatus.validPlan, bestPlan.meals, [
        'Deterministic bounded search over the declared recipe/portion space',
        if (exhausted || stoppedAfterValid)
          'Bounded search stopped before exhaustive enumeration; no global optimality claim'
        else
          'Declared finite space exhaustively compared by staged objectives',
      ], visited: visited, quality: bestPlan.quality);
    }
    if (exhausted && missingData) {
      return PlannerResult(
          PlannerStatus.insufficientData,
          const [],
          ['Binding nutrient data missing', ...missingDetails.take(40)],
          visited: visited);
    }
    if (exhausted) {
      final observed = observedErrors.toList()..sort();
      return PlannerResult(
          PlannerStatus.searchExhausted,
          const [],
          [
            'Search budget reached; constraints were not relaxed',
            ...observed
          ],
          visited: visited);
    }
    if (missingData) {
      return PlannerResult(
          PlannerStatus.insufficientData,
          const [],
          ['Binding nutrient data missing', ...missingDetails.take(40)],
          visited: visited);
    }
    final observed = observedErrors.toList()..sort();
    return PlannerResult(
        PlannerStatus.provenInfeasible,
        const [],
        [
          'ENUMERATED_FINITE_SPACE',
          if (guided && c.maximumRepeats != null)
            'All declared recipe/portion combinations were validated or ruled out by hard constraints'
          else
            'All declared recipe/portion combinations were validated',
          ...observed,
          'No relaxation was applied'
        ],
        visited: visited);
  }

  /// Repairs a plan when feasible and otherwise surfaces user-confirmable
  /// non-medical options. A relaxation is never installed automatically.
  PlannerResult repair(PlannerContext c, List<PlannedMeal> existing) {
    final result = plan(c, existing: existing);
    if (result.status == PlannerStatus.validPlan ||
        result.status == PlannerStatus.insufficientData) {
      return result;
    }
    final options =
        proposeRelaxations(c, failure: result, existing: existing);
    if (options.isEmpty) return result;
    return PlannerResult(
        PlannerStatus.proposedRelaxation,
        const [],
        [
          ...result.diagnostics,
          'No relaxation is applied automatically; explicit confirmation is required'
        ],
        visited: result.visited,
        relaxations: options,
        originalStatus: result.status);
  }

  /// Non-medical, data-derived relaxation candidates. Order is deterministic
  /// and never includes strict exclusions, diet restrictions, allergen status,
  /// current food identity or confirmed batch stock.
  List<PlannerRelaxation> proposeRelaxations(PlannerContext c,
      {PlannerResult? failure, List<PlannedMeal> existing = const []}) {
    final result = failure ?? plan(c, existing: existing);
    if (result.status == PlannerStatus.validPlan) return const [];
    if (result.status == PlannerStatus.insufficientData) return const [];
    if (result.status == PlannerStatus.proposedRelaxation) {
      return result.relaxations;
    }
    final diagnostics = result.diagnostics.toSet();
    const immutable = {
      'EXCLUSION_CONFLICT',
      'ALLERGEN_STATUS_UNKNOWN',
      'DIET_CONFLICT',
      'INGREDIENT_UNRESOLVED',
      'INGREDIENT_STALE',
      'INGREDIENT_UNAVAILABLE',
    };
    if (result.status == PlannerStatus.targetConflict &&
        diagnostics.any((d) => d.startsWith('BATCH_'))) {
      return const [];
    }
    if (result.status == PlannerStatus.targetConflict &&
        result.diagnostics
            .contains('Pinned meal slot is missing or duplicated')) {
      return const [];
    }
    final pinned = existing.where((m) => m.pinned).toList();
    if (result.status == PlannerStatus.targetConflict &&
        pinned.any(
            (m) => _recipeBlockers(m.recipe, c).any(immutable.contains))) {
      return const [];
    }
    final searchFailure = result.status == PlannerStatus.provenInfeasible ||
        result.status == PlannerStatus.searchExhausted;
    final eligible = _eligibleRecipes(c);
    final options = <PlannerRelaxation>[];
    final base = c.revision;
    void add(PlannerRelaxation relaxation) {
      if (!options.any((o) => o.signature == relaxation.signature)) {
        options.add(relaxation);
      }
    }

    final timeOnly = c.recipes
        .where((recipe) {
          final blockers = _recipeBlockers(recipe, c);
          return blockers.contains('COOKING_TIME') &&
              blockers.every((reason) => reason == 'COOKING_TIME');
        })
        .toList()
      ..sort((a, b) {
        final order = a.id.compareTo(b.id);
        return order == 0 ? a.revision.compareTo(b.revision) : order;
      });
    if (c.maximumMinutes != null && timeOnly.isNotEmpty) {
      final minimal =
          timeOnly.map((r) => r.minutes).reduce((a, b) => a < b ? a : b);
      if (minimal > c.maximumMinutes!) {
        add(PlannerRelaxation(
            kind: PlannerRelaxationKind.maximumMinutes,
            reason: 'NO_RECIPE_WITHIN_TIME',
            baseRevision: base,
            maximumMinutes: minimal));
      }
      add(PlannerRelaxation(
          kind: PlannerRelaxationKind.maximumMinutes,
          reason: 'NO_RECIPE_WITHIN_TIME',
          baseRevision: base,
          maximumMinutes: null));
    }
    if (c.maximumRepeats != null) {
      if (eligible.isNotEmpty &&
          c.slots.isNotEmpty &&
          eligible.length * c.maximumRepeats! < c.slots.length) {
        final needed =
            (c.slots.length + eligible.length - 1) ~/ eligible.length;
        if (needed > c.maximumRepeats!) {
          add(PlannerRelaxation(
              kind: PlannerRelaxationKind.maximumRepeats,
              reason: 'REPEAT_LIMIT_BLOCKS_SLOTS',
              baseRevision: base,
              maximumRepeats: needed));
        }
      }
      if (searchFailure && eligible.isNotEmpty) {
        add(PlannerRelaxation(
            kind: PlannerRelaxationKind.maximumRepeats,
            reason: 'REPEAT_LIMIT_BLOCKS_SLOTS',
            baseRevision: base,
            maximumRepeats: null));
      }
    }
    if (searchFailure && eligible.isNotEmpty && c.constraints.isNotEmpty) {
      for (final bound in c.constraints) {
        add(PlannerRelaxation(
            kind: PlannerRelaxationKind.numericConstraint,
            reason: 'NUMERIC_RANGE_UNSATISFIED',
            baseRevision: base,
            constraintNutrient: bound.nutrient));
      }
    }
    for (final meal in pinned) {
      final blockers = _recipeBlockers(meal.recipe, c);
      if (blockers.any(immutable.contains)) continue;
      if (blockers.contains('COOKING_TIME')) {
        add(PlannerRelaxation(
            kind: PlannerRelaxationKind.pin,
            reason: 'PIN_TIME_CONFLICT',
            baseRevision: base,
            slotId: meal.slot.id));
      }
      if (!c.portions.contains(meal.portions)) {
        final portions = [...c.portions, meal.portions]
          ..sort((a, b) => a.compareTo(b));
        add(PlannerRelaxation(
            kind: PlannerRelaxationKind.portions,
            reason: 'PIN_PORTION_OUTSIDE_OPTIONS',
            baseRevision: base,
            portions: portions));
      }
      if (c.maximumRepeats != null &&
          pinned
                  .where((m) => m.recipe.id == meal.recipe.id)
                  .length >
              c.maximumRepeats!) {
        add(PlannerRelaxation(
            kind: PlannerRelaxationKind.pin,
            reason: 'PIN_REPEAT_CONFLICT',
            baseRevision: base,
            slotId: meal.slot.id));
      }
      if (searchFailure && blockers.isEmpty && c.constraints.isNotEmpty) {
        add(PlannerRelaxation(
            kind: PlannerRelaxationKind.pin,
            reason: 'PIN_NUMERIC_CONFLICT',
            baseRevision: base,
            slotId: meal.slot.id));
      }
      if (searchFailure && blockers.isEmpty) {
        add(PlannerRelaxation(
            kind: PlannerRelaxationKind.pin,
            reason: 'PIN_LIMITS_SEARCH',
            baseRevision: base,
            slotId: meal.slot.id));
      }
    }
    return options;
  }

  /// Applies one explicitly confirmed relaxation and re-plans.
  ///
  /// The returned context is a new revision and must be persisted by the caller.
  /// Medical exclusions, diet tags, allergen status and catalogue identity are
  /// not representable as [PlannerRelaxation]s and cannot be changed here.
  PlannerAcceptance acceptRelaxation(
      PlannerContext c, PlannerRelaxation change,
      {required bool confirmed,
      required int expectedRevision,
      List<PlannedMeal> existing = const []}) {
    if (!confirmed) throw StateError('CONFIRMATION_REQUIRED');
    if (expectedRevision != c.revision ||
        change.baseRevision != c.revision) {
      throw StateError('STALE_PLAN_REVISION');
    }
    var maximumMinutes = c.maximumMinutes;
    var maximumRepeats = c.maximumRepeats;
    var portions = c.portions;
    final constraints = [...c.constraints];
    var meals = existing;
    switch (change.kind) {
      case PlannerRelaxationKind.maximumMinutes:
        if (change.maximumMinutes == maximumMinutes) {
          throw StateError('INVALID_RELAXATION');
        }
        maximumMinutes = change.maximumMinutes;
        break;
      case PlannerRelaxationKind.maximumRepeats:
        if (change.maximumRepeats == maximumRepeats) {
          throw StateError('INVALID_RELAXATION');
        }
        maximumRepeats = change.maximumRepeats;
        break;
      case PlannerRelaxationKind.portions:
        final next = change.portions!;
        if (next.length == portions.length &&
            next.asMap().entries.every((e) => e.value == portions[e.key])) {
          throw StateError('INVALID_RELAXATION');
        }
        portions = List<Exact>.unmodifiable(next);
        break;
      case PlannerRelaxationKind.numericConstraint:
        final nutrient = change.constraintNutrient!;
        final priorLength = constraints.length;
        constraints.removeWhere((bound) => bound.nutrient == nutrient);
        if (change.constraint == null) {
          if (constraints.length == priorLength) {
            throw StateError('INVALID_RELAXATION');
          }
        } else {
          constraints.add(change.constraint!);
        }
        break;
      case PlannerRelaxationKind.pin:
        final index = meals.indexWhere(
            (meal) => meal.slot.id == change.slotId && meal.pinned);
        if (index < 0) throw StateError('INVALID_RELAXATION');
        final meal = meals[index];
        meals = [
          for (var i = 0; i < meals.length; i++)
            if (i == index)
              PlannedMeal(meal.slot, meal.recipe, meal.portions,
                  batchUse: meal.batchUse)
            else
              meals[i]
        ];
        break;
    }
    final revised = PlannerContext(
        slots: c.slots,
        recipes: c.recipes,
        seed: c.seed,
        catalogueVersion: c.catalogueVersion,
        policyVersion: c.policyVersion,
        maxNodes: c.maxNodes,
        maximumMinutes: maximumMinutes,
        maximumRepeats: maximumRepeats,
        strictExclusions: c.strictExclusions,
        dietaryTags: c.dietaryTags,
        constraints: constraints,
        batches: c.batches,
        portions: portions,
        revision: c.revision + 1,
        acceptedRelaxations: [...c.acceptedRelaxations, change],
        currentFoods: c.currentFoods,
        unavailableFoodIds: c.unavailableFoodIds,
        objectives: c.objectives,
        guidanceNutrients: c.guidanceNutrients,
        preferredRecipeIds: c.preferredRecipeIds,
        recipeIdsBySlot: c.recipeIdsBySlot,
        targetGoals: c.targetGoals,
        recipePreferenceRanks: c.recipePreferenceRanks,
        conditionGuidance: c.conditionGuidance);
    return PlannerAcceptance(revised, repair(revised, meals));
  }
}

/// Evaluates condition guidance over concrete planned meals.
///
/// This is a report, not a safety or adequacy verdict: it states which relative
/// rules had usable nutrient data and repeats the source-linked limits. A
/// missing value is never replaced by zero.
ConditionGuidanceReport conditionGuidanceReportFor(
    ConditionGuidanceAssessment assessment, List<PlannedMeal> meals) =>
    ConditionGuidanceReport.evaluate(assessment, [
      for (final meal in meals)
        ConditionGuidanceMealData(
          ingredientsResolved: meal.recipe.ingredientsResolved,
          nutrients: meal.nutrients,
        )
    ]);

final class GroceryLine {
  const GroceryLine(this.foodId, this.name, this.grams, this.preparation);
  final String foodId, name;
  final Exact grams;
  final Preparation preparation;

  @override
  bool operator ==(Object other) =>
      other is GroceryLine &&
      other.foodId == foodId &&
      other.name == name &&
      other.grams == grams &&
      other.preparation == preparation;
  @override
  int get hashCode => Object.hash(foodId, name, grams, preparation);
}

/// Aggregates ingredients in purchase-compatible mass units.
///
/// Meals backed by existing cooked stock are excluded by default: their
/// ingredients were already purchased, and a plan is not intake. Unresolved
/// ingredients throw instead of producing a fabricated or "as needed" line.
/// Manual shopping entries, checkmarks and edits are outside this function.
List<GroceryLine> groceriesFor(List<PlannedMeal> meals,
    {bool includeStockedMeals = false}) {
  final lines = <String, GroceryLine>{};
  for (final meal in meals) {
    if (!includeStockedMeals && meal.batchUse != null) continue;
    for (final ingredient in meal.recipe.ingredients) {
      if (ingredient.food.id.isEmpty || !_hasMassBasis(ingredient.food)) {
        throw StateError('INGREDIENT_UNRESOLVED');
      }
      final key = '${ingredient.food.id}|${ingredient.food.preparation.name}';
      final quantity = ingredient.grams * meal.portions / meal.recipe.servings;
      final previous = lines[key];
      lines[key] = GroceryLine(
          ingredient.food.id,
          ingredient.food.name,
          (previous?.grams ?? Exact.zero) + quantity,
          ingredient.food.preparation);
    }
  }
  return lines.values.toList()
    ..sort((a, b) {
      final name = a.name.compareTo(b.name);
      if (name != 0) return name;
      final id = a.foodId.compareTo(b.foodId);
      return id != 0 ? id : a.preparation.name.compareTo(b.preparation.name);
    });
}
