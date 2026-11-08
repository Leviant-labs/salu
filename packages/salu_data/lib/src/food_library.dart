import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';
import 'database/app_database.dart';
import 'repositories/drift_food_repository.dart';
import 'repositories/drift_entry_repository.dart';
import 'snapshot_codec.dart';
import 'workspace_store.dart';

final class SetFavoriteFoodCommand {
  SetFavoriteFoodCommand(
      {required this.requestId, required this.foodId, required this.favorite}) {
    if (requestId.isEmpty || foodId.isEmpty) {
      throw ArgumentError('Empty food command');
    }
  }
  final String requestId, foodId;
  final bool favorite;
}

final class SaveMealCommand {
  SaveMealCommand(
      {required this.requestId,
      required this.entryRequestId,
      required this.name}) {
    if (requestId.isEmpty || entryRequestId.isEmpty || name.trim().isEmpty) {
      throw ArgumentError('Meal name and source entry are required');
    }
  }
  final String requestId, entryRequestId, name;
}

final class LogSavedMealCommand {
  LogSavedMealCommand(
      {required this.requestId,
      required this.mealId,
      required this.confirmed,
      required this.multiplier,
      required this.stamp,
      required this.diaryDate}) {
    if (requestId.isEmpty || mealId.isEmpty || !multiplier.positive) {
      throw ArgumentError('Invalid saved-meal command');
    }
  }
  final String requestId, mealId;
  final bool confirmed;
  final Exact multiplier;
  final EventStamp stamp;
  final DiaryDate diaryDate;
}

final class FoodLibraryService {
  FoodLibraryService(this.db, this.clock, this.ids);
  final AppDatabase db;
  final Clock clock;
  final IdGenerator ids;
  LocalWorkspace get workspace => LocalWorkspace(db);
  Future<void> setFavorite(SetFavoriteFoodCommand command) async =>
      db.transaction(() async {
        final old = await workspace.read('favorite-food', command.foodId);
        // The request payload is stable on retry even if the catalogue changed.
        final receipt = await (db.select(db.appliedCommands)
              ..where((t) => t.requestId.equals(command.requestId)))
            .getSingleOrNull();
        if (receipt != null) {
          final result =
              Map<String, Object?>.from(jsonDecode(receipt.resultJson) as Map);
          final payload = result['payload'] is String
              ? jsonDecode(result['payload']! as String)
              : null;
          if (result['collection'] != 'favorite-food' ||
              result['id'] != command.foodId ||
              payload is! Map ||
              payload['favorite'] != command.favorite) {
            throw StateError('REQUEST_ID_REUSED');
          }
          return;
        }
        final food = await DriftFoodRepository(db).findById(command.foodId);
        if (food == null) throw StateError('UNKNOWN_FOOD');
        await workspace.put(
            requestId: command.requestId,
            collection: 'favorite-food',
            id: command.foodId,
            expectedRevision: old?.revision ?? 0,
            data: {'favorite': command.favorite, 'food': foodSnapshot(food)});
      });
  Future<List<Food>> favorites() async {
    final docs = await workspace.list('favorite-food');
    final result = <Food>[];
    for (final d in docs.where((d) => d.data['favorite'] == true)) {
      final food = await DriftFoodRepository(db).findById(d.id);
      if (food != null) result.add(food);
    }
    return result..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<List<Food>> recent({int limit = 20}) async {
    if (limit < 1 || limit > 200) {
      throw ArgumentError('Invalid recent-food limit');
    }
    final rows = await db.customSelect(
        'SELECT i.food_id,MAX(e.recorded_at_ms) AS latest FROM log_entry_items i JOIN log_entries e ON i.entry_id=e.id WHERE i.food_id IS NOT NULL GROUP BY i.food_id ORDER BY latest DESC,i.food_id LIMIT ?',
        variables: [Variable<int>(limit)]).get();
    final result = <Food>[];
    for (final row in rows) {
      final f =
          await DriftFoodRepository(db).findById(row.read<String>('food_id'));
      if (f != null) result.add(f);
    }
    return result;
  }

  Future<String> saveMeal(SaveMealCommand command) async =>
      db.transaction(() async {
        final existing = await workspace.read('saved-meal', command.requestId);
        if (existing != null) {
          if (existing.data['name'] != command.name.trim() ||
              existing.data['sourceRequest'] != command.entryRequestId) {
            throw StateError('REQUEST_ID_REUSED');
          }
          return existing.id;
        }
        final entry = await DriftEntryRepository(db)
            .findByRequestId(command.entryRequestId);
        if (entry == null || entry.items.isEmpty) {
          throw StateError('SOURCE_ENTRY_MISSING');
        }
        if (entry.items.any((i) => i.sourceSnapshot?['batchId'] != null)) {
          throw StateError('BATCH_SELECTION_REQUIRED');
        }
        await workspace.put(
            requestId: command.requestId,
            collection: 'saved-meal',
            id: command.requestId,
            expectedRevision: 0,
            data: {
              'name': command.name.trim(),
              'sourceRequest': command.entryRequestId,
              'items': entry.items.map(loggedItemSnapshot).toList()
            });
        return command.requestId;
      });
  Future<LoggedEntry> logSavedMeal(LogSavedMealCommand c) async =>
      db.transaction(() async {
        if (!c.confirmed) throw StateError('CONSUMPTION_CONFIRMATION_REQUIRED');
        final entries = DriftEntryRepository(db);
        final prior = await entries.findByRequestId(c.requestId);
        if (prior != null) {
          if (prior.diaryDate != c.diaryDate ||
              prior.stamp != c.stamp ||
              prior.items.any((i) =>
                  i.sourceSnapshot?['savedMealId'] != c.mealId ||
                  i.sourceSnapshot?['repeatMultiplier'] is! Map ||
                  Exact.fromJson(Map<String, Object?>.from(
                          i.sourceSnapshot!['repeatMultiplier']! as Map)) !=
                      c.multiplier)) {
            throw StateError('REQUEST_ID_REUSED');
          }
          return prior;
        }
        final saved = await workspace.read('saved-meal', c.mealId);
        if (saved == null) throw StateError('SAVED_MEAL_MISSING');
        final source = (saved.data['items']! as List)
            .map((v) =>
                loggedItemFromSnapshot(Map<String, Object?>.from(v as Map)))
            .toList();
        // A saved batch portion cannot silently consume another finite batch's stock.
        if (source.any((i) => i.sourceSnapshot?['batchId'] != null)) {
          throw StateError('BATCH_SELECTION_REQUIRED');
        }
        final entry = LoggedEntry(
            id: ids.next(),
            requestId: c.requestId,
            diaryDate: c.diaryDate,
            stamp: c.stamp,
            channel: EntryChannel.manual,
            recordedAt: clock.nowUtc(),
            items: [
              for (final i in source)
                LoggedItem(
                    name: i.name,
                    grams: i.grams == null
                        ? null
                        : (Exact.parse(i.grams.toString()) * c.multiplier)
                            .toDouble(),
                    nutrients: i.nutrients.scaledExact(c.multiplier),
                    foodId: i.foodId,
                    quantity: i.quantity == null
                        ? null
                        : FoodAmount.exact(
                            i.quantity!.value * c.multiplier, i.quantity!.unit,
                            measureId: i.quantity!.measureId),
                    sourceSnapshot: {
                      ...?i.sourceSnapshot,
                      'savedMealId': saved.id,
                      'savedMealRevision': saved.revision,
                      'repeatMultiplier': c.multiplier.toJson()
                    })
            ]);
        await entries.append(entry);
        return entry;
      });
}
