/// Bounded, dependency-free ZIP reader for an XLSX container.
///
/// Only the top-level archive is opened: entries are never extracted to disk
/// and an entry that looks like another archive is rejected instead of being
/// followed. The parser reads the central directory, verifies each local
/// header, rejects duplicate/unsafe names, bounds compressed and uncompressed
/// sizes, and inflates one entry at a time through a size-limited sink.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Hard limits applied to an INSA workbook ZIP container.
abstract final class InsaZipLimits {
  /// Maximum number of central-directory entries.
  static const int maxEntries = 256;

  /// Maximum UTF-8 byte length of one entry name.
  static const int maxEntryNameBytes = 512;

  /// Maximum compressed bytes of one entry.
  static const int maxEntryCompressedBytes = 32 * 1024 * 1024;

  /// Maximum uncompressed bytes of one entry.
  static const int maxEntryUncompressedBytes = 32 * 1024 * 1024;

  /// Maximum total declared uncompressed bytes of all entries.
  static const int maxTotalUncompressedBytes = 64 * 1024 * 1024;
}

final class _InsaZipEntry {
  const _InsaZipEntry({
    required this.name,
    required this.method,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localOffset,
    required this.dataOffset,
  });

  final String name;
  final int method;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;
  final int dataOffset;
}

/// A parsed, validated ZIP archive whose contents are read on demand.
final class InsaZipArchive {
  InsaZipArchive._(this._bytes, Map<String, _InsaZipEntry> entries)
      : _entries = Map<String, _InsaZipEntry>.unmodifiable(entries);

  final Uint8List _bytes;
  final Map<String, _InsaZipEntry> _entries;

  /// Entry names in central-directory order.
  Iterable<String> get names => _entries.keys;

  /// Whether an exact entry name exists.
  bool contains(String name) => _entries.containsKey(name);

  /// Parses and validates [bytes] without extracting any entry.
  ///
  /// Throws [FormatException] for malformed, encrypted, ZIP64, duplicated,
  /// unsupported, overlapping or oversized containers.
  static InsaZipArchive parse(Uint8List bytes) {
    final eocd = _findEndOfCentralDirectory(bytes);
    final diskNumber = _u16(bytes, eocd + 4);
    final centralDisk = _u16(bytes, eocd + 6);
    final entriesOnDisk = _u16(bytes, eocd + 8);
    final totalEntries = _u16(bytes, eocd + 10);
    final centralSize = _u32(bytes, eocd + 12);
    final centralOffset = _u32(bytes, eocd + 16);

    if (diskNumber != 0 || centralDisk != 0 || entriesOnDisk != totalEntries) {
      throw const FormatException(
          'INSA workbook is not a valid ZIP archive: multi-disk archives are '
          'not supported');
    }
    if (totalEntries == 0) {
      throw const FormatException(
          'INSA workbook is not a valid ZIP archive: archive contains no '
          'entries');
    }
    if (totalEntries == 0xFFFF ||
        centralSize == 0xFFFFFFFF ||
        centralOffset == 0xFFFFFFFF) {
      throw const FormatException(
          'INSA workbook is not a valid ZIP archive: ZIP64 archives are not '
          'supported');
    }
    if (totalEntries > InsaZipLimits.maxEntries) {
      throw FormatException(
          'INSA workbook ZIP contains more than '
          '${InsaZipLimits.maxEntries} entries');
    }
    if (centralOffset + centralSize != eocd) {
      throw const FormatException(
          'INSA workbook is not a valid ZIP archive: central directory '
          'bounds do not match the archive');
    }
    if (centralSize < totalEntries * 46) {
      throw const FormatException(
          'INSA workbook is not a valid ZIP archive: central directory is '
          'truncated');
    }
    final centralEnd = centralOffset + centralSize;

    final entries = <String, _InsaZipEntry>{};
    final lowerNames = <String>{};
    var totalUncompressed = 0;
    var cursor = centralOffset;

    for (var index = 0; index < totalEntries; index++) {
      if (cursor + 46 > centralEnd) {
        throw const FormatException(
            'INSA workbook is not a valid ZIP archive: central directory is '
            'truncated');
      }
      if (_u32(bytes, cursor) != 0x02014B50) {
        throw const FormatException(
            'INSA workbook is not a valid ZIP archive: invalid central '
            'directory entry');
      }
      final flags = _u16(bytes, cursor + 8);
      final method = _u16(bytes, cursor + 10);
      final crc32 = _u32(bytes, cursor + 16);
      final compressedSize = _u32(bytes, cursor + 20);
      final uncompressedSize = _u32(bytes, cursor + 24);
      final nameLength = _u16(bytes, cursor + 28);
      final extraLength = _u16(bytes, cursor + 30);
      final commentLength = _u16(bytes, cursor + 32);
      final diskStart = _u16(bytes, cursor + 34);
      final localOffset = _u32(bytes, cursor + 42);
      final next = cursor + 46 + nameLength + extraLength + commentLength;

      if (next > centralEnd) {
        throw const FormatException(
            'INSA workbook is not a valid ZIP archive: central directory '
            'entry exceeds its bounds');
      }
      if (nameLength == 0 || nameLength > InsaZipLimits.maxEntryNameBytes) {
        throw const FormatException(
            'INSA workbook ZIP contains an invalid entry name length');
      }
      if (diskStart != 0) {
        throw const FormatException(
            'INSA workbook is not a valid ZIP archive: multi-disk entries are '
            'not supported');
      }
      if (compressedSize == 0xFFFFFFFF ||
          uncompressedSize == 0xFFFFFFFF ||
          localOffset == 0xFFFFFFFF) {
        throw const FormatException(
            'INSA workbook is not a valid ZIP archive: ZIP64 entries are not '
            'supported');
      }
      if ((flags & 0x0001) != 0 ||
          (flags & 0x0020) != 0 ||
          (flags & 0x0040) != 0 ||
          (flags & 0x2000) != 0) {
        throw const FormatException(
            'INSA workbook ZIP contains an encrypted or patched entry');
      }
      if (method != 0 && method != 8) {
        throw FormatException(
            'INSA workbook ZIP uses unsupported compression method $method');
      }
      if (compressedSize > InsaZipLimits.maxEntryCompressedBytes ||
          uncompressedSize > InsaZipLimits.maxEntryUncompressedBytes) {
        throw const FormatException(
            'INSA workbook ZIP entry exceeds the compressed or uncompressed '
            'size limit');
      }
      totalUncompressed += uncompressedSize;
      if (totalUncompressed > InsaZipLimits.maxTotalUncompressedBytes) {
        throw const FormatException(
            'INSA workbook ZIP exceeds the total uncompressed size limit');
      }
      if (localOffset >= centralOffset || localOffset + 30 > centralOffset) {
        throw const FormatException(
            'INSA workbook is not a valid ZIP archive: local entry offset is '
            'outside the entry area');
      }

      final nameBytes =
          Uint8List.sublistView(bytes, cursor + 46, cursor + 46 + nameLength);
      final name = _decodeEntryName(nameBytes, flags);
      _validateEntryName(name);
      if (!lowerNames.add(name.toLowerCase())) {
        throw FormatException(
            'INSA workbook ZIP contains duplicate entry "$name"');
      }
      final isDirectory = name.endsWith('/');
      if (isDirectory && (compressedSize != 0 || uncompressedSize != 0)) {
        throw FormatException(
            'INSA workbook ZIP entry "$name" is a directory with data');
      }

      if (_u32(bytes, localOffset) != 0x04034B50) {
        throw FormatException(
            'INSA workbook ZIP entry "$name" has an invalid local header');
      }
      final localFlags = _u16(bytes, localOffset + 6);
      final localMethod = _u16(bytes, localOffset + 8);
      final localNameLength = _u16(bytes, localOffset + 26);
      final localExtraLength = _u16(bytes, localOffset + 28);
      if (localFlags != flags) {
        throw FormatException(
            'INSA workbook ZIP entry "$name" has mismatched local flags');
      }
      if (localMethod != method) {
        throw FormatException(
            'INSA workbook ZIP entry "$name" has a mismatched local method');
      }
      final localNameEnd = localOffset + 30 + localNameLength;
      if (localNameEnd > centralOffset) {
        throw FormatException(
            'INSA workbook ZIP entry "$name" has a truncated local header');
      }
      final localNameBytes =
          Uint8List.sublistView(bytes, localOffset + 30, localNameEnd);
      if (!_bytesEqual(localNameBytes, nameBytes)) {
        throw FormatException(
            'INSA workbook ZIP entry "$name" has a mismatched local name');
      }
      final dataOffset = localNameEnd + localExtraLength;
      final dataEnd = dataOffset + compressedSize;
      if (dataOffset > centralOffset || dataEnd > centralOffset) {
        throw FormatException(
            'INSA workbook ZIP entry "$name" extends outside the entry area');
      }

      entries[name] = _InsaZipEntry(
        name: name,
        method: method,
        crc32: crc32,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localOffset: localOffset,
        dataOffset: dataOffset,
      );
      cursor = next;
    }

    if (cursor != centralEnd) {
      throw const FormatException(
          'INSA workbook is not a valid ZIP archive: central directory size '
          'is inconsistent');
    }

    final ordered = entries.values.toList(growable: false)
      ..sort((a, b) => a.localOffset.compareTo(b.localOffset));
    var previousEnd = -1;
    for (final entry in ordered) {
      if (entry.localOffset < previousEnd) {
        throw FormatException(
            'INSA workbook ZIP entry "${entry.name}" overlaps another entry');
      }
      previousEnd = entry.dataOffset + entry.compressedSize;
    }

    return InsaZipArchive._(bytes, entries);
  }

  /// Reads and verifies one exact entry.
  ///
  /// Throws [FormatException] when the entry is absent or its deflate stream,
  /// declared size or CRC-32 does not match.
  Uint8List read(String name) {
    final entry = _entries[name];
    if (entry == null) {
      throw FormatException('INSA workbook ZIP is missing entry "$name"');
    }
    if (entry.name.endsWith('/')) {
      throw FormatException('INSA workbook ZIP entry "$name" is a directory');
    }
    final compressed = Uint8List.sublistView(
        _bytes, entry.dataOffset, entry.dataOffset + entry.compressedSize);
    final Uint8List output;
    if (entry.method == 0) {
      if (entry.compressedSize != entry.uncompressedSize) {
        throw FormatException(
            'INSA workbook ZIP entry "${entry.name}" has inconsistent stored '
            'sizes');
      }
      output = Uint8List.fromList(compressed);
    } else {
      final sink = _BoundedByteSink(entry.uncompressedSize);
      try {
        final converter = ZLibDecoder(raw: true).startChunkedConversion(sink);
        converter.add(compressed);
        converter.close();
      } on FormatException catch (error) {
        throw FormatException(
            'INSA workbook ZIP entry "${entry.name}" has invalid deflate data: '
            '${error.message}');
      } on IOException catch (error) {
        throw FormatException(
            'INSA workbook ZIP entry "${entry.name}" has invalid deflate data: '
            '$error');
      }
      output = sink.takeBytes();
    }
    if (output.length != entry.uncompressedSize) {
      throw FormatException(
          'INSA workbook ZIP entry "${entry.name}" does not match its declared '
          'uncompressed size');
    }
    if (_crc32(output) != entry.crc32) {
      throw FormatException(
          'INSA workbook ZIP entry "${entry.name}" fails its CRC-32 check');
    }
    return output;
  }
}

/// A sink that stops decompression before it can exceed the declared size.
final class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (_builder.length + data.length > limit) {
      throw const FormatException(
          'declared uncompressed size exceeded');
    }
    _builder.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

int _findEndOfCentralDirectory(Uint8List bytes) {
  if (bytes.length < 22) {
    throw const FormatException(
        'INSA workbook is not a valid ZIP archive: file is too short');
  }
  final stop = bytes.length - 22 - 0xFFFF;
  for (var index = bytes.length - 22; index >= 0 && index >= stop; index--) {
    if (_u32(bytes, index) != 0x06054B50) continue;
    final commentLength = _u16(bytes, index + 20);
    if (index + 22 + commentLength == bytes.length) return index;
  }
  throw const FormatException(
      'INSA workbook is not a valid ZIP archive: end of central directory not '
      'found');
}

int _u16(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 2 > bytes.length) {
    throw const FormatException(
        'INSA workbook is not a valid ZIP archive: truncated structure');
  }
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _u32(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw const FormatException(
        'INSA workbook is not a valid ZIP archive: truncated structure');
  }
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

String _decodeEntryName(Uint8List bytes, int flags) {
  if ((flags & 0x0800) == 0) {
    for (final code in bytes) {
      if (code > 0x7F) {
        throw const FormatException(
            'INSA workbook ZIP entry name is not ASCII and lacks the UTF-8 '
            'flag');
      }
    }
  }
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException catch (error) {
    throw FormatException(
        'INSA workbook ZIP has an invalid UTF-8 entry name: ${error.message}');
  }
}

final RegExp _driveLetter = RegExp(r'^[A-Za-z]:');
final RegExp _nestedArchive = RegExp(
    r'\.(zip|xlsx|xlsm|xlsb|docx|pptx|odt)$',
    caseSensitive: false);

void _validateEntryName(String name) {
  if (name.isEmpty) {
    throw const FormatException('INSA workbook ZIP contains an empty name');
  }
  if (name.length > InsaZipLimits.maxEntryNameBytes) {
    throw const FormatException(
        'INSA workbook ZIP contains an overlong entry name');
  }
  if (name.startsWith('/') ||
      name.contains('\\') ||
      name.contains('\u0000') ||
      _driveLetter.hasMatch(name)) {
    throw FormatException(
        'INSA workbook ZIP contains an unsafe entry name "$name"');
  }
  final segments = name.split('/');
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index];
    if (segment == '..' || segment == '.') {
      throw FormatException(
          'INSA workbook ZIP contains an unsafe entry name "$name"');
    }
    if (segment.isEmpty) {
      final isTrailingDirectory =
          index == segments.length - 1 && name.endsWith('/');
      if (!isTrailingDirectory) {
        throw FormatException(
            'INSA workbook ZIP contains an unsafe entry name "$name"');
      }
    }
  }
  for (final rune in name.runes) {
    if (rune < 0x20 || rune == 0x7F) {
      throw FormatException(
          'INSA workbook ZIP contains a control character in "$name"');
    }
  }
  if (_nestedArchive.hasMatch(name)) {
    throw FormatException(
        'INSA workbook ZIP contains nested archive "$name"');
  }
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final List<int> _crcTable = List<int>.generate(256, (int value) {
  var crc = value;
  for (var bit = 0; bit < 8; bit++) {
    crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
  }
  return crc;
}, growable: false);

int _crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
