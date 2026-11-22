import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// App-owned media storage using opaque `media:<id>` references.
///
/// Stored originals are retained in `<directory>/meal-images/<id>.image` until
/// an explicit cleanup/retention action. Uploads are always re-encoded without
/// metadata via `encodeMealUpload`.
final class ManagedMediaStore {
  ManagedMediaStore({
    required Future<Directory> Function() directory,
    required String Function() newId,
    Future<List<XFile>> Function()? lostDataRetriever,
  })  : _directory = directory,
        _newId = newId,
        _lostDataRetriever = lostDataRetriever;

  static const String refPrefix = 'media:';
  static const String subdirectoryName = 'meal-images';
  static final RegExp _opaqueIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  final Future<Directory> Function() _directory;
  final String Function() _newId;
  final Future<List<XFile>> Function()? _lostDataRetriever;
  int _stagingCounter = 0;

  static bool isValidOpaqueId(String id) => _opaqueIdPattern.hasMatch(id);

  Future<Directory> _mediaDirectory() async {
    final root = await _directory();
    return Directory('${root.path}${Platform.pathSeparator}$subdirectoryName');
  }

  /// Copies [image] into the app-owned `meal-images` directory via a staging
  /// file and returns its `media:<opaque-id>` reference.
  ///
  /// Never overwrites an existing managed file and never deletes [image].
  Future<String> importImage(XFile image) async {
    final id = _newId();
    if (!isValidOpaqueId(id)) {
      throw FormatException('Invalid managed media identifier: $id');
    }
    final mediaDir = await (await _mediaDirectory()).create(recursive: true);
    final target = File(
      '${mediaDir.path}${Platform.pathSeparator}$id.image',
    );
    if (await target.exists()) {
      throw FileSystemException(
        'Managed media file already exists',
        target.path,
      );
    }
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${++_stagingCounter}';
    final staging = File(
      '${mediaDir.path}${Platform.pathSeparator}.staging-$id-$nonce.tmp',
    );
    await staging.create(exclusive: true);
    try {
      await image.saveTo(staging.path);
      if (await target.exists()) {
        throw FileSystemException(
          'Managed media file already exists',
          target.path,
        );
      }
      await staging.rename(target.path);
      return '$refPrefix$id';
    } catch (_) {
      try {
        if (await staging.exists()) {
          await staging.delete();
        }
      } on FileSystemException {
        // Staging file may already be gone.
      }
      rethrow;
    }
  }

  /// Resolves a `media:<opaque-id>` reference or a recognized legacy app-owned
  /// absolute path strictly inside the owned `meal-images` directory.
  ///
  /// Returns `null` for invalid IDs, traversal attempts, out-of-root paths, or
  /// missing files.
  Future<File?> resolve(String reference) async {
    final mediaDir = await _mediaDirectory();
    final filename = _ownedFilename(reference, mediaDir);
    if (filename == null) return null;
    final file = File('${mediaDir.path}${Platform.pathSeparator}$filename');
    if (await file.exists()) return file;
    return null;
  }

  /// Deletes unreferenced managed `.image` files inside `meal-images` whose
  /// last-modified timestamp is strictly before [olderThanUtc].
  Future<void> collect(
    Set<String> referenced, {
    required DateTime olderThanUtc,
  }) async {
    final mediaDir = await _mediaDirectory();
    if (!await mediaDir.exists()) return;
    final referencedNames = _referencedFilenames(referenced, mediaDir);
    await for (final entity in mediaDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!name.endsWith('.image')) continue;
      if (referencedNames.contains(name)) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.toUtc().isBefore(olderThanUtc)) {
          await entity.delete();
        }
      } on FileSystemException {
        // File may have been removed concurrently.
      }
    }
  }

  /// Deletes the managed file for [reference] only if it resides inside the
  /// owned `meal-images` directory and is not in [referenced].
  Future<void> removeUnreferenced(
    String reference,
    Set<String> referenced,
  ) async {
    final mediaDir = await _mediaDirectory();
    final filename = _ownedFilename(reference, mediaDir);
    if (filename == null) return;
    final referencedNames = _referencedFilenames(referenced, mediaDir);
    if (referencedNames.contains(filename)) return;
    final file = File('${mediaDir.path}${Platform.pathSeparator}$filename');
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // File may already be gone.
    }
  }

  /// Recovers image files left behind when Android kills the activity while
  /// the system camera or gallery picker was open.
  ///
  /// Returns an empty list safely on unsupported platforms.
  Future<List<XFile>> recoverLostPickerImages() async {
    if (_lostDataRetriever case final retriever?) {
      return List<XFile>.unmodifiable(await retriever());
    }
    try {
      final response = await ImagePicker().retrieveLostData();
      if (response.isEmpty) return const <XFile>[];
      final files = response.files;
      if (files != null && files.isNotEmpty) {
        return List<XFile>.unmodifiable(files);
      }
      final file = response.file;
      if (file != null) return <XFile>[file];
      return const <XFile>[];
    } on Object {
      return const <XFile>[];
    }
  }

  Set<String> _referencedFilenames(
    Set<String> references,
    Directory mediaDir,
  ) {
    final names = <String>{};
    for (final reference in references) {
      final name = _ownedFilename(reference, mediaDir);
      if (name != null) names.add(name);
    }
    return names;
  }

  String? _ownedFilename(String reference, Directory mediaDir) {
    if (reference.isEmpty) return null;
    if (reference.startsWith(refPrefix)) {
      final id = reference.substring(refPrefix.length);
      if (!isValidOpaqueId(id)) return null;
      return '$id.image';
    }
    // Legacy app-owned absolute path check: reject traversal and any path
    // whose parent directory is not the owned `meal-images` directory.
    final normalizedRef = _normalizePath(reference);
    if (normalizedRef == null) return null;
    final normalizedDir = _normalizePath(mediaDir.absolute.path);
    if (normalizedDir == null) return null;

    final separatorIndex = normalizedRef.lastIndexOf('/');
    if (separatorIndex <= 0 || separatorIndex == normalizedRef.length - 1) {
      return null;
    }
    final parent = normalizedRef.substring(0, separatorIndex);
    final filename = normalizedRef.substring(separatorIndex + 1);
    if (filename.isEmpty ||
        filename == '.' ||
        filename == '..' ||
        filename.startsWith('.staging-')) {
      return null;
    }
    final sameDir = Platform.isWindows
        ? parent.toLowerCase() == normalizedDir.toLowerCase()
        : parent == normalizedDir;
    if (!sameDir) return null;
    return filename;
  }

  static String? _normalizePath(String rawPath) {
    final unified = rawPath.replaceAll('\\', '/');
    final segments = unified.split('/');
    // Reject any explicit traversal segment.
    if (segments.any((segment) => segment == '..')) return null;
    final cleaned = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.isEmpty && i > 0) continue;
      if (segment == '.') continue;
      cleaned.add(segment);
    }
    if (cleaned.isEmpty) return null;
    return cleaned.join('/');
  }

  static String _basename(String path) {
    final unified = path.replaceAll('\\', '/');
    final index = unified.lastIndexOf('/');
    return index < 0 ? unified : unified.substring(index + 1);
  }
}

/// Resolves a managed media reference via [ManagedMediaStore] and displays an
/// unavailable state when the file is missing or cannot be decoded.
class ManagedMediaImage extends StatefulWidget {
  const ManagedMediaImage({
    super.key,
    required this.reference,
    required this.media,
    this.fit = BoxFit.contain,
    this.cacheWidth,
    this.semanticLabel,
    this.unavailableText = 'Meal photo unavailable.',
  });

  final String reference;
  final ManagedMediaStore media;
  final BoxFit fit;
  final int? cacheWidth;
  final String? semanticLabel;
  final String unavailableText;

  @override
  State<ManagedMediaImage> createState() => _ManagedMediaImageState();
}

class _ManagedMediaImageState extends State<ManagedMediaImage> {
  late Future<File?> _fileFuture = widget.media.resolve(widget.reference);

  @override
  void didUpdateWidget(ManagedMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference ||
        oldWidget.media != widget.media) {
      _fileFuture = widget.media.resolve(widget.reference);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<File?>(
        future: _fileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox.shrink();
          }
          final file = snapshot.data;
          if (file == null) {
            return Center(child: Text(widget.unavailableText));
          }
          return Image.file(
            file,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth,
            semanticLabel: widget.semanticLabel,
            errorBuilder: (context, error, stackTrace) => Center(
              child: Text(widget.unavailableText),
            ),
          );
        },
      );
}
