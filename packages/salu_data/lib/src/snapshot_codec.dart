import 'package:salu_core/salu_core.dart';

Map<String, Object?> foodSnapshot(Food f) => {
      'id': f.id,
      'name': f.name,
      'nutrients': f.per100g.toJson(),
      'dataset': f.source.dataset,
      'sourceId': f.source.datasetId,
      'version': f.source.datasetVersion,
      'basisUnit': f.basisUnit.name,
      'basisValue': f.basisValue,
      'portionGrams': f.portions.portionGrams,
      'density': f.portions.densityGramsPerMillilitre,
      'preparation': f.preparation.name,
      'allergens': f.allergens?.toList(),
      'dietaryTags': f.dietaryTags.toList(),
      'quality': f.quality.name,
      'licence': f.source.licence,
      'aliases': f.aliases,
      'barcodes': f.barcodes,
      'regions': f.regions,
      'observations': f.observations.map((o) => o.toJson()).toList(),
      'isComposite': f.isComposite
    };
Food foodFromSnapshot(Map<String, Object?> j) => Food(
    aliases: (j['aliases'] as List? ?? []).cast<String>(),
    barcodes: (j['barcodes'] as List? ?? []).cast<String>(),
    regions: (j['regions'] as List? ?? []).cast<String>(),
    observations: [
      for (final o in j['observations'] as List? ?? [])
        NutrientObservation.fromJson(Map<String, Object?>.from(o as Map))
    ],
    isComposite: j['isComposite'] == true,
    id: j['id']! as String,
    name: j['name']! as String,
    per100g: NutrientProfile.fromJson(
        Map<String, Object?>.from(j['nutrients']! as Map)),
    source: FoodSource(
        dataset: j['dataset']! as String,
        datasetId: j['sourceId']! as String,
        datasetVersion: j['version'] as String?,
        licence: j['licence'] as String?),
    basisUnit: FoodUnit.values.byName(j['basisUnit']! as String),
    basisValue: j['basisValue']! as String,
    portions: PortionDefinition(
        portionGrams: (j['portionGrams'] as num?)?.toDouble(),
        densityGramsPerMillilitre: (j['density'] as num?)?.toDouble()),
    preparation: Preparation.values.byName(j['preparation']! as String),
    allergens: (j['allergens'] as List?)?.cast<String>().toSet(),
    dietaryTags: (j['dietaryTags']! as List).cast<String>().toSet(),
    quality: DataQuality.values.byName(j['quality']! as String));
Map<String, Object?> recipeSnapshot(RecipeVersion r) => {
      'id': r.id,
      'revision': r.revision,
      'name': r.name,
      'servings': r.servings.toJson(),
      'minutes': r.minutes,
      'allergens': r.allergens?.toList(),
      'dietaryTags': r.dietaryTags.toList(),
      'ingredients': [
        for (final i in r.ingredients)
          {'food': foodSnapshot(i.food), 'grams': i.grams.toJson()}
      ]
    };
RecipeVersion recipeFromSnapshot(Map<String, Object?> j) => RecipeVersion(
        id: j['id']! as String,
        revision: j['revision']! as int,
        name: j['name']! as String,
        servings:
            Exact.fromJson(Map<String, Object?>.from(j['servings']! as Map)),
        minutes: j['minutes']! as int,
        allergens: (j['allergens'] as List?)?.cast<String>().toSet(),
        dietaryTags: (j['dietaryTags']! as List).cast<String>().toSet(),
        ingredients: [
          for (final value in j['ingredients']! as List)
            RecipeIngredient(
                foodFromSnapshot(
                    Map<String, Object?>.from((value as Map)['food'] as Map)),
                Exact.fromJson(
                    Map<String, Object?>.from(value['grams'] as Map)))
        ]);

Map<String, Object?> loggedItemSnapshot(LoggedItem i) => {
      'name': i.name,
      'grams': i.grams,
      'foodId': i.foodId,
      'nutrients': i.nutrients.toJson(),
      'quantity': i.quantity?.toJson(),
      'source': i.sourceSnapshot
    };
LoggedItem loggedItemFromSnapshot(Map<String, Object?> j) => LoggedItem(
    name: j['name']! as String,
    grams: (j['grams'] as num?)?.toDouble(),
    foodId: j['foodId'] as String?,
    nutrients: NutrientProfile.fromJson(
        Map<String, Object?>.from(j['nutrients']! as Map)),
    quantity: j['quantity'] == null
        ? null
        : FoodAmount.fromJson(Map<String, Object?>.from(j['quantity']! as Map)),
    sourceSnapshot: j['source'] == null
        ? null
        : Map<String, Object?>.from(j['source']! as Map));
