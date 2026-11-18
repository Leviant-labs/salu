import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';

import '../../assistant/assistant.dart';
import 'meal_editor_ai.dart';
import 'meal_editor_images.dart';

final activeMealEstimates = ValueNotifier<Set<String>>(const {});

/// Runs only after an explicit request. A pending row never schedules a future
/// upload: after process death it is simply available for a manual retry.
Future<void> estimateSavedMeal({
  required PhotoMeal meal,
  required PhotoMealRepository repository,
  required SaluAssistant assistant,
  required String Function() newId,
}) async {
  if (activeMealEstimates.value.contains(meal.id) || meal.items.isNotEmpty) {
    return;
  }
  activeMealEstimates.value = {...activeMealEstimates.value, meal.id};
  try {
    var items = const <PhotoMealItem>[];
    try {
      final response = await assistant.ask(
        instructions: mealEstimateInstructions,
        prompt: mealEstimatePrompt(meal.caption),
        images: [
          if (meal.photoPath case final path?) await encodeMealUpload(path)
        ],
      );
      items = parseMealEstimate(response)
          .map((item) => item.copyWith(id: newId()))
          .toList();
    } catch (_) {
      // The local record already exists. It remains editable and retryable.
    }
    await repository.replace(
        meal.copyWith(
          items: items,
          estimateStatus: items.isEmpty
              ? MealEstimateStatus.unavailable
              : MealEstimateStatus.complete,
        ),
        meal.revision);
  } catch (_) {
    // A storage failure leaves the original saved row and the explicit retry.
  } finally {
    activeMealEstimates.value = {...activeMealEstimates.value}..remove(meal.id);
  }
}
