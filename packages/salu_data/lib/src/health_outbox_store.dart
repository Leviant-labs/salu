import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import 'database/app_database.dart';

/// Persists health synchronization state in the same transactional SQLite store
/// as the user's records. A worker must still serialize access per export ID.
final class SqliteHealthOutboxStore implements HealthOutboxStore {
  SqliteHealthOutboxStore(this.db);
  final AppDatabase db;
  static const collection = 'health-outbox';

  @override
  Future<HealthOutboxItem?> get(String id) async {
    final row = await (db.select(db.userDocuments)
          ..where((t) => t.collection.equals(collection) & t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : decodeHealthOutbox(row.id, row.payload);
  }

  /// Pending exports can be recovered after the application restarts. Platform
  /// change feeds must be reconciled before dispatch, as required by the port.
  Future<List<HealthOutboxItem>> pending() async {
    final rows = await (db.select(db.userDocuments)
          ..where((t) => t.collection.equals(collection)))
        .get();
    return rows
        .map((row) => decodeHealthOutbox(row.id, row.payload))
        .where((item) => item.state == HealthOutboxState.pending)
        .toList(growable: false);
  }

  @override
  Future<void> put(HealthOutboxItem item) async {
    final id = item.write.externalId;
    final payload = encodeHealthOutbox(item);
    await db.transaction(() async {
      final row = await (db.select(db.userDocuments)
            ..where((t) => t.collection.equals(collection) & t.id.equals(id)))
          .getSingleOrNull();
      if (row != null) {
        final previous = decodeHealthOutbox(row.id, row.payload);
        if (jsonEncode(_writeJson(previous.write)) !=
            jsonEncode(_writeJson(item.write))) {
          throw StateError('Export ID is already bound to different data');
        }
        if (previous.state == HealthOutboxState.externallyDeleted &&
            item.state != HealthOutboxState.externallyDeleted) {
          throw StateError('External deletion requires review');
        }
        if ((previous.state == HealthOutboxState.externallyEdited ||
                previous.state == HealthOutboxState.restoreReviewRequired) &&
            (item.state == HealthOutboxState.pending ||
                item.state == HealthOutboxState.synced)) {
          throw StateError('External edit requires review');
        }
      }
      await db.into(db.userDocuments).insertOnConflictUpdate(
          UserDocumentsCompanion.insert(
              collection: collection,
              id: id,
              revision: (row?.revision ?? 0) + 1,
              payload: payload));
    });
  }
}

Map<String, Object?> _writeJson(NutritionWrite w) => {
      'id': w.externalId,
      'startedAt': w.startedAt.toIso8601String(),
      'energyKcal': w.energyKcal,
      'proteinG': w.proteinG,
      'carbohydrateG': w.carbohydrateG,
      'fatG': w.fatG,
    };

String encodeHealthOutbox(HealthOutboxItem item) {
  final payload =
      jsonEncode({..._writeJson(item.write), 'state': item.state.name});
  decodeHealthOutbox(item.write.externalId, payload);
  return payload;
}

/// Reject corrupt or untrusted archive data before it is used for synchronization.
HealthOutboxItem decodeHealthOutbox(String id, String payload) {
  final data = Map<String, Object?>.from(jsonDecode(payload) as Map);
  if (id.trim().isEmpty || data['id'] != id) {
    throw const FormatException('Invalid health export ID');
  }
  double? amount(String key, {bool required = false}) {
    final value = data[key];
    if (value == null && !required) return null;
    if (value is! num || !value.isFinite || value < 0) {
      throw const FormatException('Invalid health export amount');
    }
    return value.toDouble();
  }

  return HealthOutboxItem(
      NutritionWrite(
          externalId: id,
          startedAt: DateTime.parse(data['startedAt']! as String),
          energyKcal: amount('energyKcal', required: true)!,
          proteinG: amount('proteinG'),
          carbohydrateG: amount('carbohydrateG'),
          fatG: amount('fatG')),
      HealthOutboxState.values.byName(data['state']! as String));
}
