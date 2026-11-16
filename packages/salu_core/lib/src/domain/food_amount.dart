/// Resolves an explicit user amount against a food's declared nutrient basis.
///
/// The same rules apply when a food is logged and when a logged item is
/// replaced: a unit is only accepted when the food itself declares the
/// conversion, never through a guessed density or portion weight.
library;

import 'food.dart';
import 'nutrition_contract.dart';
import 'quantity.dart';

/// The conversions [food] declares, as recorded conversions that travel with an
/// export.
///
/// A missing, non-finite or non-positive density/portion weight declares no
/// conversion at all; it is never rounded into a usable default.
List<QuantityConversion> declaredQuantityConversions(Food food) {
  final density = food.portions.densityGramsPerMillilitre;
  final portion = food.portions.portionGrams;
  return [
    if (density != null && density.isFinite && density > 0)
      QuantityConversion(
          from: FoodAmount('1', FoodUnit.ml),
          to: FoodAmount(density.toString(), FoodUnit.g),
          source: 'food-density'),
    if (portion != null && portion.isFinite && portion > 0) ...[
      QuantityConversion(
          from: FoodAmount('1', FoodUnit.item, measureId: 'piece'),
          to: FoodAmount(portion.toString(), FoodUnit.g),
          source: 'food-portion'),
      QuantityConversion(
          from: FoodAmount('1', FoodUnit.serving, measureId: 'serving'),
          to: FoodAmount(portion.toString(), FoodUnit.g),
          source: 'food-serving'),
    ],
  ];
}

/// An explicit amount of a food resolved to its nutrient basis and eaten mass.
typedef ResolvedFoodAmount = ({Exact factor, double? grams});

/// Resolves [amount] against [food]'s declared basis and conversions.
///
/// [factor] is the exact multiplier for [Food.per100g], whose name is legacy:
/// the profile is stored per [Food.basisValue] of [Food.basisUnit]. [grams] is
/// the eaten mass when the recorded conversions establish one; null means the
/// native amount is valid but no mass was declared (for example a piece count
/// without a portion weight).
///
/// Throws [StateError] when [amount] has no recorded conversion for this food.
/// Callers must ask for a compatible amount instead of inventing one.
ResolvedFoodAmount resolveFoodAmount(Food food, FoodAmount amount) {
  final factor = quantityRatio(
      amount,
      FoodAmount(food.basisValue, food.basisUnit,
          measureId: switch (food.basisUnit) {
            FoodUnit.item => 'piece',
            FoodUnit.serving => 'serving',
            _ => null
          }),
      declaredQuantityConversions(food));
  final quantity = switch (amount.unit) {
    FoodUnit.g => MassQuantity(amount.value.toDouble()),
    FoodUnit.ml => VolumeQuantity(amount.value.toDouble()),
    FoodUnit.item => PieceQuantity(amount.value.toDouble()),
    FoodUnit.serving => ServingQuantity(amount.value.toDouble()),
  };
  final resolution = resolveQuantity(quantity, food.portions);
  return (
    factor: factor,
    grams: resolution is ResolvedMass ? resolution.grams : null,
  );
}
