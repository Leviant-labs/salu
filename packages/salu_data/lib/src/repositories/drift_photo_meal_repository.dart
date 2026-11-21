import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../codec/recipe_codec.dart';
import '../database/app_database.dart';

final class DriftPhotoMealRepository implements LivePhotoMealRepository {
  DriftPhotoMealRepository(this._db);

  final AppDatabase _db;

  @override
  Future<List<PhotoMeal>> listFor(DiaryDate date) async =>
      _hydrate(await _query(date).get());

  @override
  Stream<List<PhotoMeal>> watchFor(DiaryDate date) =>
      _query(date).watch().map(_hydrate);

  Selectable<PhotoMealRow> _query(DiaryDate date) => (_db.select(_db.photoMeals)
    ..where((t) => t.diaryDate.equals(date.toIso()))
    ..orderBy([
      (t) => OrderingTerm.asc(t.createdAtMs),
      (t) => OrderingTerm.asc(t.id)
    ]));

  List<PhotoMeal> _hydrate(List<PhotoMealRow> rows) {
    return [
      for (final row in rows)
        PhotoMeal(
          id: row.id,
          date: DiaryDate.parse(row.diaryDate),
          slot: MealSlot.values.byName(row.slot),
          caption: row.caption,
          createdAt:
              DateTime.fromMillisecondsSinceEpoch(row.createdAtMs, isUtc: true),
          revision: row.revision,
          photoPath: row.photoPath,
          estimateStatus: MealEstimateStatus.values.byName(row.estimateStatus),
          recordedOffsetMinutes: row.recordedOffsetMinutes,
          items: (jsonDecode(row.itemsJson) as List)
              .indexed
              .map((entry) => decodePhotoMealItem(
                    entry.$2,
                    fallbackId: '${row.id}:legacy:${entry.$1}',
                    strict: false,
                  ))
              .toList(),
        ),
    ];
  }

  @override
  Future<bool> saveNew(PhotoMeal meal) => _db.transaction(() async {
        final existing = await (_db.select(_db.photoMeals)
              ..where((t) => t.id.equals(meal.id)))
            .getSingleOrNull();
        if (existing != null) return false;
        await _db.into(_db.photoMeals).insert(PhotoMealsCompanion.insert(
              id: meal.id,
              diaryDate: meal.date.toIso(),
              slot: meal.slot.name,
              caption: meal.caption,
              createdAtMs: meal.createdAt.millisecondsSinceEpoch,
              revision: 1,
              photoPath: Value(meal.photoPath),
              estimateStatus: Value(meal.estimateStatus.name),
              recordedOffsetMinutes: Value(meal.recordedOffsetMinutes),
              itemsJson: _encodeItems(meal.items),
            ));
        return true;
      });

  @override
  Future<bool> replace(PhotoMeal meal, int expectedRevision) async {
    if (meal.revision != expectedRevision) return false;
    final count = await (_db.update(_db.photoMeals)
          ..where((t) =>
              t.id.equals(meal.id) & t.revision.equals(expectedRevision)))
        .write(PhotoMealsCompanion(
      diaryDate: Value(meal.date.toIso()),
      slot: Value(meal.slot.name),
      caption: Value(meal.caption),
      revision: Value(expectedRevision + 1),
      photoPath: Value(meal.photoPath),
      estimateStatus: Value(meal.estimateStatus.name),
      itemsJson: Value(_encodeItems(meal.items)),
    ));
    return count == 1;
  }

  String _encodeItems(List<PhotoMealItem> items) =>
      jsonEncode([for (final item in items) encodePhotoMealItem(item)]);
}
