import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/data_transfer/archive_codec.dart';

Map<String, Object?> _validRecords({String? photoRef}) => <String, Object?>{
      'format': 1,
      'photoMeals': <Object?>[
        <String, Object?>{
          'id': 'meal-1',
          if (photoRef != null) 'photoRef': photoRef,
          'nutrients': <String, Object?>{
            'energy_kcal': <String, Object?>{'state': 'measured', 'value': 420},
            'protein_g': <String, Object?>{'state': 'reported', 'value': 25.5},
            'fat_g': <String, Object?>{
              'state': 'estimated',
              'value': 12.0,
              'basis': 'ai',
            },
            'fiber_g': <String, Object?>{'state': 'trace'},
            'sodium_mg': <String, Object?>{'state': 'unknown'},
          },
        },
      ],
      'localDocuments': <Object?>[
        <String, Object?>{'id': 'user-profile', 'name': 'Test'},
      ],
    };

Uint8List _zipRawFiles(List<ArchiveFile> files) {
  final archive = Archive();
  for (final f in files) {
    archive.addFile(f);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

ArchiveFile _jsonFile(String name, Map<String, Object?> data) {
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
  return ArchiveFile(name, bytes.length, bytes);
}

Map<String, Object?> _manifestFor(
  Map<String, Uint8List> files, {
  int format = 1,
  int recordsFormat = 1,
  int schemaVersion = 4,
  bool mediaOmitted = false,
}) {
  return <String, Object?>{
    'format': format,
    'schemaVersion': schemaVersion,
    'recordsFormat': recordsFormat,
    'mediaOmitted': mediaOmitted,
    'catalogueManifest': <String, Object?>{'version': '2026-11'},
    'counts': <String, Object?>{
      'media': files.keys.where((k) => k.startsWith('media/')).length,
      'recordCollections': 1,
      'totalRecords': 1,
    },
    'files': <String, Object?>{
      for (final e in files.entries)
        e.key: <String, Object?>{
          'size': e.value.length,
          'sha256': sha256.convert(e.value).toString(),
        },
    },
  };
}

void main() {
  test('round trips archive preserving all five nutrient states and media', () {
    final photoBytes = Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 1, 2]);
    final input = ArchiveContents(
      records: _validRecords(photoRef: 'media:img_001'),
      media: <String, Uint8List>{'img_001': photoBytes},
      catalogueManifest: <String, Object?>{'catalogueId': 'usda-sr-2026'},
    );

    final encoded = encodeArchive(input);
    final decoded = decodeArchive(encoded);

    expect(decoded.mediaOmitted, isFalse);
    expect(decoded.catalogueManifest, equals(input.catalogueManifest));
    expect(decoded.media.keys, equals(<String>['img_001']));
    expect(decoded.media['img_001'], orderedEquals(photoBytes));

    final meals = decoded.records['photoMeals']! as List<Object?>;
    final meal = meals.single! as Map<String, Object?>;
    final nutrients = meal['nutrients']! as Map<String, Object?>;
    expect((nutrients['energy_kcal']! as Map)['state'], 'measured');
    expect((nutrients['protein_g']! as Map)['state'], 'reported');
    expect((nutrients['fat_g']! as Map)['state'], 'estimated');
    expect((nutrients['fiber_g']! as Map)['state'], 'trace');
    expect((nutrients['sodium_mg']! as Map)['state'], 'unknown');
  });

  test('file-backed encodeArchiveToFile and decodeArchiveFromFile round trip',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('salu_codec_test_');
    addTearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    final mediaFile = File('${tempDir.path}/img_a.image');
    final mediaBytes =
        Uint8List.fromList(List<int>.generate(1024, (i) => i % 256));
    await mediaFile.writeAsBytes(mediaBytes, flush: true);

    final outZip = File('${tempDir.path}/out.zip');
    await encodeArchiveToFile(
      records: _validRecords(photoRef: 'media:img_a'),
      mediaFiles: <String, File>{'img_a': mediaFile},
      catalogueManifest: <String, Object?>{'version': 1},
      outputFile: outZip,
    );

    final decoded = await decodeArchiveFromFile(outZip);
    expect(decoded.media['img_a'], orderedEquals(mediaBytes));
    expect(decoded.mediaOmitted, isFalse);
  });

  test('records-only archive with mediaOmitted=true allows missing media refs',
      () {
    final input = ArchiveContents(
      records: _validRecords(photoRef: 'media:missing_photo_1'),
      media: const <String, Uint8List>{},
      catalogueManifest: const <String, Object?>{},
      mediaOmitted: true,
    );

    final encoded = encodeArchive(input);
    final decoded = decodeArchive(encoded);
    expect(decoded.mediaOmitted, isTrue);
    expect(decoded.media, isEmpty);
  });

  test('rejects broken media evidence ref when mediaOmitted is false', () {
    final input = ArchiveContents(
      records: _validRecords(photoRef: 'media:missing_photo_1'),
      media: const <String, Uint8List>{},
      catalogueManifest: const <String, Object?>{},
    );
    expect(() => encodeArchive(input), throwsA(isA<FormatException>()));
  });

  test('rejects unknown/future manifest and records format versions', () {
    final recordsBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(_validRecords())));
    final badManifestZip = _zipRawFiles(<ArchiveFile>[
      _jsonFile(
        'manifest.json',
        _manifestFor(<String, Uint8List>{'records.json': recordsBytes},
            format: 2),
      ),
      ArchiveFile('records.json', recordsBytes.length, recordsBytes),
    ]);
    expect(
        () => decodeArchive(badManifestZip), throwsA(isA<FormatException>()));

    final futureRecords = Map<String, Object?>.from(_validRecords())
      ..['format'] = 99;
    final futureRecordsBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(futureRecords)));
    final badRecordsZip = _zipRawFiles(<ArchiveFile>[
      _jsonFile(
        'manifest.json',
        _manifestFor(<String, Uint8List>{'records.json': futureRecordsBytes}),
      ),
      ArchiveFile(
          'records.json', futureRecordsBytes.length, futureRecordsBytes),
    ]);
    expect(() => decodeArchive(badRecordsZip), throwsA(isA<FormatException>()));
  });

  test('rejects duplicate ZIP members', () {
    final recordsBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(_validRecords())));
    final manifestFile = _jsonFile(
      'manifest.json',
      _manifestFor(<String, Uint8List>{'records.json': recordsBytes}),
    );
    final out = OutputMemoryStream();
    final encoder = ZipEncoder()..startEncode(out);
    encoder.add(manifestFile);
    encoder.add(ArchiveFile('records.json', recordsBytes.length, recordsBytes));
    encoder.add(ArchiveFile('records.json', recordsBytes.length, recordsBytes));
    encoder.endEncode();
    final dupZip = out.getBytes();
    expect(() => decodeArchive(dupZip), throwsA(isA<FormatException>()));
  });

  test(
      'rejects traversal, Windows drive/backslash, absolute paths, and symlinks',
      () {
    final recordsBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(_validRecords())));
    final baseManifest = _jsonFile(
      'manifest.json',
      _manifestFor(<String, Uint8List>{'records.json': recordsBytes}),
    );
    final baseRecords =
        ArchiveFile('records.json', recordsBytes.length, recordsBytes);

    final badPaths = <String>[
      '../escape.txt',
      'media/../../escape.jpg',
      r'C:\evil.txt',
      r'media\img_1',
      '/etc/passwd',
      'extra.json',
    ];
    for (final path in badPaths) {
      final zip = _zipRawFiles(<ArchiveFile>[
        baseManifest,
        baseRecords,
        ArchiveFile(path, 3, Uint8List.fromList(<int>[1, 2, 3])),
      ]);
      expect(
        () => decodeArchive(zip),
        throwsA(isA<FormatException>()),
        reason: 'Expected $path to be rejected',
      );
    }

    // Symlink member.
    final symlink = ArchiveFile.string('media/link_1', '/etc/passwd')
      ..symbolicLink = '/etc/passwd';
    final symlinkZip = _zipRawFiles(<ArchiveFile>[
      baseManifest,
      baseRecords,
      symlink,
    ]);
    expect(() => decodeArchive(symlinkZip), throwsA(isA<FormatException>()));
  });

  test('rejects SHA-256 hash mismatch', () {
    final recordsBytes =
        Uint8List.fromList(utf8.encode(jsonEncode(_validRecords())));
    final manifest =
        _manifestFor(<String, Uint8List>{'records.json': recordsBytes});
    final files = manifest['files']! as Map<String, Object?>;
    (files['records.json']! as Map<String, Object?>)['sha256'] = '0' * 64;

    final zip = _zipRawFiles(<ArchiveFile>[
      _jsonFile('manifest.json', manifest),
      ArchiveFile('records.json', recordsBytes.length, recordsBytes),
    ]);
    expect(() => decodeArchive(zip), throwsA(isA<FormatException>()));
  });

  test('rejects duplicate record IDs', () {
    final records = <String, Object?>{
      'format': 1,
      'photoMeals': <Object?>[
        <String, Object?>{'id': 'dup-1'},
        <String, Object?>{'id': 'dup-1'},
      ],
    };
    expect(
      () => encodeArchive(
        ArchiveContents(
          records: records,
          media: const <String, Uint8List>{},
          catalogueManifest: const <String, Object?>{},
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects malformed nutrient states', () {
    final badState = <String, Object?>{
      'format': 1,
      'photoMeals': <Object?>[
        <String, Object?>{
          'id': 'meal-bad-1',
          'nutrients': <String, Object?>{
            'energy_kcal': <String, Object?>{'state': 'guessed', 'value': 100},
          },
        },
      ],
    };
    expect(
      () => encodeArchive(
        ArchiveContents(
          records: badState,
          media: const <String, Uint8List>{},
          catalogueManifest: const <String, Object?>{},
        ),
      ),
      throwsA(isA<FormatException>()),
    );

    final negativeMeasured = <String, Object?>{
      'format': 1,
      'photoMeals': <Object?>[
        <String, Object?>{
          'id': 'meal-bad-2',
          'nutrients': <String, Object?>{
            'protein_g': <String, Object?>{'state': 'measured', 'value': -5},
          },
        },
      ],
    };
    expect(
      () => encodeArchive(
        ArchiveContents(
          records: negativeMeasured,
          media: const <String, Uint8List>{},
          catalogueManifest: const <String, Object?>{},
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects provider-profile endpoint-connections in archives', () {
    final topLevelForbidden = <String, Object?>{
      'format': 1,
      'endpoint-connections': <Object?>[
        <String, Object?>{'id': 'openai', 'apiKey': 'sk-secret'},
      ],
    };
    expect(
      () => encodeArchive(
        ArchiveContents(
          records: topLevelForbidden,
          media: const <String, Uint8List>{},
          catalogueManifest: const <String, Object?>{},
        ),
      ),
      throwsA(isA<FormatException>()),
    );

    final docForbidden = <String, Object?>{
      'format': 1,
      'localDocuments': <Object?>[
        <String, Object?>{
          'id': 'endpoint-connections',
          'profiles': <Object?>[]
        },
      ],
    };
    expect(
      () => encodeArchive(
        ArchiveContents(
          records: docForbidden,
          media: const <String, Uint8List>{},
          catalogueManifest: const <String, Object?>{},
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects ZIP bomb exceeding per-file expanded limit', () {
    // 17 MiB of zeroes compresses to ~17 KB in ZIP, exceeding the 16 MiB records.json cap.
    final bombBytes = Uint8List(maxRecordsJsonBytes + 1024 * 1024);
    final manifest =
        _manifestFor(<String, Uint8List>{'records.json': bombBytes});
    final bombZip = _zipRawFiles(<ArchiveFile>[
      _jsonFile('manifest.json', manifest),
      ArchiveFile('records.json', bombBytes.length, bombBytes),
    ]);
    expect(bombZip.length, lessThan(1024 * 1024));
    expect(() => decodeArchive(bombZip), throwsA(isA<FormatException>()));
  });
}
