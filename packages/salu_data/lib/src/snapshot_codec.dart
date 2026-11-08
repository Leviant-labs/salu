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
      'quality': f.quality.name
    };
Food foodFromSnapshot(Map<String, Object?> j) => Food(
    id: j['id']! as String,
    name: j['name']! as String,
    per100g: NutrientProfile.fromJson(
        Map<String, Object?>.from(j['nutrients']! as Map)),
    source: FoodSource(
        dataset: j['dataset']! as String,
        datasetId: j['sourceId']! as String,
        datasetVersion: j['version'] as String?),
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
