import 'package:salu_core/salu_core.dart';
import 'database/app_database.dart';
import 'workspace_store.dart';

/// Guided choices and the existing declaration goal are one atomic edit.
final class NutritionProfileStore {
  NutritionProfileStore(this.db);
  final AppDatabase db;
  Future<StoredDocument?> read() =>
      LocalWorkspace(db).read('nutrition-profile-v1', 'current');

  Future<StoredDocument> save({required String requestId,
    required int expectedRevision, required NutritionProfile profile}) =>
      db.transaction(() async {
        final workspace = LocalWorkspace(db);
        final replayed = await (db.select(db.appliedCommands)
              ..where((table) => table.requestId.equals(requestId)))
            .getSingleOrNull();
        final data = profile.toJson();
        final revision = await workspace.put(requestId: requestId,
            collection: 'nutrition-profile-v1', id: 'current',
            expectedRevision: expectedRevision, data: data);
        final health = await workspace.read('health-declaration', 'current');
        if (replayed == null && health?.data['goal'] != profile.goal.name) {
          await workspace.put(requestId: '$requestId:health',
              collection: 'health-declaration', id: 'current',
              expectedRevision: health?.revision ?? 0,
              data: {...const AdultHealthDeclaration().toJson(),
                ...?health?.data, 'goal': profile.goal.name});
        }
        return StoredDocument('nutrition-profile-v1', 'current', revision, data);
      });
}
