import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

/// Current archive manifest format version.
const int archiveFormatVersion = 1;

/// Current `records.json` format version.
const int archiveRecordsFormatVersion = 1;

/// Current database schema version supported by format 1 archives.
const int archiveSchemaVersion = 4;

/// Maximum compressed ZIP archive size (64 MiB).
const int maxArchiveCompressedBytes = 64 * 1024 * 1024;

/// Maximum total expanded bytes across all ZIP members (128 MiB).
const int maxArchiveExpandedBytes = 128 * 1024 * 1024;

/// Maximum number of ZIP members permitted in an archive.
const int maxArchiveMembers = 25000;

/// Maximum expanded bytes for `records.json` (16 MiB).
const int maxRecordsJsonBytes = 16 * 1024 * 1024;

/// Maximum expanded bytes for `manifest.json` (4 MiB).
const int maxManifestJsonBytes = 4 * 1024 * 1024;

/// Maximum expanded bytes for a single media file (24 MiB).
const int maxSingleMediaBytes = 24 * 1024 * 1024;

final RegExp _opaqueMediaIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

const Set<String> _validNutrientStates = <String>{
  'unknown',
  'trace',
  'measured',
  'reported',
  'estimated',
};

const Set<String> _forbiddenCollectionKeys = <String>{
  'endpoint-connections',
  'endpointConnections',
  'endpoint_connections',
};

const Set<String> _nutrientContainerKeys = <String>{
  'nutrients',
  'nutrientProfile',
  'nutrient_profile',
  'estimatedNutrients',
  'estimated_nutrients',
  'nutrientValues',
  'nutrient_values',
};

/// Decoded contents of a Salu versioned archive.
class ArchiveContents {
  const ArchiveContents({
    required this.records,
    required this.media,
    required this.catalogueManifest,
    this.mediaOmitted = false,
  });

  final Map<String, Object?> records;
  final Map<String, Uint8List> media;
  final Map<String, Object?> catalogueManifest;
  final bool mediaOmitted;
}

class _BoundedMemoryOutputStream extends OutputMemoryStream {
  _BoundedMemoryOutputStream({
    required this.maxFileBytes,
    required this.maxTotalBytes,
    required this.totalBytesReadSoFar,
  });

  final int maxFileBytes;
  final int maxTotalBytes;
  final int totalBytesReadSoFar;
  int _written = 0;

  void _checkAdd(int count) {
    _written += count;
    if (_written > maxFileBytes) {
      throw const FormatException(
        'Archive member exceeds maximum allowed expanded size.',
      );
    }
    if (totalBytesReadSoFar + _written > maxArchiveExpandedBytes ||
        totalBytesReadSoFar + _written > maxTotalBytes) {
      throw const FormatException(
        'Archive exceeds maximum allowed total expanded size (128 MiB).',
      );
    }
  }

  @override
  void writeByte(int value) {
    _checkAdd(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final len = length ?? bytes.length;
    _checkAdd(len);
    super.writeBytes(bytes, length: length);
  }
}

/// Validates that [id] is a safe opaque media identifier.
bool isValidOpaqueMediaId(String id) => _opaqueMediaIdPattern.hasMatch(id);

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

Future<({int size, String sha256})> _hashAndMeasureFile(
  File file, {
  required int maxBytes,
}) async {
  final size = await file.length();
  if (size > maxBytes) {
    throw const FormatException(
      'Media file exceeds maximum allowed size (24 MiB).',
    );
  }
  final digest = await sha256.bind(file.openRead()).first;
  return (size: size, sha256: digest.toString());
}

void _validateMemberName(String name) {
  if (name.isEmpty ||
      name.contains('\\') ||
      name.contains('\x00') ||
      name.startsWith('/') ||
      name.endsWith('/') ||
      name.contains('..') ||
      RegExp(r'^[A-Za-z]:').hasMatch(name)) {
    throw FormatException('Disallowed archive member path: $name');
  }
  if (name == 'manifest.json' || name == 'records.json') {
    return;
  }
  if (name.startsWith('media/')) {
    final id = name.substring('media/'.length);
    if (!id.contains('/') && isValidOpaqueMediaId(id)) {
      return;
    }
  }
  throw FormatException('Archive member is outside allowlist: $name');
}

Map<String, Object?> _prepareAndValidateRecords(
  Map<String, Object?> rawRecords, {
  required Set<String> availableMediaIds,
  required bool mediaOmitted,
  required bool requireFormatField,
}) {
  final prepared = Map<String, Object?>.from(rawRecords);
  if (prepared.containsKey('format')) {
    if (prepared['format'] != archiveRecordsFormatVersion) {
      throw FormatException(
        'Unsupported records format version: ${prepared['format']}',
      );
    }
  } else if (requireFormatField) {
    throw const FormatException(
        'records.json is missing required format field.');
  } else {
    prepared['format'] = archiveRecordsFormatVersion;
  }

  for (final entry in prepared.entries) {
    final key = entry.key;
    if (_forbiddenCollectionKeys.contains(key)) {
      throw FormatException(
        'Provider profile collection "$key" is not allowed in archives.',
      );
    }
    if (key == 'format') {
      continue;
    }
    final value = entry.value;
    if (value is List) {
      _validateRecordCollection(
        key,
        value,
        availableMediaIds: availableMediaIds,
        mediaOmitted: mediaOmitted,
      );
    } else if (value is Map) {
      _validateRecordObject(
        value,
        availableMediaIds: availableMediaIds,
        mediaOmitted: mediaOmitted,
      );
    }
  }
  return prepared;
}

void _validateRecordCollection(
  String collectionName,
  List<Object?> items, {
  required Set<String> availableMediaIds,
  required bool mediaOmitted,
}) {
  final seenIds = <String>{};
  for (final item in items) {
    if (item is! Map) {
      continue;
    }
    final idField = item['id'] ?? item['key'] ?? item['docKey'];
    if (idField is String && idField.isNotEmpty) {
      if (idField == 'endpoint-connections' ||
          idField.startsWith('endpoint-connections:')) {
        throw FormatException(
          'Provider profile document "$idField" is not allowed in archives.',
        );
      }
      if (!seenIds.add(idField)) {
        throw FormatException(
          'Duplicate record ID "$idField" in collection "$collectionName".',
        );
      }
    }
    _validateRecordObject(
      item,
      availableMediaIds: availableMediaIds,
      mediaOmitted: mediaOmitted,
    );
  }
}

void _validateRecordObject(
  Map<Object?, Object?> map, {
  required Set<String> availableMediaIds,
  required bool mediaOmitted,
}) {
  for (final entry in map.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is String && _forbiddenCollectionKeys.contains(key)) {
      throw FormatException(
        'Provider profile field "$key" is not allowed in archives.',
      );
    }
    if (key is String && _nutrientContainerKeys.contains(key)) {
      if (value is! Map) {
        throw FormatException('Malformed nutrient map for "$key".');
      }
      _validateNutrientMap(value);
      continue;
    }
    _validateValueRecursive(
      value,
      availableMediaIds: availableMediaIds,
      mediaOmitted: mediaOmitted,
    );
  }
}

void _validateNutrientMap(Map<Object?, Object?> nutrientMap) {
  for (final entry in nutrientMap.entries) {
    final nutrientKey = entry.key;
    final rawVal = entry.value;
    if (nutrientKey is! String || nutrientKey.isEmpty) {
      throw const FormatException('Invalid nutrient key in records.');
    }
    if (rawVal is! Map) {
      throw FormatException(
        'Malformed nutrient state for "$nutrientKey": expected object.',
      );
    }
    final state = rawVal['state'];
    if (state is! String || !_validNutrientStates.contains(state)) {
      throw FormatException(
        'Invalid nutrient state "$state" for "$nutrientKey".',
      );
    }
    if (state == 'measured' || state == 'reported' || state == 'estimated') {
      final numVal = rawVal['value'];
      if (numVal is! num || !numVal.isFinite || numVal < 0) {
        throw FormatException(
          'Invalid numeric value "$numVal" for $state nutrient "$nutrientKey".',
        );
      }
    }
  }
}

void _validateValueRecursive(
  Object? value, {
  required Set<String> availableMediaIds,
  required bool mediaOmitted,
}) {
  if (value is String) {
    if (value.startsWith('media:')) {
      final id = value.substring('media:'.length);
      if (!isValidOpaqueMediaId(id)) {
        throw FormatException('Invalid media reference: $value');
      }
      if (!mediaOmitted && !availableMediaIds.contains(id)) {
        throw FormatException('Broken media evidence reference: $value');
      }
    }
    return;
  }
  if (value is List) {
    for (final item in value) {
      _validateValueRecursive(
        item,
        availableMediaIds: availableMediaIds,
        mediaOmitted: mediaOmitted,
      );
    }
    return;
  }
  if (value is Map) {
    _validateRecordObject(
      value,
      availableMediaIds: availableMediaIds,
      mediaOmitted: mediaOmitted,
    );
  }
}

Map<String, int> _countRecords(Map<String, Object?> records) {
  var collections = 0;
  var total = 0;
  for (final entry in records.entries) {
    if (entry.key == 'format') continue;
    collections++;
    final value = entry.value;
    if (value is List) {
      total += value.length;
    } else if (value is Map) {
      total += value.length;
    }
  }
  return <String, int>{
    'recordCollections': collections,
    'totalRecords': total,
  };
}

/// Encodes [contents] into a versioned format-1 ZIP archive in memory.
Uint8List encodeArchive(ArchiveContents contents) {
  if (contents.mediaOmitted && contents.media.isNotEmpty) {
    throw const FormatException(
      'Cannot include media bytes when mediaOmitted is true.',
    );
  }
  final memberCount = 2 + contents.media.length;
  if (memberCount > maxArchiveMembers) {
    throw const FormatException(
      'Archive exceeds maximum member count ($maxArchiveMembers).',
    );
  }

  for (final id in contents.media.keys) {
    if (!isValidOpaqueMediaId(id)) {
      throw FormatException('Invalid opaque media ID: $id');
    }
  }

  final validatedRecords = _prepareAndValidateRecords(
    contents.records,
    availableMediaIds: contents.media.keys.toSet(),
    mediaOmitted: contents.mediaOmitted,
    requireFormatField: false,
  );

  final recordsBytes =
      Uint8List.fromList(utf8.encode(jsonEncode(validatedRecords)));
  if (recordsBytes.length > maxRecordsJsonBytes) {
    throw const FormatException(
      'records.json exceeds maximum allowed size (16 MiB).',
    );
  }

  var totalExpanded = recordsBytes.length;
  final fileHashes = <String, Map<String, Object?>>{
    'records.json': <String, Object?>{
      'size': recordsBytes.length,
      'sha256': _sha256Hex(recordsBytes),
    },
  };

  final sortedMediaIds = contents.media.keys.toList()..sort();
  for (final id in sortedMediaIds) {
    final bytes = contents.media[id]!;
    if (bytes.length > maxSingleMediaBytes) {
      throw FormatException(
        'Media "$id" exceeds maximum allowed size (24 MiB).',
      );
    }
    totalExpanded += bytes.length;
    if (totalExpanded > maxArchiveExpandedBytes) {
      throw const FormatException(
        'Archive exceeds maximum allowed total expanded size (128 MiB).',
      );
    }
    fileHashes['media/$id'] = <String, Object?>{
      'size': bytes.length,
      'sha256': _sha256Hex(bytes),
    };
  }

  final counts = _countRecords(validatedRecords);
  final manifest = <String, Object?>{
    'format': archiveFormatVersion,
    'schemaVersion': archiveSchemaVersion,
    'recordsFormat': archiveRecordsFormatVersion,
    'mediaOmitted': contents.mediaOmitted,
    'catalogueManifest': contents.catalogueManifest,
    'counts': <String, Object?>{
      'media': sortedMediaIds.length,
      'recordCollections': counts['recordCollections'],
      'totalRecords': counts['totalRecords'],
    },
    'files': fileHashes,
  };
  final manifestBytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
  if (manifestBytes.length > maxManifestJsonBytes) {
    throw const FormatException(
      'manifest.json exceeds maximum allowed size (4 MiB).',
    );
  }
  totalExpanded += manifestBytes.length;
  if (totalExpanded > maxArchiveExpandedBytes) {
    throw const FormatException(
      'Archive exceeds maximum allowed total expanded size (128 MiB).',
    );
  }

  final archive = Archive()
    ..addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes))
    ..addFile(ArchiveFile('records.json', recordsBytes.length, recordsBytes));

  for (final id in sortedMediaIds) {
    final bytes = contents.media[id]!;
    archive.addFile(ArchiveFile('media/$id', bytes.length, bytes));
  }

  final encoded = ZipEncoder().encode(archive);
  final zipBytes = Uint8List.fromList(encoded);
  if (zipBytes.length > maxArchiveCompressedBytes) {
    throw const FormatException(
      'Compressed archive exceeds 64 MiB limit.',
    );
  }
  return zipBytes;
}

/// Streams records and on-disk media files directly into [outputFile] without
/// loading all media files into a single in-memory map.
Future<File> encodeArchiveToFile({
  required Map<String, Object?> records,
  required Map<String, File> mediaFiles,
  required Map<String, Object?> catalogueManifest,
  required File outputFile,
  bool mediaOmitted = false,
}) async {
  if (mediaOmitted && mediaFiles.isNotEmpty) {
    throw const FormatException(
      'Cannot include media files when mediaOmitted is true.',
    );
  }
  final memberCount = 2 + mediaFiles.length;
  if (memberCount > maxArchiveMembers) {
    throw const FormatException(
      'Archive exceeds maximum member count ($maxArchiveMembers).',
    );
  }
  for (final id in mediaFiles.keys) {
    if (!isValidOpaqueMediaId(id)) {
      throw FormatException('Invalid opaque media ID: $id');
    }
  }

  final validatedRecords = _prepareAndValidateRecords(
    records,
    availableMediaIds: mediaFiles.keys.toSet(),
    mediaOmitted: mediaOmitted,
    requireFormatField: false,
  );
  final recordsBytes =
      Uint8List.fromList(utf8.encode(jsonEncode(validatedRecords)));
  if (recordsBytes.length > maxRecordsJsonBytes) {
    throw const FormatException(
      'records.json exceeds maximum allowed size (16 MiB).',
    );
  }

  var totalExpanded = recordsBytes.length;
  final fileHashes = <String, Map<String, Object?>>{
    'records.json': <String, Object?>{
      'size': recordsBytes.length,
      'sha256': _sha256Hex(recordsBytes),
    },
  };

  final sortedMediaIds = mediaFiles.keys.toList()..sort();
  for (final id in sortedMediaIds) {
    final file = mediaFiles[id]!;
    final meta = await _hashAndMeasureFile(
      file,
      maxBytes: maxSingleMediaBytes,
    );
    totalExpanded += meta.size;
    if (totalExpanded > maxArchiveExpandedBytes) {
      throw const FormatException(
        'Archive exceeds maximum allowed total expanded size (128 MiB).',
      );
    }
    fileHashes['media/$id'] = <String, Object?>{
      'size': meta.size,
      'sha256': meta.sha256,
    };
  }

  final counts = _countRecords(validatedRecords);
  final manifest = <String, Object?>{
    'format': archiveFormatVersion,
    'schemaVersion': archiveSchemaVersion,
    'recordsFormat': archiveRecordsFormatVersion,
    'mediaOmitted': mediaOmitted,
    'catalogueManifest': catalogueManifest,
    'counts': <String, Object?>{
      'media': sortedMediaIds.length,
      'recordCollections': counts['recordCollections'],
      'totalRecords': counts['totalRecords'],
    },
    'files': fileHashes,
  };
  final manifestBytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
  if (manifestBytes.length > maxManifestJsonBytes) {
    throw const FormatException(
      'manifest.json exceeds maximum allowed size (4 MiB).',
    );
  }
  totalExpanded += manifestBytes.length;
  if (totalExpanded > maxArchiveExpandedBytes) {
    throw const FormatException(
      'Archive exceeds maximum allowed total expanded size (128 MiB).',
    );
  }

  final encoder = ZipFileEncoder();
  encoder.create(outputFile.path);
  try {
    encoder.addArchiveFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );
    encoder.addArchiveFile(
      ArchiveFile('records.json', recordsBytes.length, recordsBytes),
    );
    for (final id in sortedMediaIds) {
      await encoder.addFile(mediaFiles[id]!, 'media/$id');
    }
  } finally {
    await encoder.close();
  }

  final compressedLength = await outputFile.length();
  if (compressedLength > maxArchiveCompressedBytes) {
    if (await outputFile.exists()) {
      await outputFile.delete();
    }
    throw const FormatException('Compressed archive exceeds 64 MiB limit.');
  }
  return outputFile;
}

ArchiveContents _decodeArchiveFromStream(InputStream input) {
  final ZipDirectory directory;
  try {
    directory = ZipDirectory()..read(input);
  } catch (_) {
    throw const FormatException('Archive is not a valid ZIP file.');
  }

  if (directory.fileHeaders.length > maxArchiveMembers) {
    throw const FormatException(
      'Archive exceeds maximum member count ($maxArchiveMembers).',
    );
  }

  final directoryNames = <String>{};
  for (final header in directory.fileHeaders) {
    if (!directoryNames.add(header.filename)) {
      throw FormatException('Duplicate archive member: ${header.filename}');
    }
  }

  input.rewind();
  final Archive archive;
  try {
    archive = ZipDecoder().decodeStream(input);
  } catch (_) {
    throw const FormatException('Archive is not a valid ZIP file.');
  }

  final seenNames = <String>{};
  final extracted = <String, Uint8List>{};
  var totalExpanded = 0;

  for (final file in archive) {
    final name = file.name;
    if (!seenNames.add(name)) {
      throw FormatException('Duplicate archive member: $name');
    }
    if (file.isSymbolicLink || !file.isFile) {
      throw FormatException('Disallowed non-file archive member: $name');
    }
    _validateMemberName(name);

    final int maxMemberBytes;
    if (name == 'manifest.json') {
      maxMemberBytes = maxManifestJsonBytes;
    } else if (name == 'records.json') {
      maxMemberBytes = maxRecordsJsonBytes;
    } else {
      maxMemberBytes = maxSingleMediaBytes;
    }

    if (file.size > maxMemberBytes) {
      throw FormatException(
        'Archive member "$name" exceeds maximum allowed size.',
      );
    }
    if (totalExpanded + file.size > maxArchiveExpandedBytes) {
      throw const FormatException(
        'Archive exceeds maximum allowed total expanded size (128 MiB).',
      );
    }

    final boundedOut = _BoundedMemoryOutputStream(
      maxFileBytes: maxMemberBytes,
      maxTotalBytes: maxArchiveExpandedBytes,
      totalBytesReadSoFar: totalExpanded,
    );
    file.writeContent(boundedOut);
    final bytes = boundedOut.getBytes();
    totalExpanded += bytes.length;
    extracted[name] = bytes;
  }

  final manifestBytes = extracted['manifest.json'];
  final recordsBytes = extracted['records.json'];
  if (manifestBytes == null || recordsBytes == null) {
    throw const FormatException(
      'Archive is missing required manifest.json or records.json.',
    );
  }

  final Object? decodedManifest;
  try {
    decodedManifest = jsonDecode(utf8.decode(manifestBytes));
  } catch (_) {
    throw const FormatException('manifest.json is not valid UTF-8 JSON.');
  }
  if (decodedManifest is! Map<String, Object?>) {
    throw const FormatException('manifest.json must be a JSON object.');
  }

  if (decodedManifest['format'] != archiveFormatVersion) {
    throw FormatException(
      'Unsupported archive manifest format: ${decodedManifest['format']}',
    );
  }
  if (decodedManifest['recordsFormat'] != archiveRecordsFormatVersion) {
    throw FormatException(
      'Unsupported archive records format: ${decodedManifest['recordsFormat']}',
    );
  }
  final schemaVersion = decodedManifest['schemaVersion'];
  if (schemaVersion is! int ||
      schemaVersion < 1 ||
      schemaVersion > archiveSchemaVersion) {
    throw FormatException(
      'Unsupported archive schema version: $schemaVersion',
    );
  }
  final mediaOmitted = decodedManifest['mediaOmitted'];
  if (mediaOmitted is! bool) {
    throw const FormatException('manifest.json missing boolean mediaOmitted.');
  }
  final catalogueManifest = decodedManifest['catalogueManifest'];
  if (catalogueManifest is! Map<String, Object?>) {
    throw const FormatException(
      'manifest.json missing catalogueManifest object.',
    );
  }
  final filesManifest = decodedManifest['files'];
  if (filesManifest is! Map<String, Object?>) {
    throw const FormatException('manifest.json missing files integrity map.');
  }

  // Verify exact file set, sizes, and SHA-256 digests.
  final nonManifestNames =
      extracted.keys.where((name) => name != 'manifest.json').toSet();
  final manifestFileNames = filesManifest.keys.toSet();
  if (nonManifestNames.length != manifestFileNames.length ||
      !nonManifestNames.containsAll(manifestFileNames)) {
    throw const FormatException(
      'Archive members do not match manifest.json file inventory.',
    );
  }

  for (final name in nonManifestNames) {
    final entry = filesManifest[name];
    if (entry is! Map<String, Object?>) {
      throw FormatException('Invalid manifest entry for "$name".');
    }
    final expectedSize = entry['size'];
    final expectedHash = entry['sha256'];
    final actualBytes = extracted[name]!;
    if (expectedSize is! int || actualBytes.length != expectedSize) {
      throw FormatException('Size mismatch for archive member "$name".');
    }
    if (expectedHash is! String || _sha256Hex(actualBytes) != expectedHash) {
      throw FormatException(
          'SHA-256 hash mismatch for archive member "$name".');
    }
  }

  final media = <String, Uint8List>{};
  for (final entry in extracted.entries) {
    if (entry.key.startsWith('media/')) {
      final id = entry.key.substring('media/'.length);
      media[id] = entry.value;
    }
  }
  if (mediaOmitted && media.isNotEmpty) {
    throw const FormatException(
      'Archive declares mediaOmitted=true but contains media files.',
    );
  }

  final Object? decodedRecords;
  try {
    decodedRecords = jsonDecode(utf8.decode(recordsBytes));
  } catch (_) {
    throw const FormatException('records.json is not valid UTF-8 JSON.');
  }
  if (decodedRecords is! Map<String, Object?>) {
    throw const FormatException('records.json must be a JSON object.');
  }

  final validatedRecords = _prepareAndValidateRecords(
    decodedRecords,
    availableMediaIds: media.keys.toSet(),
    mediaOmitted: mediaOmitted,
    requireFormatField: true,
  );

  return ArchiveContents(
    records: validatedRecords,
    media: media,
    catalogueManifest: catalogueManifest,
    mediaOmitted: mediaOmitted,
  );
}

/// Decodes and validates a format-1 ZIP archive from memory.
ArchiveContents decodeArchive(Uint8List zipBytes) {
  if (zipBytes.length > maxArchiveCompressedBytes) {
    throw const FormatException('Compressed archive exceeds 64 MiB limit.');
  }
  return _decodeArchiveFromStream(InputMemoryStream(zipBytes));
}

/// Decodes and validates a format-1 ZIP archive from a file on disk,
/// enforcing the 64 MiB compressed size limit before reading.
Future<ArchiveContents> decodeArchiveFromFile(File zipFile) async {
  final length = await zipFile.length();
  if (length > maxArchiveCompressedBytes) {
    throw const FormatException('Compressed archive exceeds 64 MiB limit.');
  }
  final input = InputFileStream(zipFile.path);
  try {
    return _decodeArchiveFromStream(input);
  } finally {
    await input.close();
  }
}
