import 'nutrients.dart';
import 'nutrition_screening.dart';
import 'time.dart';

enum MealSlot { breakfast, lunch, dinner, snack }

enum MealUnit { grams, millilitres, servings, pieces }

enum MealEstimateStatus { none, pending, unavailable, complete }

final class MealPortion {
  MealPortion(this.amount, this.unit) {
    if (!amount.isFinite || amount <= 0) {
      throw ArgumentError.value(
          amount, 'amount', 'must be positive and finite');
    }
  }

  final double amount;
  final MealUnit unit;
}

/// Nutrients are a snapshot for the consumed portion, not a per-unit value.
final class PhotoMealItem {
  PhotoMealItem({
    required String name,
    this.portion,
    NutrientProfile? nutrients,
    String? labelPath,
    List<String> labelPaths = const [],
    this.id,
    this.source,
    List<NutritionIssue> reviewIssues = const [],
  })  : name = name.trim(),
        labelPaths = List.unmodifiable(
            {...labelPaths, if (labelPath != null) labelPath}),
        nutrients = nutrients ?? const NutrientProfile.empty(),
        reviewIssues = List.unmodifiable(reviewIssues) {
    if (this.name.isEmpty) throw ArgumentError('A food name is required');
  }

  final String name;
  final String? id;
  final MealPortion? portion;
  final NutrientProfile nutrients;
  final List<String> labelPaths;
  String? get labelPath => labelPaths.lastOrNull;
  final String? source;
  final List<NutritionIssue> reviewIssues;

  PhotoMealItem copyWith({
    String? name,
    String? id,
    MealPortion? portion,
    NutrientProfile? nutrients,
    String? labelPath,
    String? source,
    List<NutritionIssue>? reviewIssues,
  }) =>
      PhotoMealItem(
        name: name ?? this.name,
        id: id ?? this.id,
        portion: portion ?? this.portion,
        nutrients: nutrients ?? this.nutrients,
        labelPaths: labelPaths,
        labelPath: labelPath,
        source: source ?? this.source,
        reviewIssues: reviewIssues ?? this.reviewIssues,
      );
}

/// A diary record can contain photo evidence even when every food is unresolved.
final class PhotoMeal {
  PhotoMeal({
    required this.id,
    required this.date,
    required this.slot,
    required this.caption,
    required DateTime createdAt,
    this.revision = 1,
    this.photoPath,
    this.estimateStatus = MealEstimateStatus.none,
    this.recordedOffsetMinutes,
    List<PhotoMealItem> items = const [],
  })  : createdAt = createdAt.toUtc(),
        items = List.unmodifiable(items) {
    if (id.trim().isEmpty || revision < 1) {
      throw ArgumentError('A meal needs an ID and a positive revision');
    }
  }

  final String id;
  final DiaryDate date;
  final MealSlot slot;
  final String caption;
  final DateTime createdAt;
  final int revision;
  final String? photoPath;
  final MealEstimateStatus estimateStatus;
  final int? recordedOffsetMinutes;
  final List<PhotoMealItem> items;

  PhotoMeal copyWith({
    DiaryDate? date,
    MealSlot? slot,
    String? caption,
    List<PhotoMealItem>? items,
    int? revision,
    String? photoPath,
    bool clearPhoto = false,
    MealEstimateStatus? estimateStatus,
  }) =>
      PhotoMeal(
        id: id,
        date: date ?? this.date,
        slot: slot ?? this.slot,
        caption: caption ?? this.caption,
        createdAt: createdAt,
        revision: revision ?? this.revision,
        photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
        estimateStatus: estimateStatus ?? this.estimateStatus,
        recordedOffsetMinutes: recordedOffsetMinutes,
        items: items ?? this.items,
      );
}

abstract interface class LivePhotoMealRepository
    implements PhotoMealRepository {
  Stream<List<PhotoMeal>> watchFor(DiaryDate date);
}

abstract interface class PhotoMealRepository {
  Future<List<PhotoMeal>> listFor(DiaryDate date);

  /// Inserts once per stable meal ID. Returns false for a duplicate.
  Future<bool> saveNew(PhotoMeal meal);

  /// Replaces the editable snapshot only if the expected revision still matches.
  Future<bool> replace(PhotoMeal meal, int expectedRevision);
}
