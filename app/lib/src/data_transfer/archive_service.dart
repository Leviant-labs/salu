import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:salu_data/salu_data.dart';

import '../assistant/credential_store.dart';
import '../assistant/operation_fence.dart';
import '../media/managed_media_store.dart';
import 'archive_codec.dart';
import 'archive_crypto.dart';
import 'data_write_gate.dart';

/// Validated, password-free preview of an inspected encrypted Salu archive.
///
/// Bound to its temporary staging directory by [contentDigest]; any tampering
/// or removal of staged files invalidates the preview before restore begins.
class RestorePreview {
  const RestorePreview({
    required this.stagingDirPath,
    required this.contentDigest,
    required this.mealCount,
    required this.entryCount,
    required this.documentCount,
    required this.mutationCount,
    required this.mediaCount,
    required this.mediaOmitted,
    required this.catalogueManifest,
  });

  final String stagingDirPath;
  final String contentDigest;
  final int mealCount;
  final int entryCount;
  final int documentCount;
  final int mutationCount;
  final int mediaCount;
  final bool mediaOmitted;
  final Map<String, Object?> catalogueManifest;
}

/// Orchestrates encrypted archive export, staged inspection, and atomic
/// replace-only restore with write-gate fencing and credential cleanup.
final class ArchiveService {
  ArchiveService({
    required UserDataRepository data,
    required ManagedMediaStore media,
    required OperationFence fence,
    required CredentialStore credentials,
    required DataWriteGate gate,
    required Future<Directory> Function() stagingDirectory,
    VoidCallback? onRestored,
    Future<String> Function(XFile image)? stageMediaOverride,
  })  : _data = data,
        _media = media,
        _fence = fence,
        _credentials = credentials,
        _gate = gate,
        _stagingDirectory = stagingDirectory,
        _onRestored = onRestored,
        _stageMediaOverride = stageMediaOverride;

  static const String _cleanupMarkerName = 'pending-credential-cleanup.marker';

  final UserDataRepository _data;
  final ManagedMediaStore _media;
  final OperationFence _fence;
  final CredentialStore _credentials;
  final DataWriteGate _gate;
  final Future<Directory> Function() _stagingDirectory;
  final VoidCallback? _onRestored;
  final Future<String> Function(XFile image)? _stageMediaOverride;
  int _stageCounter = 0;

  /// Exports a consistent snapshot of all user data (and optionally referenced
  /// managed media) into a password-encrypted Salu archive.
  Future<Uint8List> export({
    required String password,
    required bool includeMedia,
  }) async {
    final snapshot = await _data.snapshot();
    final mediaPaths = <String, String>{};

    if (includeMedia) {
      final referenced = _collectReferencedMediaRefs(snapshot);
      for (final ref in referenced) {
        if (!ref.startsWith(ManagedMediaStore.refPrefix)) continue;
        final id = ref.substring(ManagedMediaStore.refPrefix.length);
        if (!isValidOpaqueMediaId(id)) {
          throw FormatException('Invalid managed media reference: $ref');
        }
        final file = await _media.resolve(ref);
        if (file == null) {
          throw FormatException('Referenced media file is missing: $ref');
        }
        mediaPaths[id] = file.path;
      }
    }

    final stageDir = await _createUniqueStageDir('export');
    try {
      final records = snapshot.toJson();
      final manifest = snapshot.catalogueManifest;
      final stagePath = stageDir.path;
      return await Isolate.run(() async {
        final plainZip = File('$stagePath${Platform.pathSeparator}plain.zip');
        final encrypted =
            File('$stagePath${Platform.pathSeparator}archive.salu');
        final mediaFiles = <String, File>{
          for (final entry in mediaPaths.entries) entry.key: File(entry.value),
        };
        await encodeArchiveToFile(
          records: records,
          mediaFiles: mediaFiles,
          catalogueManifest: manifest,
          outputFile: plainZip,
          mediaOmitted: !includeMedia,
        );
        await encryptFileToFile(plainZip, encrypted, password);
        return encrypted.readAsBytes();
      });
    } finally {
      await _deleteDirQuietly(stageDir);
    }
  }

  /// Decrypts, decodes, and validates [encrypted] in a temporary staging
  /// directory and returns a password-free [RestorePreview].
  Future<RestorePreview> inspect(Uint8List encrypted, String password) async {
    final stageDir = await _createUniqueStageDir('inspect');
    try {
      final inputFile =
          File('${stageDir.path}${Platform.pathSeparator}input.salu');
      await inputFile.writeAsBytes(encrypted, flush: true);

      final stagePath = stageDir.path;
      final inspected = await Isolate.run(() async {
        final inFile = File('$stagePath${Platform.pathSeparator}input.salu');
        final plainZip = File('$stagePath${Platform.pathSeparator}plain.zip');
        await decryptFileToFile(inFile, plainZip, password);
        final contents = await decodeArchiveFromFile(plainZip);
        final snapshot = UserDataSnapshot.fromJson(contents.records);

        final validatedDir =
            await Directory('$stagePath${Platform.pathSeparator}validated')
                .create(recursive: true);
        final recordsFile = File(
          '${validatedDir.path}${Platform.pathSeparator}records.json',
        );
        await recordsFile.writeAsString(
          jsonEncode(snapshot.toJson()),
          flush: true,
        );

        final mediaDir = await Directory(
          '${validatedDir.path}${Platform.pathSeparator}media',
        ).create(recursive: true);
        final sortedIds = contents.media.keys.toList()..sort();
        for (final id in sortedIds) {
          final out = File(
            '${mediaDir.path}${Platform.pathSeparator}$id.bin',
          );
          await out.writeAsBytes(contents.media[id]!, flush: true);
        }

        await inFile.delete();
        await plainZip.delete();

        final digest = await _computeStagingDigest(validatedDir);
        return <String, Object?>{
          'stagingDirPath': validatedDir.path,
          'contentDigest': digest,
          'mealCount': snapshot.meals.length,
          'entryCount': snapshot.entries.length,
          'documentCount': snapshot.documents.length,
          'mutationCount': snapshot.mutations.length,
          'mediaCount': contents.media.length,
          'mediaOmitted': contents.mediaOmitted,
          'catalogueManifest': contents.catalogueManifest,
        };
      });

      return RestorePreview(
        stagingDirPath: inspected['stagingDirPath']! as String,
        contentDigest: inspected['contentDigest']! as String,
        mealCount: inspected['mealCount']! as int,
        entryCount: inspected['entryCount']! as int,
        documentCount: inspected['documentCount']! as int,
        mutationCount: inspected['mutationCount']! as int,
        mediaCount: inspected['mediaCount']! as int,
        mediaOmitted: inspected['mediaOmitted']! as bool,
        catalogueManifest:
            (inspected['catalogueManifest']! as Map).cast<String, Object?>(),
      );
    } catch (_) {
      await _deleteDirQuietly(stageDir);
      rethrow;
    }
  }

  /// Replaces all local user data with the validated snapshot in [preview].
  ///
  /// Stages media under fresh managed IDs, acquires [DataWriteGate.exclusive],
  /// invalidates [OperationFence], persists a credential-cleanup marker,
  /// replaces the database atomically, clears credentials, and notifies
  /// listeners.
  Future<void> restore(RestorePreview preview) async {
    final validatedDir = Directory(preview.stagingDirPath);
    if (!await validatedDir.exists()) {
      throw const FormatException(
        'Restore preview staging directory no longer exists.',
      );
    }

    final currentDigest = await _computeStagingDigest(validatedDir);
    if (currentDigest != preview.contentDigest) {
      throw const FormatException(
        'Restore preview staging content was modified; inspect the archive again.',
      );
    }

    final recordsFile = File(
      '${validatedDir.path}${Platform.pathSeparator}records.json',
    );
    final rawRecords = jsonDecode(await recordsFile.readAsString());
    if (rawRecords is! Map) {
      throw const FormatException('Staged records.json is not a JSON object.');
    }
    final snapshot =
        UserDataSnapshot.fromJson(rawRecords.cast<String, Object?>());

    // Stage media into ManagedMediaStore under fresh IDs before acquiring the
    // exclusive DB gate so existing media remain completely untouched on error.
    final mediaDir =
        Directory('${validatedDir.path}${Platform.pathSeparator}media');
    final refRemap = <String, String>{};
    final newlyStagedRefs = <String>[];

    try {
      if (await mediaDir.exists()) {
        final entries = await mediaDir
            .list(followLinks: false)
            .where((e) => e is File && e.path.endsWith('.bin'))
            .cast<File>()
            .toList();
        entries.sort((a, b) => a.path.compareTo(b.path));
        for (final file in entries) {
          final base = _basename(file.path);
          final oldId = base.substring(0, base.length - '.bin'.length);
          final stageFn = _stageMediaOverride ?? _media.importImage;
          final newRef = await stageFn(XFile(file.path));
          refRemap['${ManagedMediaStore.refPrefix}$oldId'] = newRef;
          newlyStagedRefs.add(newRef);
        }
      }
    } catch (_) {
      await _cleanupStagedMedia(newlyStagedRefs);
      rethrow;
    }

    final remappedSnapshot = _remapSnapshotMediaRefs(snapshot, refRemap);

    await _gate.exclusive(() async {
      _fence.invalidate();

      final marker = await _cleanupMarkerFile();
      await marker.parent.create(recursive: true);
      await marker.writeAsString(
        DateTime.now().toUtc().toIso8601String(),
        flush: true,
      );

      try {
        await _data.replace(remappedSnapshot);
      } catch (_) {
        // DB replace failed: original DB & media are intact. Remove the marker
        // and clean only the newly staged media files.
        await _deleteFileQuietly(marker);
        await _cleanupStagedMedia(newlyStagedRefs);
        rethrow;
      }

      // DB commit succeeded! Clean staging dir.
      await _deleteDirQuietly(validatedDir.parent);

      // Clear credentials; if this throws, the marker remains on disk so
      // resumePendingCredentialCleanup() retries before allowing AI use.
      await _credentials.clearSaluCredentials();
      await _deleteFileQuietly(marker);

      _onRestored?.call();
    });
  }

  /// Completes any interrupted post-restore credential cleanup from a prior
  /// session. Safe to call on startup and before AI use.
  Future<void> resumePendingCredentialCleanup() async {
    final marker = await _cleanupMarkerFile();
    if (!await marker.exists()) return;
    await _credentials.clearSaluCredentials();
    await _deleteFileQuietly(marker);
  }

  Future<File> _cleanupMarkerFile() async {
    final root = await _stagingDirectory();
    return File('${root.path}${Platform.pathSeparator}$_cleanupMarkerName');
  }

  Future<Directory> _createUniqueStageDir(String prefix) async {
    final root = await _stagingDirectory();
    await root.create(recursive: true);
    final stamp = '${DateTime.now().microsecondsSinceEpoch}-${++_stageCounter}';
    return Directory('${root.path}${Platform.pathSeparator}$prefix-$stamp')
        .create(recursive: true);
  }

  Future<void> _cleanupStagedMedia(List<String> refs) async {
    for (final ref in refs) {
      try {
        await _media.removeUnreferenced(ref, const <String>{});
      } on Object {
        // Best-effort cleanup of newly staged files.
      }
    }
  }
}

Set<String> _collectReferencedMediaRefs(UserDataSnapshot snapshot) {
  final refs = <String>{};
  void addIfManaged(Object? value) {
    if (value is String && value.startsWith(ManagedMediaStore.refPrefix)) {
      refs.add(value);
    }
  }

  for (final meal in snapshot.meals) {
    addIfManaged(meal['photoPath']);
    final itemsJson = meal['itemsJson'];
    if (itemsJson is String) {
      final decoded = jsonDecode(itemsJson);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) {
            addIfManaged(item['labelPath']);
            final labelPaths = item['labelPaths'];
            if (labelPaths is List) {
              for (final p in labelPaths) {
                addIfManaged(p);
              }
            }
          }
        }
      }
    }
  }
  return refs;
}

UserDataSnapshot _remapSnapshotMediaRefs(
  UserDataSnapshot snapshot,
  Map<String, String> remap,
) {
  if (remap.isEmpty) return snapshot;

  String? remapRef(Object? value) {
    if (value is! String) return null;
    return remap[value] ?? value;
  }

  List<Object?> remapItemsList(List<Object?> items) {
    return items.map((item) {
      if (item is! Map) return item;
      final copy = Map<String, Object?>.from(item);
      if (copy['labelPath'] is String) {
        copy['labelPath'] = remapRef(copy['labelPath']);
      }
      if (copy['labelPaths'] is List) {
        copy['labelPaths'] = (copy['labelPaths']! as List)
            .map((e) => e is String ? (remap[e] ?? e) : e)
            .toList();
      }
      return copy;
    }).toList();
  }

  String? remapPhotoMealJson(Object? raw) {
    if (raw is! String) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return raw;
    final copy = Map<String, Object?>.from(decoded);
    if (copy['photoPath'] is String) {
      copy['photoPath'] = remapRef(copy['photoPath']);
    }
    if (copy['items'] is List) {
      copy['items'] = remapItemsList(copy['items']! as List);
    }
    return jsonEncode(copy);
  }

  final meals = [
    for (final meal in snapshot.meals)
      <String, Object?>{
        ...meal,
        'photoPath': remapRef(meal['photoPath']),
        'itemsJson': meal['itemsJson'] is String
            ? jsonEncode(
                remapItemsList(
                  jsonDecode(meal['itemsJson']! as String) as List<Object?>,
                ),
              )
            : meal['itemsJson'],
      },
  ];

  final mutations = [
    for (final mut in snapshot.mutations)
      <String, Object?>{
        ...mut,
        'beforeJson': remapPhotoMealJson(mut['beforeJson']),
        'afterJson': remapPhotoMealJson(mut['afterJson']),
      },
  ];

  return UserDataSnapshot(
    entries: snapshot.entries,
    entryItems: snapshot.entryItems,
    meals: meals,
    documents: snapshot.documents,
    mutations: mutations,
    catalogueManifest: snapshot.catalogueManifest,
  );
}

Future<String> _computeStagingDigest(Directory validatedDir) async {
  final recordsFile = File(
    '${validatedDir.path}${Platform.pathSeparator}records.json',
  );
  if (!await recordsFile.exists()) {
    throw const FormatException('Staged records.json is missing.');
  }
  final builder = BytesBuilder(copy: false);
  builder.add(utf8.encode('records.json\n'));
  builder.add(await recordsFile.readAsBytes());

  final mediaDir =
      Directory('${validatedDir.path}${Platform.pathSeparator}media');
  if (await mediaDir.exists()) {
    final files = await mediaDir
        .list(followLinks: false)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    files.sort((a, b) => _basename(a.path).compareTo(_basename(b.path)));
    for (final file in files) {
      builder.add(utf8.encode('\nmedia/${_basename(file.path)}\n'));
      builder.add(await file.readAsBytes());
    }
  }
  return sha256.convert(builder.takeBytes()).toString();
}

String _basename(String path) {
  final idx = path.lastIndexOf(Platform.pathSeparator);
  final slash = path.lastIndexOf('/');
  final cut = idx > slash ? idx : slash;
  return cut < 0 ? path : path.substring(cut + 1);
}

Future<void> _deleteDirQuietly(Directory dir) async {
  try {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  } on FileSystemException {
    // Best-effort cleanup.
  }
}

Future<void> _deleteFileQuietly(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } on FileSystemException {
    // Best-effort cleanup.
  }
}
