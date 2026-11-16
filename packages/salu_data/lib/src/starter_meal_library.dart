/// Idempotent installation of Salu's authored starter-meal library.
///
/// Nutrition comes only from the bundled INSA catalogue rows resolved by exact
/// id (`insa-bdca:<code>`). This library stores:
/// * `recipe` documents through [recipeSnapshot] (frozen ingredient snapshots),
/// * `meal-content-v1` documents (recipe-level composition metadata:
///   locale titles/descriptions/instructions, meal labels, cold-suitability,
///   qualitative cost tier, diet tags), and
/// * one receipt document in `preferences` (`starter-meals-v1`) binding the
///   asset version, its digest and the installed recipe signatures.
///
/// Ingredient allergen declarations are Salu's conventional composition
/// assessment (`salu-starter-v1`), never an INSA claim: the imported
/// [Food.allergens] stay null/unknown and are never rewritten. Declared
/// effective allergens (see [RecipeIngredient.effectiveAllergens]) are what
/// make exclusion-aware planning possible over unknown-status INSA rows.
///
/// Installation is atomic: every definition is resolved and validated before
/// any write, so a missing id or invalid definition aborts the whole library
/// transaction with [StarterMealLibraryException], retaining the prior library
/// and all user recipes/history. No partial installation, fuzzy substitution
/// or development-fixture fallback is attempted.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:salu_core/salu_core.dart';

import 'database/app_database.dart';
import 'snapshot_codec.dart';
import 'workspace_store.dart';

/// Caller-facing failure for starter-library installation.
final class StarterMealLibraryException implements Exception {
  const StarterMealLibraryException(this.code, this.message, [this.cause]);
  final String code;
  final String message;
  final Object? cause;
  @override
  String toString() => message;
}

/// One localized string.
typedef StarterLocalizedText = ({String en, String ptPT});

/// One asset ingredient: exact INSA code plus editable grams and declaration.
final class StarterMealIngredientDef {
  const StarterMealIngredientDef({
    required this.sourceCode,
    required this.grams,
    this.allergens = const <String>{},
  });
  final String sourceCode;
  final String grams;
  final Set<String> allergens;
}

/// One authored meal definition (decoded asset row).
final class StarterMealDef {
  const StarterMealDef({
    required this.id,
    required this.revision,
    required this.titleEn,
    required this.titlePtPT,
    required this.descriptionEn,
    required this.descriptionPtPT,
    required this.instructionsEn,
    required this.instructionsPtPT,
    required this.mealLabels,
    required this.minutes,
    required this.ingredients,
    required this.dietaryTags,
    required this.coldSuitable,
    required this.costTier,
    this.grainComposition,
  });
  final String id;
  final int revision;
  final String titleEn, titlePtPT, descriptionEn, descriptionPtPT;
  final List<String> instructionsEn, instructionsPtPT;
  final List<String> mealLabels;
  final int minutes;
  final List<StarterMealIngredientDef> ingredients;
  final Set<String> dietaryTags;
  final bool coldSuitable;
  final String costTier; // 'lowerCost' | 'standard'
  /// Source-verified authored grain class: 'wholeGrain' or 'refinedGrain'.
  /// Absent when the recipe is grain-free or not classified; absence is never
  /// treated as refined.
  final String? grainComposition;
}

/// Parsed starter-meal asset.
final class StarterMealAsset {
  const StarterMealAsset({
    required this.assetVersion,
    required this.meals,
    required this.jsonBytes,
  });
  final String assetVersion;
  final List<StarterMealDef> meals;
  final List<int> jsonBytes;

  static const String declarationSource = 'salu-starter-v1';
  static const int contentSchemaVersion = 1;
  static const String receiptCollection = 'preferences';
  static const String receiptId = 'starter-meals-v1';
  static const String ingredientAllergenDeclarationNote =
      'Salu starter-meal composition assessment (salu-starter-v1); the INSA '
      'workbook publishes no allergens and Food allergens remain unknown.';
  static const List<String> allowedMealLabels = [
    'breakfast',
    'lunch',
    'snack',
    'dinner'
  ];
  static const Set<String> allowedCostTiers = {'lowerCost', 'standard'};
  static const Set<String> allowedGrainCompositions = {
    'wholeGrain',
    'refinedGrain'
  };
  static const Set<String> allowedDietTags = {
    'vegan',
    'vegetarian',
    'pescatarian'
  };
}

/// A built recipe plus its content-document payload.
final class StarterMealInstallation {
  const StarterMealInstallation({
    required this.recipe,
    required this.contentPayload,
  });
  final RecipeVersion recipe;
  final Map<String, Object?> contentPayload;
}

enum StarterMealLibraryStatus { installed, alreadyInstalled, repaired }

final class StarterMealLibraryProvision {
  const StarterMealLibraryProvision({
    required this.status,
    required this.assetVersion,
    required this.digest,
    required this.recipeCount,
    required this.recipeRevision,
  });
  final StarterMealLibraryStatus status;
  final String assetVersion;
  final String digest;
  final int recipeCount;
  final int recipeRevision;
}

/// Decodes and strictly validates a starter-meals JSON asset.
///
/// The asset is a JSON object `{assetVersion: <nonempty>, meals: [...]}`.
/// Any item requires a stable `starter:<slug>` id, revision 1, EN + pt-PT
/// title/description/instructions, 1+ valid unique meal labels, positive
/// minutes, 1+ ingredients with positive gram strings, valid diet tags,
/// cold-suitability flag and a `lowerCost|standard` cost tier.
/// `grainComposition` (`wholeGrain`/`refinedGrain`) is authored composition
/// metadata; absence means grain-free or not classified. Any error
/// throws [FormatException]; callers map it to a repair message.
StarterMealAsset decodeStarterMealAsset(List<int> jsonBytes) {
  final decoded = jsonDecode(utf8.decode(jsonBytes));
  if (decoded is! Map) {
    throw const FormatException('Starter meal asset must be an object');
  }
  final root = Map<String, Object?>.from(decoded);
  final version = root['assetVersion'];
  if (version is! String || version.isEmpty) {
    throw const FormatException('Starter meal asset requires assetVersion');
  }
  final rawMeals = root['meals'];
  if (rawMeals is! List || rawMeals.isEmpty) {
    throw const FormatException('Starter meal asset requires meals');
  }
  final meals = <StarterMealDef>[];
  final seenIds = <String>{};
  for (final raw in rawMeals) {
    meals.add(_decodeMeal(raw, seenIds));
  }
  return StarterMealAsset(
    assetVersion: version,
    meals: List.unmodifiable(meals),
    jsonBytes: List.unmodifiable(jsonBytes),
  );
}

StarterMealDef _decodeMeal(Object? raw, Set<String> seenIds) {
  if (raw is! Map) {
    throw const FormatException('Starter meal must be an object');
  }
  final meal = Map<String, Object?>.from(raw);
  String text(String key) {
    final value = meal[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Starter meal requires $key');
    }
    return value;
  }

  String localized(String mapKey, String locale) {
    final map = meal[mapKey];
    if (map is! Map) {
      throw FormatException('Starter meal requires $mapKey');
    }
    final value = map[locale];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Starter meal requires $mapKey.$locale');
    }
    return value;
  }

  List<String> steps(String locale) {
    final map = meal['instructions'];
    if (map is! Map) {
      throw const FormatException('Starter meal requires instructions');
    }
    final value = map[locale];
    if (value is! List ||
        value.isEmpty ||
        value.any((s) => s is! String || s.trim().isEmpty)) {
      throw FormatException('Starter meal requires instructions.$locale');
    }
    return value.cast<String>();
  }

  final id = text('id');
  if (!id.startsWith('starter:') || id == 'starter:' ||
      !seenIds.add(id)) {
    throw FormatException('Starter meal has invalid/duplicate id: $id');
  }
  final revision = meal['revision'];
  if (revision is! int || revision < 1) {
    throw const FormatException('Starter meal requires revision >= 1');
  }
  final labelsRaw = meal['mealLabels'];
  if (labelsRaw is! List ||
      labelsRaw.isEmpty ||
      labelsRaw.any((l) => l is! String) ||
      labelsRaw.toSet().length != labelsRaw.length ||
      !labelsRaw
          .every((l) => StarterMealAsset.allowedMealLabels.contains(l))) {
    throw FormatException('Starter meal $id requires valid mealLabels');
  }
  final minutes = meal['minutes'];
  if (minutes is! int || minutes <= 0) {
    throw FormatException('Starter meal $id requires positive minutes');
  }
  final coldSuitable = meal['coldSuitable'];
  if (coldSuitable is! bool) {
    throw FormatException('Starter meal $id requires coldSuitable');
  }
  final costTier = meal['costTier'];
  if (costTier is! String ||
      !StarterMealAsset.allowedCostTiers.contains(costTier)) {
    throw FormatException('Starter meal $id requires valid costTier');
  }
  final grainComposition = meal['grainComposition'];
  if (grainComposition != null &&
      (grainComposition is! String ||
          !StarterMealAsset.allowedGrainCompositions.contains(
              grainComposition))) {
    throw FormatException('Starter meal $id has invalid grainComposition');
  }
  final tagsRaw = meal['dietaryTags'];
  if (tagsRaw is! List ||
      tagsRaw.any((t) => t is! String) ||
      !tagsRaw
          .every((t) => StarterMealAsset.allowedDietTags.contains(t))) {
    throw FormatException('Starter meal $id requires valid dietaryTags');
  }
  final servings = meal['servings'];
  if (servings != '1') {
    throw FormatException('Starter meal $id requires servings "1"');
  }
  final rawIngredients = meal['ingredients'];
  if (rawIngredients is! List || rawIngredients.isEmpty) {
    throw FormatException('Starter meal $id requires ingredients');
  }
  final ingredients = <StarterMealIngredientDef>[];
  for (final rawIngredient in rawIngredients) {
    if (rawIngredient is! Map) {
      throw FormatException('Starter meal $id ingredient must be an object');
    }
    final ing = Map<String, Object?>.from(rawIngredient);
    String? codeValue;
    final sourceFoodIdValue = ing['sourceFoodId'];
    if (sourceFoodIdValue is String &&
        sourceFoodIdValue.startsWith('insa-bdca:')) {
      codeValue = sourceFoodIdValue.substring('insa-bdca:'.length);
    } else {
      final code = ing['sourceCode'] ?? ing['code'];
      codeValue = code is String ? code : null;
    }
    if (codeValue == null || codeValue.trim().isEmpty) {
      throw FormatException('Starter meal $id ingredient requires sourceCode');
    }
    final grams = ing['grams'];
    if (grams is! String) {
      throw FormatException('Starter meal $id ingredient requires grams');
    }
    final amount = Exact.parse(grams);
    if (!amount.positive) {
      throw FormatException('Starter meal $id ingredient grams must be positive');
    }
    final allergensRaw = ing['allergens'];
    Set<String> allergens = const {};
    if (allergensRaw != null) {
      if (allergensRaw is! List ||
          allergensRaw.any((a) => a is! String)) {
        throw FormatException(
            'Starter meal $id ingredient requires allergens list');
      }
      allergens = allergensRaw.cast<String>().toSet();
    }
    final declarationSource = ing['declarationSource'];
    if (declarationSource != null &&
        declarationSource != StarterMealAsset.declarationSource) {
      throw FormatException(
          'Starter meal $id ingredient has unknown declarationSource');
    }
    final sourceFoodId = ing['sourceFoodId'];
    if (sourceFoodId != null &&
        sourceFoodId != 'insa-bdca:$codeValue') {
      throw FormatException(
          'Starter meal $id ingredient sourceFoodId mismatch');
    }
    ingredients.add(StarterMealIngredientDef(
      sourceCode: codeValue,
      grams: grams,
      allergens: allergens,
    ));
  }

  return StarterMealDef(
    id: id,
    revision: revision,
    titleEn: localized('titles', 'en'),
    titlePtPT: localized('titles', 'pt-PT'),
    descriptionEn: localized('descriptions', 'en'),
    descriptionPtPT: localized('descriptions', 'pt-PT'),
    instructionsEn: steps('en'),
    instructionsPtPT: steps('pt-PT'),
    mealLabels: labelsRaw.cast<String>(),
    minutes: minutes,
    ingredients: ingredients,
    dietaryTags: tagsRaw.cast<String>().toSet(),
    coldSuitable: coldSuitable,
    costTier: costTier,
    grainComposition: grainComposition as String?,
  );
}

/// Builds [RecipeVersion]s from [def]s against resolved catalogue [foods]
/// (keyed by exact id `insa-bdca:<code>`).
///
/// Recipe-level allergens are the union of all effective ingredient allergens
/// **only when every ingredient is known** (effective set non-null for all);
/// otherwise null. The aggregate never feeds back into ingredient status.
List<StarterMealInstallation> buildStarterMealInstallations(
  List<StarterMealDef> defs,
  Map<String, Food> foods,
) {
  final installations = <StarterMealInstallation>[];
  for (final def in defs) {
    final ingredients = <RecipeIngredient>[];
    for (final ingDef in def.ingredients) {
      final foodId = 'insa-bdca:${ingDef.sourceCode}';
      final food = foods[foodId];
      if (food == null || food.id.isEmpty) {
        throw StarterMealLibraryException(
          'STARTER_MEAL_SOURCE_MISSING',
          'Starter meal ${def.id} needs missing catalogue food $foodId. '
          'Repair the bundled catalogue and rerun the meal library install.',
        );
      }
      ingredients.add(RecipeIngredient(
        food,
        Exact.parse(ingDef.grams),
        declaredAllergens: ingDef.allergens,
        allergenDeclarationSource: StarterMealAsset.declarationSource,
      ));
    }
    final everyKnown =
        ingredients.every((i) => i.effectiveAllergens != null);
    final recipeAllergens = everyKnown
        ? <String>{
            for (final i in ingredients) ...i.effectiveAllergens!,
          }
        : null;
    final recipe = RecipeVersion(
      id: def.id,
      revision: def.revision,
      name: def.titleEn,
      ingredients: ingredients,
      servings: Exact.one,
      minutes: def.minutes,
      allergens: recipeAllergens,
      dietaryTags: def.dietaryTags,
    );
    installations.add(StarterMealInstallation(
      recipe: recipe,
      contentPayload: starterMealContentPayload(def),
    ));
  }
  return installations;
}

/// The exact `meal-content-v1` payload stored for one starter recipe.
///
/// Field names match the parent validator contract:
/// `schemaVersion`, `recipeId`, `revision`, `coldSuitable`, `costTier`,
/// `mealLabels`, `titles`/`descriptions` maps (`en`, `pt-PT`),
/// `instructions` map (`en`, `pt-PT` string lists), plus `dietaryTags`,
/// `minutes` and `servings` for display. Instructions live here only; they
/// never enter nutrient arithmetic.
Map<String, Object?> starterMealContentPayload(StarterMealDef def) => {
      'schemaVersion': StarterMealAsset.contentSchemaVersion,
      'recipeId': def.id,
      'revision': def.revision,
      'coldSuitable': def.coldSuitable,
      'costTier': def.costTier,
      if (def.grainComposition != null)
        'grainComposition': def.grainComposition,
      'mealLabels': def.mealLabels,
      'minutes': def.minutes,
      'servings': '1',
      'dietaryTags': (def.dietaryTags.toList()..sort()),
      'titles': {'en': def.titleEn, 'pt-PT': def.titlePtPT},
      'descriptions': {
        'en': def.descriptionEn,
        'pt-PT': def.descriptionPtPT
      },
      'instructions': {
        'en': def.instructionsEn,
        'pt-PT': def.instructionsPtPT,
      },
      'allergenDeclarationNote':
          StarterMealAsset.ingredientAllergenDeclarationNote,
    };

/// Idempotent, atomic installer for the starter-meal library.
///
/// * Resolves every `insa-bdca:<code>` against the live catalogue and
///   validates all definitions before writing anything.
/// * Writes each `recipe` document via [recipeSnapshot] (collection `recipe`),
///   each content record (collection `meal-content-v1`, id == recipe id),
///   and the receipt (`preferences/starter-meals-v1`).
/// * A matching receipt, recipe signatures and content revisions make a launch
///   a no-op (`alreadyInstalled`). A new asset revision creates new immutable
///   recipe versions rather than rewriting pinned history: a starter recipe
///   found at a different definition signature is written at its asset
///   revision, never mutated in place when that would change a previously
///   installed signature (content is keyed by recipe id + revision).
/// * User-created (`starter:`-prefixed) ids are never overwritten: an existing
///   non-starter-v1 recipe under a starter id aborts the install.
final class StarterMealLibrary {
  StarterMealLibrary(this.db) : _workspace = LocalWorkspace(db);
  final AppDatabase db;
  final LocalWorkspace _workspace;

  /// Reads one meal-content record by recipe id, or null.
  Future<Map<String, Object?>?> readContent(String recipeId) async {
    final doc = await _workspace.read('meal-content-v1', recipeId);
    return doc?.data;
  }

  /// All installed meal-content records, ordered by id.
  Future<List<Map<String, Object?>>> listContent() async {
    final docs = await _workspace.list('meal-content-v1');
    return [for (final d in docs) d.data];
  }

  Future<String> assetDigest(List<int> jsonBytes) async {
    final hash = await Sha256().hash(jsonBytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<StarterMealLibraryProvision> ensureInstalled({
    required StarterMealAsset asset,
    required Future<Map<String, Food>> Function() resolveFoods,
  }) async {
    final digest = await assetDigest(asset.jsonBytes);
    final expectedRevision = asset.meals.first.revision;
    final bindings = <String, String>{
      for (final meal in asset.meals) meal.id: meal.id,
    };

    // Resolve + build fully before any write.
    final foods = await resolveFoods();
    final installations = buildStarterMealInstallations(asset.meals, foods);

    // Ownership pre-check (re-checked inside the transaction): an existing
    // recipe under a starter id is ours only when blindly trusting the
    // stored id is not enough — require a prior verified receipt mapping
    // whose signature matches the stored recipe exactly. Without a receipt,
    // any existing `starter:`-prefixed recipe is treated as a user recipe and
    // is never overwritten.
    final receipt0 = await _workspace.read(
        StarterMealAsset.receiptCollection, StarterMealAsset.receiptId);
    await _rejectUnowned(receipt0, installations);

    // Same-version/different-definition guard: if a receipt exists for this
    // asset version but with a different digest, reject rather than rewrite
    // a pinned historical definition in place.
    if (receipt0 != null &&
        receipt0.data['assetVersion'] == asset.assetVersion &&
        receipt0.data['digest'] != digest) {
      throw StarterMealLibraryException(
        'STARTER_MEAL_VERSION_CONFLICT',
        'Starter meal asset version ${asset.assetVersion} was already '
        'installed with different contents. Repair requires a new asset '
        'version; pinned history is preserved.',
      );
    }

    // Idempotent no-op check compares ACTUAL stored snapshots, never just
    // the receipt's claims.
    if (await _isIntact(receipt0, asset, digest, installations)) {
      return StarterMealLibraryProvision(
        status: StarterMealLibraryStatus.alreadyInstalled,
        assetVersion: asset.assetVersion,
        digest: digest,
        recipeCount: installations.length,
        recipeRevision: expectedRevision,
      );
    }

    final hadReceipt = receipt0 != null;
    final hadAny = receipt0 != null ||
        (await _workspace.read('recipe', installations.first.recipe.id)) !=
            null;
    final status = (!hadReceipt && !hadAny)
        ? StarterMealLibraryStatus.installed
        : StarterMealLibraryStatus.repaired;

    var recipeRevision = expectedRevision;
    await db.transaction(() async {
      // Re-read receipt + ownership under the transaction lock so a
      // concurrent install cannot cause a silent collision.
      final receipt = await _workspace.read(
          StarterMealAsset.receiptCollection, StarterMealAsset.receiptId);
      await _rejectUnowned(receipt, installations);
      for (final installation in installations) {
        final recipe = installation.recipe;
        recipeRevision = recipe.revision;
        final snapshot = recipeSnapshot(recipe);
        final recipeDoc = await _workspace.read('recipe', recipe.id);
        if (recipeDoc != null &&
            _storedSignature(recipeDoc) == recipe.definitionSignature) {
          // Already exactly this definition; skip the write.
        } else {
          final recipeExpected = recipeDoc?.revision ?? 0;
          // Request id binds the live expected revision + digest so a
          // deleted row with an old receipt replays with a fresh id and
          // actually writes instead of returning the old receipt revision.
          await _workspace.put(
            requestId:
                'starter-meals:${asset.assetVersion}:${recipe.id}:r${recipe.revision}:e$recipeExpected:$digest',
            collection: 'recipe',
            id: recipe.id,
            expectedRevision: recipeExpected,
            data: snapshot,
          );
        }
        final content = installation.contentPayload;
        final contentDoc =
            await _workspace.read('meal-content-v1', recipe.id);
        if (contentDoc != null &&
            _canonicalJson(contentDoc.data) == _canonicalJson(content)) {
          // Content already exact.
        } else {
          final contentExpected = contentDoc?.revision ?? 0;
          await _workspace.put(
            requestId:
                'starter-meals-content:${asset.assetVersion}:${recipe.id}:r${recipe.revision}:e$contentExpected:$digest',
            collection: 'meal-content-v1',
            id: recipe.id,
            expectedRevision: contentExpected,
            data: content,
          );
        }
      }
      final signatures = <String, String>{
        for (final installation in installations)
          installation.recipe.id: installation.recipe.definitionSignature,
      };
      final contentRevisions = <String, int>{
        for (final installation in installations)
          installation.recipe.id: installation.recipe.revision,
      };
      final receiptDoc = await _workspace.read(
          StarterMealAsset.receiptCollection, StarterMealAsset.receiptId);
      final receiptExpected = receiptDoc?.revision ?? 0;
      await _workspace.put(
        requestId:
            'starter-meals-receipt:${asset.assetVersion}:$digest:e$receiptExpected',
        collection: StarterMealAsset.receiptCollection,
        id: StarterMealAsset.receiptId,
        expectedRevision: receiptExpected,
        data: {
          'schemaVersion': 1,
          'assetVersion': asset.assetVersion,
          'digest': digest,
          'bindings': bindings,
          'signatures': signatures,
          'contentRevisions': contentRevisions,
          'recipeCount': installations.length,
          'recipeRevision': recipeRevision,
        },
      );
    });
    return StarterMealLibraryProvision(
      status: status,
      assetVersion: asset.assetVersion,
      digest: digest,
      recipeCount: installations.length,
      recipeRevision: recipeRevision,
    );
  }

  /// An existing starter recipe is owned by the library iff a prior receipt
  /// maps that id to a signature equal to the stored recipe's actual
  /// definition signature. Anything else (no receipt, mismatched signature,
  /// unparseable snapshot) is a user recipe and must never be overwritten.
  Future<void> _rejectUnowned(
    StoredDocument? receipt,
    List<StarterMealInstallation> installations,
  ) async {
    for (final installation in installations) {
      final existing =
          await _workspace.read('recipe', installation.recipe.id);
      if (existing == null) continue;
      final storedSignature = _storedSignature(existing);
      if (storedSignature == null) {
        throw StarterMealLibraryException(
          'STARTER_MEAL_ID_CONFLICT',
          'A user recipe already uses starter id ${installation.recipe.id}. '
          'Rename or remove it before installing the starter library.',
        );
      }
      final signatures = receipt?.data['signatures'];
      final owned = signatures is Map &&
          signatures[installation.recipe.id] == storedSignature;
      if (!owned) {
        throw StarterMealLibraryException(
          'STARTER_MEAL_ID_CONFLICT',
          'A user recipe already uses starter id ${installation.recipe.id}. '
          'Rename or remove it before installing the starter library.',
        );
      }
    }
  }

  /// Actual stored definition signature, or null when unparseable.
  String? _storedSignature(StoredDocument doc) {
    try {
      return recipeFromSnapshot(doc.data).definitionSignature;
    } catch (_) {
      return null;
    }
  }

  /// True only when receipt claims AND actual stored rows both match.
  Future<bool> _isIntact(
    StoredDocument? receipt,
    StarterMealAsset asset,
    String digest,
    List<StarterMealInstallation> installations,
  ) async {
    if (receipt == null) return false;
    final data = receipt.data;
    if (data['assetVersion'] != asset.assetVersion ||
        data['digest'] != digest ||
        data['recipeCount'] != installations.length) {
      return false;
    }
    final signatures = data['signatures'];
    if (signatures is! Map) return false;
    final contentRevisions = data['contentRevisions'];
    if (contentRevisions is! Map) return false;
    for (final installation in installations) {
      final expectedSignature = installation.recipe.definitionSignature;
      if (signatures[installation.recipe.id] != expectedSignature) {
        return false;
      }
      final recipeDoc =
          await _workspace.read('recipe', installation.recipe.id);
      if (recipeDoc == null) return false;
      // Tampered or stale stored recipe is never "intact".
      if (_storedSignature(recipeDoc) != expectedSignature) return false;
      if (contentRevisions[installation.recipe.id] !=
          installation.recipe.revision) {
        return false;
      }
      final contentDoc =
          await _workspace.read('meal-content-v1', installation.recipe.id);
      if (contentDoc == null) return false;
      if (_canonicalJson(contentDoc.data) !=
          _canonicalJson(installation.contentPayload)) {
        return false;
      }
    }
    return true;
  }

  /// Canonical JSON for content-equality comparison. Stored payloads are
  /// decoded maps, so key order of the original encode is not significant;
  /// encode deterministically with sorted map keys.
  String _canonicalJson(Object? value) => jsonEncode(_canonical(value));

  Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      return {
        for (final key in keys) key: _canonical(value[key]),
      };
    }
    if (value is List) return [for (final item in value) _canonical(item)];
    return value;
  }
}
