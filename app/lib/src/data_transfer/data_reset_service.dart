import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:salu_data/salu_data.dart';

import '../assistant/credential_store.dart';
import '../assistant/operation_fence.dart';
import 'data_write_gate.dart';

/// Resumable, crash-safe local data deletion service.
///
/// Acquires [DataWriteGate.exclusive] and invalidates [OperationFence] before
/// writing a durable `salu-reset-pending.json` marker so a rejected concurrent
/// exclusive operation never leaves an orphan marker on disk. If interrupted at
/// any phase, [resumeIfPending] idempotently completes deletion on next launch.
final class DataResetService {
  DataResetService({
    required UserDataRepository data,
    required CredentialStore credentials,
    required OperationFence fence,
    required DataWriteGate gate,
    required Future<Directory> Function() supportDirectory,
    Future<Directory> Function()? stagingDirectory,
    VoidCallback? onReset,
    @visibleForTesting Future<void> Function(String phase)? onPhaseForTest,
  })  : _data = data,
        _credentials = credentials,
        _fence = fence,
        _gate = gate,
        _supportDirectory = supportDirectory,
        _stagingDirectory = stagingDirectory,
        _onReset = onReset,
        _onPhaseForTest = onPhaseForTest;

  /// Name of the durable reset-in-progress marker in the support directory.
  static const String markerFileName = 'salu-reset-pending.json';

  static const List<String> _ownedSubdirectories = <String>[
    'meal-images',
    'thumbnails',
    'transfer-staging',
  ];

  static const String _legacyProfileFileName = 'planning_profile_v1.json';
  static const String _legacyWeekPrefix = 'week_plan_v1_';
  static const String _legacyWeekSuffix = '.json';
  static const String _credentialCleanupMarkerName =
      'pending-credential-cleanup.marker';

  final UserDataRepository _data;
  final CredentialStore _credentials;
  final OperationFence _fence;
  final DataWriteGate _gate;
  final Future<Directory> Function() _supportDirectory;
  final Future<Directory> Function()? _stagingDirectory;
  final VoidCallback? _onReset;
  final Future<void> Function(String phase)? _onPhaseForTest;

  /// Erases all local user data, owned media/staging directories, legacy JSON
  /// files, and `salu.*` credentials.
  Future<void> erase() async {
    await _gate.exclusive(() async {
      _fence.invalidate();

      final supportDir = await _supportDirectory();
      await supportDir.create(recursive: true);
      final marker = _markerFile(supportDir);
      await marker.writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );

      await _executeEraseSteps(supportDir, marker);
    });
  }

  /// Completes an interrupted [erase] if `salu-reset-pending.json` is present.
  ///
  /// Returns immediately when no reset marker exists.
  Future<void> resumeIfPending() async {
    final supportDir = await _supportDirectory();
    final marker = _markerFile(supportDir);
    if (!await marker.exists()) return;

    await _gate.exclusive(() async {
      _fence.invalidate();
      if (!await marker.exists()) return;
      await _executeEraseSteps(supportDir, marker);
    });
  }

  Future<void> _executeEraseSteps(Directory supportDir, File marker) async {
    await _onPhaseForTest?.call('after_marker');

    // 1. Clear all user tables, journals, and user/provider documents.
    //    Preserves catalog_foods, catalog_barcodes, catalogue-edition:*,
    //    and search-index-state.
    await _data.erase();
    await _onPhaseForTest?.call('after_db');

    // 2. Delete ONLY exact enumerated app-owned directories inside supportDir.
    for (final name in _ownedSubdirectories) {
      final dir = Directory('${supportDir.path}${Platform.pathSeparator}$name');
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    // Also clean Salu archive staging subdirectories (export-*/inspect-*)
    // inside stagingDirectory if provided, without touching unrelated temp files.
    if (_stagingDirectory != null) {
      final stagingRoot = await _stagingDirectory();
      if (await stagingRoot.exists()) {
        await for (final entity in stagingRoot.list(followLinks: false)) {
          if (entity is Directory) {
            final base = _basename(entity.path);
            if (base.startsWith('export-') || base.startsWith('inspect-')) {
              await entity.delete(recursive: true);
            }
          }
        }
      }
    }

    // 3. Delete recognized legacy JSON files so they cannot reimport and
    //    resurrect erased data.
    if (await supportDir.exists()) {
      await for (final entity in supportDir.list(followLinks: false)) {
        if (entity is! File) continue;
        final base = _basename(entity.path);
        final isLegacyProfile = base == _legacyProfileFileName;
        final isLegacyWeek = base.startsWith(_legacyWeekPrefix) &&
            base.endsWith(_legacyWeekSuffix);
        final isCredMarker = base == _credentialCleanupMarkerName;
        if (isLegacyProfile || isLegacyWeek || isCredMarker) {
          await entity.delete();
        }
      }
    }
    await _onPhaseForTest?.call('after_media');

    // 4. Clear all salu.* credentials, leaving unrelated credentials untouched.
    await _credentials.clearSaluCredentials();
    await _onPhaseForTest?.call('after_credentials');

    // 5. Remove reset marker ONLY after all owned components succeed.
    if (await marker.exists()) {
      await marker.delete();
    }

    // 6. Notify app state (providers, active estimates, connections).
    _onReset?.call();
  }

  File _markerFile(Directory supportDir) =>
      File('${supportDir.path}${Platform.pathSeparator}$markerFileName');

  static String _basename(String path) {
    final sep = path.lastIndexOf(Platform.pathSeparator);
    final slash = path.lastIndexOf('/');
    final cut = sep > slash ? sep : slash;
    return cut < 0 ? path : path.substring(cut + 1);
  }
}
