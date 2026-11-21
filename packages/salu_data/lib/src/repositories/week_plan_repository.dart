import 'package:salu_core/salu_core.dart';

import '../codec/recipe_codec.dart';
import 'local_document_store.dart';

/// Pure-Dart persistence adapter for weekly meal plans in [LocalDocumentStore].
final class WeekPlanRepository {
  const WeekPlanRepository(this.documents);

  final LocalDocumentStore documents;

  static String keyFor(DateTime week) =>
      'week:${week.toIso8601String().substring(0, 10)}';

  Future<WeekPlan?> loadIfPresent(DateTime monday) async {
    final key = keyFor(monday);
    final saved = await documents.read(key);
    if (saved == null) return null;
    final plan =
        WeekPlan.fromJson(monday, saved.data, revision: saved.revision);
    if (!isCurrentDocumentVersion(
      saved.data,
      WeekPlan.currentVersion,
      documentName: 'week-plan',
    )) {
      final migrated = <String, Object?>{
        ...saved.data,
        'version': WeekPlan.currentVersion,
      };
      if (await documents.put(key, saved.revision, migrated)) {
        return plan.copyWith(revision: saved.revision + 1);
      }
      final latest = await documents.read(key);
      if (latest != null) {
        return WeekPlan.fromJson(
          monday,
          latest.data,
          revision: latest.revision,
        );
      }
    }
    return plan;
  }

  Future<WeekPlan> load(DateTime monday) async =>
      await loadIfPresent(monday) ?? WeekPlan(monday);

  Future<void> save(WeekPlan plan) async {
    final key = keyFor(plan.monday);
    final existing = await documents.read(key);
    if (existing != null) {
      isCurrentDocumentVersion(
        existing.data,
        WeekPlan.currentVersion,
        documentName: 'week-plan',
      );
    }
    if (!await documents.put(key, plan.revision, {
      ...?existing?.data,
      ...plan.toJson(),
    })) {
      throw StateError('This week changed. Reload before saving.');
    }
  }
}
