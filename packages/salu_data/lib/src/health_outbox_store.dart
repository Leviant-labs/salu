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
  ///
  /// Ordered by start time then export ID so a recovery pass is deterministic.
  @override
  Future<List<HealthOutboxItem>> pending() async {
    final rows = await (db.select(db.userDocuments)
          ..where((t) => t.collection.equals(collection)))
        .get();
    final items = rows
        .map((row) => decodeHealthOutbox(row.id, row.payload))
        .where((item) => item.state == HealthOutboxState.pending)
        .toList();
    items.sort((a, b) {
      final byTime = a.write.startedAt.compareTo(b.write.startedAt);
      if (byTime != 0) return byTime;
      return a.write.externalId.compareTo(b.write.externalId);
    });
    return List<HealthOutboxItem>.unmodifiable(items);
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
        if (!_sameWrite(previous.write, item.write)) {
          throw StateError('Export ID is already bound to different data');
        }
        if (previous.state == HealthOutboxState.externallyDeleted &&
            item.state != HealthOutboxState.externallyDeleted) {
          throw StateError('External deletion requires review');
        }
        if (previous.state == HealthOutboxState.synced &&
            item.state == HealthOutboxState.pending) {
          throw StateError('Synced export cannot be re-queued');
        }
        if ((previous.state == HealthOutboxState.externallyEdited ||
                previous.state == HealthOutboxState.restoreReviewRequired) &&
            (item.state == HealthOutboxState.pending ||
                item.state == HealthOutboxState.synced)) {
          throw StateError('External edit requires review');
        }
        // Compare-and-swap on the visible revision so a second writer cannot
        // silently overwrite a reconciliation state it did not observe.
        final updated = await (db.update(db.userDocuments)
              ..where((t) =>
                  t.collection.equals(collection) &
                  t.id.equals(id) &
                  t.revision.equals(row.revision)))
            .write(UserDocumentsCompanion(
                revision: Value(row.revision + 1),
                payload: Value(payload)));
        if (updated != 1) {
          throw StateError('Concurrent health outbox update');
        }
        return;
      }
      await db.into(db.userDocuments).insert(UserDocumentsCompanion.insert(
          collection: collection, id: id, revision: 1, payload: payload));
    });
  }
}

Map<String, Object?> _writeJson(NutritionWrite w) => {
      'id': w.externalId,
      // Store the instant explicitly. A local ISO string carries no offset and
      // would be reinterpreted if the device timezone changed before a retry.
      'startedAt': w.startedAt.toUtc().toIso8601String(),
      'energyKcal': w.energyKcal,
      'proteinG': w.proteinG,
      'carbohydrateG': w.carbohydrateG,
      'fatG': w.fatG,
    };

bool _sameWrite(NutritionWrite a, NutritionWrite b) =>
    a.externalId == b.externalId &&
    a.startedAt.isAtSameMomentAs(b.startedAt) &&
    a.energyKcal == b.energyKcal &&
    a.proteinG == b.proteinG &&
    a.carbohydrateG == b.carbohydrateG &&
    a.fatG == b.fatG;

String encodeHealthOutbox(HealthOutboxItem item) {
  final payload =
      jsonEncode({..._writeJson(item.write), 'state': item.state.name});
  decodeHealthOutbox(item.write.externalId, payload);
  return payload;
}

/// Reject corrupt or untrusted archive data before it is used for synchronization.
HealthOutboxItem decodeHealthOutbox(String id, String payload) {
  if (id.trim().isEmpty) {
    throw const FormatException('Invalid health export ID');
  }
  final data = _decodeHealthPayload(payload);
  if (data['id'] != id) {
    throw const FormatException('Invalid health export ID');
  }
  final startedAt = data['startedAt'];
  if (startedAt is! String) {
    throw const FormatException('Invalid health export time');
  }
  final started = DateTime.tryParse(startedAt);
  if (started == null) {
    throw const FormatException('Invalid health export time');
  }
  double? amount(String key, {bool required = false}) {
    final value = data[key];
    if (value == null && !required) return null;
    if (value is! num || !value.isFinite || value < 0) {
      throw const FormatException('Invalid health export amount');
    }
    return value.toDouble();
  }

  final stateName = data['state'];
  if (stateName is! String) {
    throw const FormatException('Invalid health export state');
  }
  final state = _stateByName(stateName);
  return HealthOutboxItem(
      NutritionWrite(
          externalId: id,
          startedAt: started,
          energyKcal: amount('energyKcal', required: true)!,
          proteinG: amount('proteinG'),
          carbohydrateG: amount('carbohydrateG'),
          fatG: amount('fatG')),
      state);
}

Map<String, Object?> _decodeHealthPayload(String payload) {
  final Object? decoded = jsonDecode(payload);
  if (decoded is! Map) {
    throw const FormatException('Invalid health export payload');
  }
  return Map<String, Object?>.from(decoded);
}

HealthOutboxState _stateByName(String name) {
  for (final candidate in HealthOutboxState.values) {
    if (candidate.name == name) return candidate;
  }
  throw const FormatException('Invalid health export state');
}
