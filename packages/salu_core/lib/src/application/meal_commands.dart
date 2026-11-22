import '../domain/photo_meal.dart';
import '../domain/time.dart';

/// Outcome of applying a [MealCommand] through the mutation journal.
enum MutationStatus {
  applied,
  alreadyApplied,
  stale,
  notFound,
  expired,
  invalidDate,
}

/// Result returned by a revisioned meal mutation.
final class MealMutationResult {
  const MealMutationResult({
    required this.status,
    this.meal,
    this.undoToken,
  });

  final MutationStatus status;
  final PhotoMeal? meal;
  final String? undoToken;
}

/// Idempotent, revision-checked mutation command for a [PhotoMeal].
sealed class MealCommand {
  const MealCommand({required this.requestId});

  final String requestId;
}

/// Replaces editable fields (slot, caption, items, photo, estimate status) on
/// an existing meal when [expectedRevision] matches the active row.
final class ReviseMeal extends MealCommand {
  const ReviseMeal({
    required super.requestId,
    required this.meal,
    required this.expectedRevision,
  });

  final PhotoMeal meal;
  final int expectedRevision;
}

/// Moves an existing meal to [date] (which must not be after [today]) while
/// preserving its identity, photo, items, creation instant, and UTC offset.
final class MoveMeal extends MealCommand {
  const MoveMeal({
    required super.requestId,
    required this.mealId,
    required this.expectedRevision,
    required this.date,
    required this.today,
  });

  final String mealId;
  final int expectedRevision;
  final DiaryDate date;
  final DiaryDate today;
}

/// Soft-deletes an active meal by removing its row and recording a 24-hour undo
/// snapshot in the mutation journal.
final class DeleteMeal extends MealCommand {
  const DeleteMeal({
    required super.requestId,
    required this.mealId,
    required this.expectedRevision,
  });

  final String mealId;
  final int expectedRevision;
}

/// Restores a previously deleted meal using its durable [undoToken] if the undo
/// window has not expired and no newer mutation has superseded it.
final class UndoMeal extends MealCommand {
  const UndoMeal({
    required super.requestId,
    required this.undoToken,
  });

  final String undoToken;
}
