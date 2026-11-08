import '../domain/entry.dart';
import '../domain/nutrition_contract.dart';
import '../domain/planning.dart';
import '../domain/time.dart';
import 'ports.dart';

final class LogRecipeCommand {
  LogRecipeCommand(
      {required this.requestId,
      required this.recipe,
      required this.portions,
      required this.offsetMinutes,
      required this.confirmed,
      this.channel = EntryChannel.manual}) {
    if (requestId.isEmpty ||
        !portions.positive ||
        offsetMinutes < -840 ||
        offsetMinutes > 840) {
      throw ArgumentError('Invalid recipe log');
    }
  }
  final String requestId;
  final RecipeVersion recipe;
  final Exact portions;
  final int offsetMinutes;
  final bool confirmed;
  final EntryChannel channel;
}

final class LogRecipeHandler {
  const LogRecipeHandler(this.entries, this.clock, this.ids);
  final EntryRepository entries;
  final Clock clock;
  final IdGenerator ids;
  Future<LoggedEntry> handle(LogRecipeCommand c) async {
    if (!c.confirmed) throw StateError('CONSUMPTION_CONFIRMATION_REQUIRED');
    final previous = await entries.findByRequestId(c.requestId);
    if (previous != null) return previous;
    final stamp =
        EventStamp(instant: clock.nowUtc(), offsetMinutes: c.offsetMinutes);
    final factor = c.portions / c.recipe.servings;
    // Preserve individual ingredient snapshots and their omissions. Equal-serving
    // allocation is explicit; no precise cooked grams are invented from raw mass.
    final entry = LoggedEntry(
        id: ids.next(),
        requestId: c.requestId,
        diaryDate: DiaryDate.assign(stamp),
        stamp: stamp,
        channel: c.channel,
        recordedAt: clock.nowUtc(),
        items: [
          for (final ingredient in c.recipe.ingredients)
            LoggedItem(
                name: ingredient.food.name,
                grams: null,
                nutrients: ingredient.nutrients.scaledExact(factor),
                foodId: ingredient.food.id,
                quantity: FoodAmount.exact(
                    ingredient.grams * (c.portions / c.recipe.servings),
                    FoodUnit.g),
                sourceSnapshot: {
                  'recipeId': c.recipe.id,
                  'recipeRevision': c.recipe.revision,
                  'dataset': ingredient.food.source.dataset,
                  'sourceId': ingredient.food.source.datasetId,
                  'sourceVersion': ingredient.food.source.datasetVersion,
                  'rawEdibleGrams': ingredient.grams.toJson(),
                  'allocationScale': (c.portions / c.recipe.servings).toJson(),
                  'cookingLossesModeled': false,
                  'quantityBasis': 'raw-edible-ingredient-allocation',
                  'engine': 'nutrition-v2'
                })
        ]);
    await entries.append(entry);
    return entry;
  }
}
