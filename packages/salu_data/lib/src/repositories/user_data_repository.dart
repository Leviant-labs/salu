import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../catalogue/bundled_catalogue_data.dart';
import '../codec/photo_meal_codec.dart';
import '../codec/recipe_codec.dart';
import '../database/app_database.dart';

/// Explicit classification of every `local_documents` namespace.
///
/// Any document ID that does not match a known namespace is rejected visibly
/// during snapshot and restore so new features cannot silently leak or drop
/// user data.
enum DocumentNamespaceKind {
  /// User-authored or user-derived state: exported, replaced on restore, and
  /// cleared on erase.
  user,

  /// Installed catalogue edition metadata (`catalogue-edition:*`): exported
  /// into `catalogueManifest`, preserved on restore and erase.
  catalogueEdition,

  /// Nonpersonal local system state (`search-index-state`): excluded from
  /// user snapshots, preserved on restore and erase.
  system,

  /// Provider connection profiles and credential cleanup metadata: excluded
  /// from user snapshots, cleared on restore and erase.
  providerCredential,
}

/// Thrown when a `local_documents` row has an unclassified namespace.
class UnsupportedDocumentNamespaceException extends FormatException {
  const UnsupportedDocumentNamespaceException(this.documentId)
      : super('Unsupported document namespace: $documentId');

  final String documentId;
}

const Set<String> _exactUserDocumentIds = <String>{
  'planning-profile',
  'onboarding-draft',
  'food-library',
  'recipe-library',
  'cooked-batches',
  'check-in-settings',
};

const List<String> _userDocumentPrefixes = <String>[
  'day:',
  'week:',
  'estimate:',
];

const Set<String> _exactSystemDocumentIds = <String>{
  'search-index-state',
};

const Set<String> _exactProviderDocumentIds = <String>{
  'endpoint-connections',
  'retired-credentials',
  'retired-credential-cleanup',
};

const List<String> _providerDocumentPrefixes = <String>[
  'endpoint-connections:',
  'retired-credential:',
];

/// Classifies a `local_documents.id` into its lifecycle namespace, or returns
/// `null` if the namespace is unknown.
DocumentNamespaceKind? classifyDocumentNamespace(String id) {
  if (_exactUserDocumentIds.contains(id)) {
    return DocumentNamespaceKind.user;
  }
  for (final prefix in _userDocumentPrefixes) {
    if (id.startsWith(prefix) && id.length > prefix.length) {
      return DocumentNamespaceKind.user;
    }
  }
  if (id.startsWith('catalogue-edition:') &&
      id.length > 'catalogue-edition:'.length) {
    return DocumentNamespaceKind.catalogueEdition;
  }
  if (_exactSystemDocumentIds.contains(id)) {
    return DocumentNamespaceKind.system;
  }
  if (_exactProviderDocumentIds.contains(id)) {
    return DocumentNamespaceKind.providerCredential;
  }
  for (final prefix in _providerDocumentPrefixes) {
    if (id.startsWith(prefix) && id.length > prefix.length) {
      return DocumentNamespaceKind.providerCredential;
    }
  }
  return null;
}

/// Consistent, versioned snapshot of all user-owned database tables.
class UserDataSnapshot {
  const UserDataSnapshot({
    required this.entries,
    required this.entryItems,
    required this.meals,
    required this.documents,
    required this.mutations,
    this.catalogueManifest = const <String, Object?>{},
  });

  static const int currentFormat = 1;
  static const int currentSchemaVersion = 4;

  final List<Map<String, Object?>> entries;
  final List<Map<String, Object?>> entryItems;
  final List<Map<String, Object?>> meals;
  final List<Map<String, Object?>> documents;
  final List<Map<String, Object?>> mutations;
  final Map<String, Object?> catalogueManifest;

  Map<String, Object?> toJson() => <String, Object?>{
        'format': currentFormat,
        'schemaVersion': currentSchemaVersion,
        'entries': entries,
        'entryItems': entryItems,
        'meals': meals,
        'documents': documents,
        'mutations': mutations,
        'catalogueManifest': catalogueManifest,
      };

  factory UserDataSnapshot.fromJson(Map<String, Object?> json) {
    final format = json['format'];
    if (format is! int || format != currentFormat) {
      throw FormatException('Unsupported UserDataSnapshot format: $format');
    }
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != currentSchemaVersion) {
      throw FormatException(
        'Unsupported UserDataSnapshot schemaVersion: $schemaVersion',
      );
    }

    final rawManifest = json['catalogueManifest'];
    final Map<String, Object?> manifest;
    if (rawManifest == null) {
      manifest = const <String, Object?>{};
    } else if (rawManifest is Map) {
      manifest = _stringKeyMap(rawManifest, 'catalogueManifest');
    } else {
      throw const FormatException('catalogueManifest must be a JSON object');
    }

    return UserDataSnapshot(
      entries: _rowList(json['entries'], 'entries'),
      entryItems: _rowList(json['entryItems'], 'entryItems'),
      meals: _rowList(json['meals'], 'meals'),
      documents: _rowList(json['documents'], 'documents'),
      mutations: _rowList(json['mutations'], 'mutations'),
      catalogueManifest: manifest,
    );
  }
}

/// Consistent snapshot, validated atomic replace, and user-data erase over
/// [AppDatabase].
class UserDataRepository {
  const UserDataRepository(this._db);

  final AppDatabase _db;

  /// Snapshots all five user tables inside one consistent read transaction.
  Future<UserDataSnapshot> snapshot() => _db.transaction(() async {
        final entryRows = await _db.select(_db.logEntries).get();
        final itemRows = await _db.select(_db.logEntryItems).get();
        final mealRows = await _db.select(_db.photoMeals).get();
        final docRows = await _db.select(_db.localDocuments).get();
        final mutationRows = await _db.select(_db.mealMutations).get();

        final userDocs = <Map<String, Object?>>[];
        final editions = <String, Object?>{};

        for (final row in docRows) {
          final kind = classifyDocumentNamespace(row.id);
          if (kind == null) {
            throw UnsupportedDocumentNamespaceException(row.id);
          }
          switch (kind) {
            case DocumentNamespaceKind.user:
              userDocs.add(<String, Object?>{
                'id': row.id,
                'revision': row.revision,
                'payload': row.payload,
              });
            case DocumentNamespaceKind.catalogueEdition:
              try {
                editions[row.id] = jsonDecode(row.payload);
              } on FormatException {
                editions[row.id] = row.payload;
              }
            case DocumentNamespaceKind.system:
            case DocumentNamespaceKind.providerCredential:
              break;
          }
        }

        final catalogueManifest = <String, Object?>{
          'bundledCatalogue': <String, Object?>{
            'dataset': bundledCatalogueDataset,
            'version': bundledCatalogueDatasetVersion,
            'licence': bundledCatalogueLicence,
          },
          'editions': editions,
        };

        return UserDataSnapshot(
          entries: [
            for (final r in entryRows)
              <String, Object?>{
                'id': r.id,
                'requestId': r.requestId,
                'diaryDate': r.diaryDate,
                'instantUtcMs': r.instantUtcMs,
                'offsetMinutes': r.offsetMinutes,
                'channel': r.channel,
                'recordedAtMs': r.recordedAtMs,
                'revision': r.revision,
                'note': r.note,
              },
          ],
          entryItems: [
            for (final r in itemRows)
              <String, Object?>{
                'id': r.id,
                'entryId': r.entryId,
                'foodId': r.foodId,
                'name': r.name,
                'grams': r.grams,
                'nutrientsJson': r.nutrientsJson,
                'position': r.position,
              },
          ],
          meals: [
            for (final r in mealRows)
              <String, Object?>{
                'id': r.id,
                'diaryDate': r.diaryDate,
                'slot': r.slot,
                'caption': r.caption,
                'createdAtMs': r.createdAtMs,
                'revision': r.revision,
                'photoPath': r.photoPath,
                'itemsJson': r.itemsJson,
                'estimateStatus': r.estimateStatus,
                'recordedOffsetMinutes': r.recordedOffsetMinutes,
              },
          ],
          documents: userDocs,
          mutations: [
            for (final r in mutationRows)
              <String, Object?>{
                'requestId': r.requestId,
                'mealId': r.mealId,
                'operation': r.operation,
                'expectedRevision': r.expectedRevision,
                'resultingRevision': r.resultingRevision,
                'beforeJson': r.beforeJson,
                'afterJson': r.afterJson,
                'createdAtMs': r.createdAtMs,
                'undoExpiresAtMs': r.undoExpiresAtMs,
                'payloadDigest': r.payloadDigest,
              },
          ],
          catalogueManifest: catalogueManifest,
        );
      });

  /// Validates [snapshot] completely without mutating the database.
  ///
  /// Throws [FormatException] on any schema, type, uniqueness, foreign-key,
  /// nutrient-state, diary-date, or document-format violation.
  static void validate(UserDataSnapshot snapshot) {
    _validateSnapshot(snapshot);
  }

  /// Validates [snapshot] completely and replaces all user tables inside one
  /// atomic transaction.
  ///
  /// Preserves replaceable catalogue tables (`catalog_foods`,
  /// `catalog_barcodes`) and nonpersonal system/edition documents
  /// (`catalogue-edition:*`, `search-index-state`). Clears provider/credential
  /// documents (`endpoint-connections`, retired-credential metadata).
  Future<void> replace(UserDataSnapshot snapshot) async {
    final validated = _validateSnapshot(snapshot);

    await _db.transaction(() async {
      await _deleteUserTablesInTransaction();

      await _db.batch((batch) {
        if (validated.entries.isNotEmpty) {
          batch.insertAll(_db.logEntries, validated.entries);
        }
        if (validated.entryItems.isNotEmpty) {
          batch.insertAll(_db.logEntryItems, validated.entryItems);
        }
        if (validated.meals.isNotEmpty) {
          batch.insertAll(_db.photoMeals, validated.meals);
        }
        if (validated.documents.isNotEmpty) {
          batch.insertAll(_db.localDocuments, validated.documents);
        }
        if (validated.mutations.isNotEmpty) {
          batch.insertAll(_db.mealMutations, validated.mutations);
        }
      });
    });
  }

  /// Erases all user tables and provider/credential documents inside one
  /// atomic transaction while preserving replaceable catalogue data and
  /// nonpersonal system metadata.
  Future<void> erase() => _db.transaction(_deleteUserTablesInTransaction);

  Future<void> _deleteUserTablesInTransaction() async {
    await _db.delete(_db.logEntryItems).go();
    await _db.delete(_db.logEntries).go();
    await _db.delete(_db.photoMeals).go();
    await _db.delete(_db.mealMutations).go();

    final existingDocs = await _db.select(_db.localDocuments).get();
    final idsToDelete = <String>[];
    for (final row in existingDocs) {
      final kind = classifyDocumentNamespace(row.id);
      if (kind == DocumentNamespaceKind.catalogueEdition ||
          kind == DocumentNamespaceKind.system) {
        continue;
      }
      idsToDelete.add(row.id);
    }

    const chunkSize = 500;
    for (var i = 0; i < idsToDelete.length; i += chunkSize) {
      final end = (i + chunkSize < idsToDelete.length)
          ? i + chunkSize
          : idsToDelete.length;
      final chunk = idsToDelete.sublist(i, end);
      await (_db.delete(_db.localDocuments)..where((t) => t.id.isIn(chunk)))
          .go();
    }
  }
}

class _ValidatedSnapshot {
  const _ValidatedSnapshot({
    required this.entries,
    required this.entryItems,
    required this.meals,
    required this.documents,
    required this.mutations,
  });

  final List<LogEntriesCompanion> entries;
  final List<LogEntryItemsCompanion> entryItems;
  final List<PhotoMealsCompanion> meals;
  final List<LocalDocumentsCompanion> documents;
  final List<MealMutationsCompanion> mutations;
}

_ValidatedSnapshot _validateSnapshot(UserDataSnapshot snapshot) {
  final entryIds = <String>{};
  final requestIds = <String>{};
  final entryCompanions = <LogEntriesCompanion>[];

  for (var i = 0; i < snapshot.entries.length; i++) {
    final row = snapshot.entries[i];
    final id = _reqNonEmptyString(row, 'id', 'entries[$i]');
    if (!entryIds.add(id)) {
      throw FormatException('Duplicate entry id: $id');
    }
    final requestId = _reqNonEmptyString(row, 'requestId', 'entries[$i]');
    if (!requestIds.add(requestId)) {
      throw FormatException('Duplicate entry requestId: $requestId');
    }
    final diaryDate = _reqNonEmptyString(row, 'diaryDate', 'entries[$i]');
    _parseDiaryDate(diaryDate, 'entries[$i].diaryDate');
    final instantUtcMs = _reqInt(row, 'instantUtcMs', 'entries[$i]');
    final offsetMinutes = _reqInt(row, 'offsetMinutes', 'entries[$i]');
    final channel = _reqNonEmptyString(row, 'channel', 'entries[$i]');
    _parseEnum(EntryChannel.values, channel, 'entries[$i].channel');
    final recordedAtMs = _reqInt(row, 'recordedAtMs', 'entries[$i]');
    final revision = _reqInt(row, 'revision', 'entries[$i]');
    if (revision < 1) {
      throw FormatException('entries[$i].revision must be >= 1');
    }
    final note = _optString(row, 'note', 'entries[$i]');

    entryCompanions.add(
      LogEntriesCompanion.insert(
        id: id,
        requestId: requestId,
        diaryDate: diaryDate,
        instantUtcMs: instantUtcMs,
        offsetMinutes: offsetMinutes,
        channel: channel,
        recordedAtMs: recordedAtMs,
        revision: Value(revision),
        note: Value(note),
      ),
    );
  }

  final itemIds = <String>{};
  final itemCompanions = <LogEntryItemsCompanion>[];

  for (var i = 0; i < snapshot.entryItems.length; i++) {
    final row = snapshot.entryItems[i];
    final id = _reqNonEmptyString(row, 'id', 'entryItems[$i]');
    if (!itemIds.add(id)) {
      throw FormatException('Duplicate entryItem id: $id');
    }
    final entryId = _reqNonEmptyString(row, 'entryId', 'entryItems[$i]');
    if (!entryIds.contains(entryId)) {
      throw FormatException(
        'entryItems[$i] references missing entryId: $entryId',
      );
    }
    final foodId = _optString(row, 'foodId', 'entryItems[$i]');
    final name = _reqNonEmptyString(row, 'name', 'entryItems[$i]');
    final grams = _reqFiniteDouble(row, 'grams', 'entryItems[$i]');
    if (grams < 0) {
      throw FormatException('entryItems[$i].grams must be >= 0');
    }
    final nutrientsJson =
        _reqNonEmptyString(row, 'nutrientsJson', 'entryItems[$i]');
    try {
      final decodedNutrients = jsonDecode(nutrientsJson);
      if (decodedNutrients is! Map) {
        throw const FormatException('nutrientsJson must be a JSON object');
      }
      NutrientProfile.fromJson(
        _stringKeyMap(decodedNutrients, 'entryItems[$i].nutrientsJson'),
      );
    } on FormatException catch (e) {
      throw FormatException(
        'Invalid nutrientsJson in entryItems[$i]: ${e.message}',
      );
    } on ArgumentError catch (e) {
      throw FormatException(
        'Invalid nutrientsJson in entryItems[$i]: ${e.message}',
      );
    }
    final position = _reqInt(row, 'position', 'entryItems[$i]');
    if (position < 0) {
      throw FormatException('entryItems[$i].position must be >= 0');
    }

    itemCompanions.add(
      LogEntryItemsCompanion.insert(
        id: id,
        entryId: entryId,
        foodId: Value(foodId),
        name: name,
        grams: grams,
        nutrientsJson: nutrientsJson,
        position: position,
      ),
    );
  }

  final mealIds = <String>{};
  final mealCompanions = <PhotoMealsCompanion>[];

  for (var i = 0; i < snapshot.meals.length; i++) {
    final row = snapshot.meals[i];
    final id = _reqNonEmptyString(row, 'id', 'meals[$i]');
    if (!mealIds.add(id)) {
      throw FormatException('Duplicate meal id: $id');
    }
    final diaryDate = _reqNonEmptyString(row, 'diaryDate', 'meals[$i]');
    _parseDiaryDate(diaryDate, 'meals[$i].diaryDate');
    final slot = _reqNonEmptyString(row, 'slot', 'meals[$i]');
    _parseEnum(MealSlot.values, slot, 'meals[$i].slot');
    final caption = _reqString(row, 'caption', 'meals[$i]');
    final createdAtMs = _reqInt(row, 'createdAtMs', 'meals[$i]');
    final revision = _reqInt(row, 'revision', 'meals[$i]');
    if (revision < 1) {
      throw FormatException('meals[$i].revision must be >= 1');
    }
    final photoPath = _optString(row, 'photoPath', 'meals[$i]');
    final itemsJson = _reqNonEmptyString(row, 'itemsJson', 'meals[$i]');
    final Object? decodedItems;
    try {
      decodedItems = jsonDecode(itemsJson);
    } on FormatException catch (e) {
      throw FormatException('Invalid itemsJson in meals[$i]: ${e.message}');
    }
    if (decodedItems is! List) {
      throw FormatException('meals[$i].itemsJson must be a JSON list');
    }
    for (var j = 0; j < decodedItems.length; j++) {
      try {
        decodePhotoMealItem(
          decodedItems[j],
          fallbackId: '$id:item:$j',
          strict: false,
        );
      } on FormatException catch (e) {
        throw FormatException(
            'Invalid meal item in meals[$i][$j]: ${e.message}');
      } on ArgumentError catch (e) {
        throw FormatException(
            'Invalid meal item in meals[$i][$j]: ${e.message}');
      }
    }

    final estimateStatus =
        _reqNonEmptyString(row, 'estimateStatus', 'meals[$i]');
    _parseEnum(
      MealEstimateStatus.values,
      estimateStatus,
      'meals[$i].estimateStatus',
    );
    final recordedOffsetMinutes =
        _optInt(row, 'recordedOffsetMinutes', 'meals[$i]');

    mealCompanions.add(
      PhotoMealsCompanion.insert(
        id: id,
        diaryDate: diaryDate,
        slot: slot,
        caption: caption,
        createdAtMs: createdAtMs,
        revision: revision,
        photoPath: Value(photoPath),
        itemsJson: itemsJson,
        estimateStatus: Value(estimateStatus),
        recordedOffsetMinutes: Value(recordedOffsetMinutes),
      ),
    );
  }

  final docIds = <String>{};
  final docCompanions = <LocalDocumentsCompanion>[];

  for (var i = 0; i < snapshot.documents.length; i++) {
    final row = snapshot.documents[i];
    final id = _reqNonEmptyString(row, 'id', 'documents[$i]');
    if (!docIds.add(id)) {
      throw FormatException('Duplicate document id: $id');
    }
    final kind = classifyDocumentNamespace(id);
    if (kind != DocumentNamespaceKind.user) {
      throw FormatException(
        'Document "$id" is not an allowed user document namespace',
      );
    }
    final revision = _reqInt(row, 'revision', 'documents[$i]');
    if (revision < 1) {
      throw FormatException('documents[$i].revision must be >= 1');
    }
    final payload = _reqNonEmptyString(row, 'payload', 'documents[$i]');
    _validateDocumentPayload(id, payload);

    docCompanions.add(
      LocalDocumentsCompanion.insert(
        id: id,
        revision: revision,
        payload: payload,
      ),
    );
  }

  final mutationRequestIds = <String>{};
  final mutationCompanions = <MealMutationsCompanion>[];

  for (var i = 0; i < snapshot.mutations.length; i++) {
    final row = snapshot.mutations[i];
    final requestId = _reqNonEmptyString(row, 'requestId', 'mutations[$i]');
    if (!mutationRequestIds.add(requestId)) {
      throw FormatException('Duplicate mutation requestId: $requestId');
    }
    final mealId = _reqNonEmptyString(row, 'mealId', 'mutations[$i]');
    final operation = _reqNonEmptyString(row, 'operation', 'mutations[$i]');
    final expectedRevision = _reqInt(row, 'expectedRevision', 'mutations[$i]');
    final resultingRevision =
        _reqInt(row, 'resultingRevision', 'mutations[$i]');
    if (expectedRevision < 0 || resultingRevision < 0) {
      throw FormatException('mutations[$i] revisions must be >= 0');
    }
    final beforeJson = _optString(row, 'beforeJson', 'mutations[$i]');
    if (beforeJson != null) {
      _validatePhotoMealJson(beforeJson, 'mutations[$i].beforeJson');
    }
    final afterJson = _optString(row, 'afterJson', 'mutations[$i]');
    if (afterJson != null) {
      _validatePhotoMealJson(afterJson, 'mutations[$i].afterJson');
    }
    final createdAtMs = _reqInt(row, 'createdAtMs', 'mutations[$i]');
    final undoExpiresAtMs = _optInt(row, 'undoExpiresAtMs', 'mutations[$i]');
    final payloadDigest =
        _reqNonEmptyString(row, 'payloadDigest', 'mutations[$i]');

    mutationCompanions.add(
      MealMutationsCompanion.insert(
        requestId: requestId,
        mealId: mealId,
        operation: operation,
        expectedRevision: expectedRevision,
        resultingRevision: resultingRevision,
        beforeJson: Value(beforeJson),
        afterJson: Value(afterJson),
        createdAtMs: createdAtMs,
        undoExpiresAtMs: Value(undoExpiresAtMs),
        payloadDigest: payloadDigest,
      ),
    );
  }

  return _ValidatedSnapshot(
    entries: entryCompanions,
    entryItems: itemCompanions,
    meals: mealCompanions,
    documents: docCompanions,
    mutations: mutationCompanions,
  );
}

void _validateDocumentPayload(String id, String payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } on FormatException catch (e) {
    throw FormatException('Invalid JSON in document "$id": ${e.message}');
  }
  if (decoded is! Map) {
    throw FormatException('Document "$id" payload must be a JSON object');
  }
  final map = _stringKeyMap(decoded, 'document "$id"');

  final rawVersion = map['version'];
  if (rawVersion != null) {
    if (rawVersion is! int || rawVersion < 1 || rawVersion > 1) {
      throw FormatException(
        'Unsupported version $rawVersion in document "$id"',
      );
    }
  }

  if (id.startsWith('day:')) {
    _parseDiaryDate(id.substring('day:'.length), 'document "$id"');
  } else if (id.startsWith('week:')) {
    _parseDiaryDate(id.substring('week:'.length), 'document "$id"');
  } else if (id == 'planning-profile') {
    try {
      PlanningProfile.fromJson(map);
    } on FormatException catch (e) {
      throw FormatException('Invalid planning-profile document: ${e.message}');
    } on ArgumentError catch (e) {
      throw FormatException('Invalid planning-profile document: ${e.message}');
    }
  }
}

void _validatePhotoMealJson(String raw, String context) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw FormatException('Invalid JSON in $context: ${e.message}');
  }
  if (decoded is! Map) {
    throw FormatException('$context must be a JSON object');
  }
  try {
    decodePhotoMeal(Map<String, dynamic>.from(decoded));
  } on FormatException catch (e) {
    throw FormatException('Invalid PhotoMeal in $context: ${e.message}');
  } on ArgumentError catch (e) {
    throw FormatException('Invalid PhotoMeal in $context: ${e.message}');
  }
}

void _parseDiaryDate(String value, String context) {
  try {
    DiaryDate.parse(value);
  } on FormatException catch (e) {
    throw FormatException('Invalid diary date in $context: ${e.message}');
  } on ArgumentError catch (e) {
    throw FormatException('Invalid diary date in $context: ${e.message}');
  }
}

T _parseEnum<T extends Enum>(List<T> values, String name, String context) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  throw FormatException('Invalid enum value "$name" in $context');
}

List<Map<String, Object?>> _rowList(Object? raw, String field) {
  if (raw is! List) {
    throw FormatException('Expected list for "$field"');
  }
  final out = <Map<String, Object?>>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) {
      throw FormatException('Expected object at $field[$i]');
    }
    out.add(_stringKeyMap(item, '$field[$i]'));
  }
  return out;
}

Map<String, Object?> _stringKeyMap(Map<Object?, Object?> raw, String context) {
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw FormatException('Non-string key in $context');
    }
    out[key] = entry.value;
  }
  return out;
}

String _reqNonEmptyString(
    Map<String, Object?> row, String key, String context) {
  final value = row[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$context.$key must be a non-empty string');
  }
  return value;
}

String _reqString(Map<String, Object?> row, String key, String context) {
  final value = row[key];
  if (value is! String) {
    throw FormatException('$context.$key must be a string');
  }
  return value;
}

String? _optString(Map<String, Object?> row, String key, String context) {
  final value = row[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$context.$key must be a string or null');
  }
  return value;
}

int _reqInt(Map<String, Object?> row, String key, String context) {
  final value = row[key];
  if (value is! int) {
    throw FormatException('$context.$key must be an int');
  }
  return value;
}

int? _optInt(Map<String, Object?> row, String key, String context) {
  final value = row[key];
  if (value == null) return null;
  if (value is! int) {
    throw FormatException('$context.$key must be an int or null');
  }
  return value;
}

double _reqFiniteDouble(Map<String, Object?> row, String key, String context) {
  final value = row[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('$context.$key must be a finite number');
  }
  return value.toDouble();
}
