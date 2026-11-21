import 'package:flutter/foundation.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

import '../../assistant/assistant.dart';
import 'meal_editor_ai.dart';
import 'meal_editor_images.dart';

/// Scoped tracker for meal IDs with an in-flight AI estimate request.
class ActiveMealEstimates extends ValueNotifier<Set<String>> {
  ActiveMealEstimates() : super(const <String>{});

  bool contains(String mealId) => value.contains(mealId);

  bool tryStart(String mealId) {
    if (value.contains(mealId)) return false;
    value = <String>{...value, mealId};
    return true;
  }

  void finish(String mealId) {
    if (!value.contains(mealId)) return;
    value = <String>{...value}..remove(mealId);
  }

  void reset() {
    if (value.isNotEmpty) {
      value = const <String>{};
    }
  }
}

/// Runs only after an explicit request. A pending row never schedules a future
/// upload: after process death it is simply available for a manual retry.
Future<void> estimateSavedMeal({
  required PhotoMeal meal,
  required PhotoMealRepository repository,
  required SaluAssistant assistant,
  required String Function() newId,
  ActiveMealEstimates? activeEstimates,
  MealEstimateStatusStore? statusStore,
}) async {
  if (meal.items.isNotEmpty) return;
  if (activeEstimates != null && !activeEstimates.tryStart(meal.id)) {
    return;
  }
  try {
    var items = const <PhotoMealItem>[];
    String? errorCode;
    try {
      final response = await assistant.ask(
        instructions: mealEstimateInstructions,
        prompt: mealEstimatePrompt(meal.caption),
        images: [
          if (meal.photoPath case final path?) await encodeMealUpload(path),
        ],
        task: InferenceTask.mealPhoto,
        requestId: meal.id,
      );
      final rawProvenance = await assistant.activeProviderProvenance;
      final provenance = (rawProvenance == null || rawProvenance.trim().isEmpty)
          ? defaultMealEstimateProvenance
          : '${rawProvenance.trim()}-meal-estimate';
      items = parseMealEstimate(response, provenance: provenance)
          .map((item) => item.copyWith(id: newId()))
          .toList();
    } on SaluAssistantException catch (error) {
      errorCode = error.code.name;
    } on FormatException {
      errorCode = SaluAssistantErrorCode.invalidResponse.name;
    } on Object {
      errorCode = SaluAssistantErrorCode.serviceUnavailable.name;
    }
    final updated = meal.copyWith(
      items: items,
      estimateStatus: items.isEmpty
          ? MealEstimateStatus.unavailable
          : MealEstimateStatus.complete,
    );
    if (statusStore != null) {
      await statusStore.finish(
        updated,
        meal.revision,
        errorCode: items.isEmpty ? errorCode : null,
      );
    } else {
      await repository.replace(updated, meal.revision);
    }
  } catch (_) {
    // A storage failure leaves the original saved row and the explicit retry.
  } finally {
    activeEstimates?.finish(meal.id);
  }
}
