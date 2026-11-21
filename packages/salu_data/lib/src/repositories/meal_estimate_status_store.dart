import 'package:salu_core/salu_core.dart';

import '../database/app_database.dart';
import 'drift_photo_meal_repository.dart';
import 'local_document_store.dart';

/// Persists safe, revision-bound AI meal estimation error codes alongside
/// revision-checked [PhotoMeal] updates without altering [PhotoMeal] JSON.
final class MealEstimateStatusStore {
  const MealEstimateStatusStore(this.db);

  static const int currentVersion = 1;

  final AppDatabase db;

  static String _documentId(String mealId) => 'estimate:$mealId';

  /// Atomically replaces [updated] at [expectedRevision] and records [errorCode]
  /// for the resulting revision (`expectedRevision + 1`), or removes any prior
  /// error document when [errorCode] is `null`.
  ///
  /// Returns `false` and writes no status document if [expectedRevision] is
  /// stale.
  Future<bool> finish(
    PhotoMeal updated,
    int expectedRevision, {
    String? errorCode,
  }) =>
      db.transaction(() async {
        final replaced = await DriftPhotoMealRepository(db)
            .replace(updated, expectedRevision);
        if (!replaced) return false;

        final docId = _documentId(updated.id);
        final documents = LocalDocumentStore(db);
        if (errorCode == null) {
          await documents.remove(docId);
          return true;
        }

        final existing = await documents.read(docId);
        return documents.put(docId, existing?.revision ?? 0, <String, Object?>{
          'version': currentVersion,
          'revision': expectedRevision + 1,
          'errorCode': errorCode,
        });
      });

  /// Returns the persisted safe error code for [mealId] if its stored version
  /// is `1` and its stored meal revision matches [revision]; otherwise `null`.
  Future<String?> errorFor(String mealId, int revision) async {
    final record = await LocalDocumentStore(db).read(_documentId(mealId));
    if (record == null) return null;
    final data = record.data;
    if (data['version'] != currentVersion || data['revision'] != revision) {
      return null;
    }
    final code = data['errorCode'];
    return code is String && code.isNotEmpty ? code : null;
  }
}
