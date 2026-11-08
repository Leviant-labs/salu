import 'dart:convert';
import 'package:salu_core/salu_core.dart';
import 'document_validation.dart';
import 'database/app_database.dart';
import 'workspace_store.dart';
import 'health_outbox_store.dart';
import 'repositories/drift_food_repository.dart';

/// Versioned full database archive. Secrets have no database representation.
final class ArchiveService {
  ArchiveService(this.db);
  final AppDatabase db;
  static const tables = [
    'catalog_datasets',
    'catalog_foods',
    'log_entries',
    'log_entry_items',
    'user_documents',
    'applied_commands'
  ];
  Future<String> exportJson() async => db.transaction(() async {
        final data = <String, Object?>{};
        for (final table in tables) {
          data[table] = (await db
                  .customSelect('SELECT * FROM $table ORDER BY rowid')
                  .get())
              .map((r) => r.data)
              .toList();
        }
        return jsonEncode(
            {'format': 'salu-archive', 'version': 3, 'tables': data});
      });
  Future<void> _load(AppDatabase target, Map<String, Object?> root) async {
    if (root['format'] != 'salu-archive' ||
        (root['version'] != 2 && root['version'] != 3)) {
      throw const FormatException('Unsupported archive');
    }
    final data = Map<String, Object?>.from(root['tables']! as Map);
    final expectedTables = root['version'] == 2
        ? tables.where((t) => t != 'catalog_datasets').toList()
        : tables;
    if (data.keys.toSet().difference(expectedTables.toSet()).isNotEmpty ||
        data.length != expectedTables.length) {
      throw const FormatException('Unexpected tables');
    }
    for (final table in expectedTables) {
      final columns =
          (await target.customSelect('PRAGMA table_info($table)').get())
              .map((r) => r.read<String>('name'))
              .toSet();
      for (final value in data[table]! as List) {
        final row = Map<String, Object?>.from(value as Map);
        if (root['version'] == 2 && table == 'catalog_foods') {
          row['details_json'] = '{}';
          row['search_aliases'] = '';
        }
        if (row.keys.toSet().difference(columns).isNotEmpty ||
            !columns.every(row.containsKey)) {
          throw const FormatException('Invalid columns');
        }
        if (row.values.any((v) => v != null && v is! num && v is! String)) {
          throw const FormatException('Non-scalar cell');
        }
        if (table == 'user_documents') {
          if (!userCollections.contains(row['collection'])) {
            throw const FormatException('Unknown document type');
          }
          if (jsonDecode(row['payload']! as String) is! Map ||
              (row['revision']! as int) < 1) {
            throw const FormatException('Invalid document');
          }
        }
        if (table == 'user_documents') {
          validateUserDocument(
              row['collection']! as String,
              Map<String, Object?>.from(
                  jsonDecode(row['payload']! as String) as Map));
        }
        if (table == 'user_documents' &&
            row['collection'] == SqliteHealthOutboxStore.collection) {
          final item = decodeHealthOutbox(
              row['id']! as String, row['payload']! as String);
          // A restored device has no verified connection or change-feed cursor.
          // Never automatically replay an export from a backup.
          row['payload'] = encodeHealthOutbox(HealthOutboxItem(
              item.write,
              item.state == HealthOutboxState.externallyDeleted
                  ? HealthOutboxState.externallyDeleted
                  : HealthOutboxState.restoreReviewRequired));
        }
        if (table == 'catalog_foods') {
          FoodUnit.values.byName(row['basis_unit']! as String);
          if (!Exact.parse(row['basis_value']! as String).positive) {
            throw const FormatException('Invalid food basis');
          }
          if ((row['name']! as String).trim().isEmpty) {
            throw const FormatException('Missing food name');
          }
          NutrientProfile.fromJson(Map<String, Object?>.from(
              jsonDecode(row['per100g_json']! as String) as Map));
        }
        if (table == 'log_entries') {
          DiaryDate.parse(row['diary_date']! as String);
          if ((row['revision']! as int) < 1) {
            throw const FormatException('Invalid diary revision');
          }
          EventStamp(
              instant: DateTime.fromMillisecondsSinceEpoch(
                  row['instant_utc_ms']! as int,
                  isUtc: true),
              offsetMinutes: row['offset_minutes']! as int);
        }
        if (table == 'log_entry_items') {
          NutrientProfile.fromJson(Map<String, Object?>.from(
              jsonDecode(row['nutrients_json']! as String) as Map));
          if (row['quantity_json'] != null) {
            FoodAmount.fromJson(Map<String, Object?>.from(
                jsonDecode(row['quantity_json']! as String) as Map));
          }
          if (row['grams'] != null &&
              ((row['grams']! as num) < 0 ||
                  !(row['grams']! as num).isFinite)) {
            throw const FormatException('Invalid mass');
          }
        }
        await target.customStatement(
            'INSERT INTO $table (${row.keys.join(',')}) VALUES (${List.filled(row.length, '?').join(',')})',
            row.values.toList());
        if (table == 'catalog_foods') {
          final food =
              await DriftFoodRepository(target).findById(row['id']! as String);
          DriftFoodRepository.validateFoods([food!]);
        }
        if (table == 'catalog_datasets' &&
            ((row['food_count']! as int) < 1 ||
                ['id', 'version', 'licence', 'attribution', 'review_id']
                    .any((k) => (row[k]! as String).trim().isEmpty))) {
          throw const FormatException('Invalid dataset manifest');
        }
      }
    }
    if ((await target.customSelect('PRAGMA foreign_key_check').get())
        .isNotEmpty) {
      throw const FormatException('Broken references');
    }
  }

  /// Replace only after full staging validation. All live changes are atomic.
  Future<void> restoreJson(String archive, {required bool confirmed}) async {
    if (!confirmed) throw StateError('RESTORE_CONFIRMATION_REQUIRED');
    if (archive.length > 50 * 1024 * 1024) {
      throw const FormatException('Archive too large');
    }
    final root = Map<String, Object?>.from(jsonDecode(archive) as Map);
    final stage = AppDatabase.memory();
    try {
      await stage.transaction(() => _load(stage, root));
    } finally {
      await stage.close();
    }
    await db.transaction(() async {
      for (final table in tables.reversed) {
        await db.customStatement('DELETE FROM $table');
      }
      await _load(db, root);
    });
  }

  Future<String> exportCsv() async {
    String cell(Object? v) {
      var value = (v ?? '').toString();
      // CSV quoting alone does not prevent spreadsheet apps from evaluating
      // a user-provided food name as a formula. Keep numeric database values
      // numeric; prefix risky strings, including leading whitespace/control
      // characters that spreadsheet importers may ignore.
      if (v is String &&
          (RegExp(r'^[\t\r\n]').hasMatch(value) ||
              RegExp(r'^\s*[=+\-@]').hasMatch(value))) {
        value = "'$value";
      }
      return '"${value.replaceAll('"', '""')}"';
    }
    final rows = await db
        .customSelect(
            'SELECT e.id,e.diary_date,e.instant_utc_ms,e.offset_minutes,e.revision,i.name,i.grams,i.quantity_json,i.nutrients_json,i.source_json FROM log_entries e JOIN log_entry_items i ON e.id=i.entry_id ORDER BY e.diary_date,e.instant_utc_ms,i.position')
        .get();
    const keys = [
      'id',
      'diary_date',
      'instant_utc_ms',
      'offset_minutes',
      'revision',
      'name',
      'grams',
      'quantity_json',
      'nutrients_json',
      'source_json'
    ];
    return [
      keys.map(cell).join(','),
      ...rows.map((r) => keys.map((k) => cell(r.data[k])).join(','))
    ].join('\r\n');
  }

  Future<void> deleteLocalData({required bool confirmed}) async {
    if (!confirmed) throw StateError('DELETE_CONFIRMATION_REQUIRED');
    await db.customStatement('PRAGMA secure_delete=ON');
    await db.transaction(() async {
      for (final table in tables.reversed) {
        await db.customStatement('DELETE FROM $table');
      }
    });
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await db.customStatement('VACUUM');
  }
}
