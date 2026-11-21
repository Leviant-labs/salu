import 'package:salu_core/salu_core.dart';

import 'recipe_codec.dart';

/// Current snapshot schema version for serialized [PhotoMeal] records.
const int photoMealSnapshotVersion = 1;

/// Serializes [meal] as a version-1 snapshot, preserving all identity, timing,
/// evidence, nutrition, and review-issue fields.
Map<String, Object?> encodePhotoMeal(PhotoMeal meal) => <String, Object?>{
      'version': photoMealSnapshotVersion,
      'id': meal.id,
      'date': meal.date.toIso(),
      'slot': meal.slot.name,
      'caption': meal.caption,
      'createdAtMs': meal.createdAt.millisecondsSinceEpoch,
      'revision': meal.revision,
      'photoPath': meal.photoPath,
      'estimateStatus': meal.estimateStatus.name,
      'recordedOffsetMinutes': meal.recordedOffsetMinutes,
      'items': [for (final item in meal.items) encodePhotoMealItem(item)],
    };

/// Decodes a [PhotoMeal] from either a legacy (unversioned) or version-1 map.
///
/// Rejects unsupported future versions with a [FormatException].
PhotoMeal decodePhotoMeal(Map<String, dynamic> row) {
  final rawVersion = row['version'];
  if (rawVersion != null) {
    if (rawVersion is! int ||
        rawVersion < 1 ||
        rawVersion > photoMealSnapshotVersion) {
      throw FormatException(
        'Unsupported PhotoMeal snapshot version: $rawVersion',
      );
    }
  }

  final id = row['id'];
  if (id is! String || id.trim().isEmpty) {
    throw const FormatException('PhotoMeal snapshot missing valid id');
  }

  final rawDate = row['date'] ?? row['diaryDate'];
  if (rawDate is! String) {
    throw const FormatException('PhotoMeal snapshot missing date');
  }

  final rawSlot = row['slot'];
  final slot = rawSlot is String
      ? MealSlot.values.byName(rawSlot)
      : throw const FormatException('PhotoMeal snapshot missing slot');

  final caption = row['caption'] is String ? row['caption'] as String : '';

  final DateTime createdAt;
  final rawCreatedAtMs = row['createdAtMs'];
  final rawCreatedAt = row['createdAt'];
  if (rawCreatedAtMs is int) {
    createdAt =
        DateTime.fromMillisecondsSinceEpoch(rawCreatedAtMs, isUtc: true);
  } else if (rawCreatedAt is String) {
    createdAt = DateTime.parse(rawCreatedAt).toUtc();
  } else {
    throw const FormatException('PhotoMeal snapshot missing createdAt');
  }

  final rawRevision = row['revision'];
  final revision = rawRevision is int && rawRevision >= 1 ? rawRevision : 1;

  final photoPath =
      row['photoPath'] is String ? row['photoPath'] as String : null;

  final rawEstimateStatus = row['estimateStatus'];
  final estimateStatus = rawEstimateStatus is String
      ? MealEstimateStatus.values.byName(rawEstimateStatus)
      : MealEstimateStatus.none;

  final recordedOffsetMinutes = row['recordedOffsetMinutes'] is int
      ? row['recordedOffsetMinutes'] as int
      : null;

  final rawItems = row['items'];
  final items = rawItems is List
      ? rawItems.indexed
          .map((entry) => decodePhotoMealItem(
                entry.$2,
                fallbackId: '$id:legacy:${entry.$1}',
                strict: false,
              ))
          .toList()
      : const <PhotoMealItem>[];

  return PhotoMeal(
    id: id,
    date: DiaryDate.parse(rawDate),
    slot: slot,
    caption: caption,
    createdAt: createdAt,
    revision: revision,
    photoPath: photoPath,
    estimateStatus: estimateStatus,
    recordedOffsetMinutes: recordedOffsetMinutes,
    items: items,
  );
}
