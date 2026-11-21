import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:salu_data/salu_data.dart';

/// Persisted SQLite fixture for device integration tests.
///
/// Each instance isolates its database file inside a unique directory under
/// the device temporary directory and never touches the app's live database.
class DeviceTestDatabase {
  DeviceTestDatabase._({
    required Directory tempDir,
    required File dbFile,
    required AppDatabase db,
  })  : _tempDir = tempDir,
        _dbFile = dbFile,
        _db = db,
        _meals = DriftPhotoMealRepository(db);

  final Directory _tempDir;
  final File _dbFile;
  AppDatabase _db;
  DriftPhotoMealRepository _meals;
  bool _disposed = false;

  /// Creates a new isolated database backed by a unique temp directory.
  static Future<DeviceTestDatabase> create() async {
    final baseDir = await _resolveTempBase();
    final tempDir = await baseDir.createTemp('salu_device_smoke_');
    final dbFile = File('${tempDir.path}${Platform.pathSeparator}diary.sqlite');
    final db = AppDatabase(NativeDatabase(dbFile));
    return DeviceTestDatabase._(tempDir: tempDir, dbFile: dbFile, db: db);
  }

  static Future<Directory> _resolveTempBase() async {
    try {
      return await getTemporaryDirectory();
    } on MissingPluginException {
      return Directory.systemTemp;
    }
  }

  /// Open database handle for overriding `databaseProvider`.
  AppDatabase get db => _db;

  /// Photo-meal repository backed by [db].
  DriftPhotoMealRepository get meals => _meals;

  /// Closes the current database handle and reopens the same file on disk.
  Future<void> reopen() async {
    if (_disposed) {
      throw StateError('DeviceTestDatabase has already been disposed');
    }
    await _db.close();
    _db = AppDatabase(NativeDatabase(_dbFile));
    _meals = DriftPhotoMealRepository(_db);
  }

  /// Closes the database before deleting only this fixture's temp directory.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _db.close();
    if (await _tempDir.exists()) {
      await _tempDir.delete(recursive: true);
    }
  }
}
