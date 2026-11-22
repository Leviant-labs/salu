import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:salu/src/assistant/credential_store.dart';
import 'package:salu/src/assistant/operation_fence.dart';
import 'package:salu/src/data_transfer/archive_codec.dart';
import 'package:salu/src/data_transfer/archive_crypto.dart';
import 'package:salu/src/data_transfer/archive_service.dart';
import 'package:salu/src/data_transfer/data_write_gate.dart';
import 'package:salu/src/media/managed_media_store.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

final class _FakeCredentialStore implements CredentialStore {
  int clearCalls = 0;
  bool failNextClear = false;
  final Map<String, String> _secrets = <String, String>{};

  @override
  Future<String?> read(String id) async => _secrets[id];

  @override
  Future<void> write(String id, String secret) async {
    _secrets[id] = secret;
  }

  @override
  Future<void> delete(String id) async {
    _secrets.remove(id);
  }

  @override
  Future<void> clearSaluCredentials() async {
    clearCalls++;
    if (failNextClear) {
      failNextClear = false;
      throw StateError('keychain unavailable');
    }
    _secrets.clear();
  }
}

final class _FailingReplaceRepository extends UserDataRepository {
  _FailingReplaceRepository(super.db);

  @override
  Future<void> replace(UserDataSnapshot snapshot) async {
    throw StateError('injected DB commit failure');
  }
}

void main() {
  const password = 'correct-horse-battery-staple';

  Future<ManagedMediaStore> createMediaStore(
      Directory root, String prefix) async {
    var seq = 0;
    return ManagedMediaStore(
      directory: () async => root,
      newId: () => '$prefix-${++seq}',
    );
  }

  test(
      'export, inspect, and restore round trip with fresh media IDs and credential cleanup',
      () async {
    final tempRoot = await Directory.systemTemp.createTemp('salu_arch_rt_');
    addTearDown(() => tempRoot.delete(recursive: true));

    final srcDb = AppDatabase.memory();
    addTearDown(srcDb.close);
    final srcMediaDir =
        await Directory('${tempRoot.path}${Platform.pathSeparator}src_media')
            .create();
    final srcMedia = await createMediaStore(srcMediaDir, 'src');

    // Import a photo and label into source media store
    final rawPhoto = File('${tempRoot.path}${Platform.pathSeparator}photo.jpg');
    await rawPhoto.writeAsBytes(Uint8List.fromList([1, 2, 3, 4, 5]));
    final photoRef = await srcMedia.importImage(XFile(rawPhoto.path));

    final rawLabel = File('${tempRoot.path}${Platform.pathSeparator}label.jpg');
    await rawLabel.writeAsBytes(Uint8List.fromList([9, 8, 7, 6]));
    final labelRef = await srcMedia.importImage(XFile(rawLabel.path));

    await DriftPhotoMealRepository(srcDb).saveNew(
      PhotoMeal(
        id: 'meal-1',
        date: DiaryDate.parse('2026-11-19'),
        slot: MealSlot.dinner,
        caption: 'Pasta',
        createdAt: DateTime.utc(2026, 11, 19, 19, 0),
        photoPath: photoRef,
        items: [
          PhotoMealItem(
            id: 'item-1',
            name: 'Spaghetti',
            labelPaths: [labelRef],
          ),
        ],
      ),
    );
    await LocalDocumentStore(srcDb)
        .put('day:2026-11-19', 0, {'weightKg': 74.2});

    final srcService = ArchiveService(
      data: UserDataRepository(srcDb),
      media: srcMedia,
      fence: OperationFence(),
      credentials: _FakeCredentialStore(),
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}src_stage'),
    );

    final encrypted = await srcService.export(
      password: password,
      includeMedia: true,
    );

    // Inspect and restore into a fresh target DB & media store
    final dstDb = AppDatabase.memory();
    addTearDown(dstDb.close);
    final dstMediaDir =
        await Directory('${tempRoot.path}${Platform.pathSeparator}dst_media')
            .create();
    final dstMedia = await createMediaStore(dstMediaDir, 'dst');
    final dstCreds = _FakeCredentialStore();
    await dstCreds.write('openai', 'secret-token');
    final dstFence = OperationFence();
    final epochBeforeRestore = dstFence.capture();
    var restoredCallbacks = 0;

    final dstService = ArchiveService(
      data: UserDataRepository(dstDb),
      media: dstMedia,
      fence: dstFence,
      credentials: dstCreds,
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}dst_stage'),
      onRestored: () => restoredCallbacks++,
    );

    final preview = await dstService.inspect(encrypted, password);
    expect(preview.mealCount, 1);
    expect(preview.documentCount, 1);
    expect(preview.mediaCount, 2);
    expect(preview.mediaOmitted, isFalse);

    await dstService.restore(preview);

    // OperationFence invalidated late inference
    expect(dstFence.isCurrent(epochBeforeRestore), isFalse);
    // Credentials cleared and callback fired
    expect(dstCreds.clearCalls, 1);
    expect(await dstCreds.read('openai'), isNull);
    expect(restoredCallbacks, 1);

    // Restored meal has fresh managed media IDs and intact bytes
    final restoredMeals = await DriftPhotoMealRepository(dstDb)
        .listFor(DiaryDate.parse('2026-11-19'));
    expect(restoredMeals, hasLength(1));
    final restoredMeal = restoredMeals.single;
    expect(restoredMeal.photoPath, isNotNull);
    expect(restoredMeal.photoPath, isNot(photoRef));
    final restoredPhotoFile = await dstMedia.resolve(restoredMeal.photoPath!);
    expect(await restoredPhotoFile!.readAsBytes(), [1, 2, 3, 4, 5]);

    final restoredLabelRef = restoredMeal.items.single.labelPaths.single;
    expect(restoredLabelRef, isNot(labelRef));
    final restoredLabelFile = await dstMedia.resolve(restoredLabelRef);
    expect(await restoredLabelFile!.readAsBytes(), [9, 8, 7, 6]);
  });

  test('export without media sets mediaOmitted and restores records cleanly',
      () async {
    final tempRoot =
        await Directory.systemTemp.createTemp('salu_arch_nomedia_');
    addTearDown(() => tempRoot.delete(recursive: true));

    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalDocumentStore(db).put('day:2026-11-19', 0, {'weightKg': 71.0});
    final media = await createMediaStore(tempRoot, 'm');

    final service = ArchiveService(
      data: UserDataRepository(db),
      media: media,
      fence: OperationFence(),
      credentials: _FakeCredentialStore(),
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}stage'),
    );

    final encrypted = await service.export(
      password: password,
      includeMedia: false,
    );
    final preview = await service.inspect(encrypted, password);
    expect(preview.mediaOmitted, isTrue);
    expect(preview.mediaCount, 0);
    expect(preview.documentCount, 1);
  });

  test('tampered staging invalidates RestorePreview before restore', () async {
    final tempRoot = await Directory.systemTemp.createTemp('salu_arch_tamper_');
    addTearDown(() => tempRoot.delete(recursive: true));

    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalDocumentStore(db).put('day:2026-11-19', 0, {'weightKg': 70.0});
    final media = await createMediaStore(tempRoot, 'm');

    final service = ArchiveService(
      data: UserDataRepository(db),
      media: media,
      fence: OperationFence(),
      credentials: _FakeCredentialStore(),
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}stage'),
    );

    final encrypted = await service.export(
      password: password,
      includeMedia: false,
    );
    final preview = await service.inspect(encrypted, password);

    // Tamper with staged records.json
    final recordsFile = File(
      '${preview.stagingDirPath}${Platform.pathSeparator}records.json',
    );
    await recordsFile.writeAsString('{"tampered":true}', flush: true);

    await expectLater(
      service.restore(preview),
      throwsA(isA<FormatException>()),
    );
  });

  test(
      'injected media-write failure before DB commit leaves old DB and media intact',
      () async {
    final tempRoot = await Directory.systemTemp.createTemp('salu_arch_mfail_');
    addTearDown(() => tempRoot.delete(recursive: true));

    final srcDb = AppDatabase.memory();
    addTearDown(srcDb.close);
    final srcMedia = await createMediaStore(
      await Directory('${tempRoot.path}${Platform.pathSeparator}src').create(),
      'src',
    );
    final raw = File('${tempRoot.path}${Platform.pathSeparator}a.jpg');
    await raw.writeAsBytes([10, 20, 30]);
    final srcRef = await srcMedia.importImage(XFile(raw.path));
    await DriftPhotoMealRepository(srcDb).saveNew(
      PhotoMeal(
        id: 'new-meal',
        date: DiaryDate.parse('2026-11-19'),
        slot: MealSlot.lunch,
        caption: 'New',
        createdAt: DateTime.utc(2026, 11, 19, 12, 0),
        photoPath: srcRef,
      ),
    );

    final srcService = ArchiveService(
      data: UserDataRepository(srcDb),
      media: srcMedia,
      fence: OperationFence(),
      credentials: _FakeCredentialStore(),
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}src_stage'),
    );
    final encrypted =
        await srcService.export(password: password, includeMedia: true);

    // Target DB has existing data + existing media
    final dstDb = AppDatabase.memory();
    addTearDown(dstDb.close);
    final dstMediaRoot =
        await Directory('${tempRoot.path}${Platform.pathSeparator}dst')
            .create();
    final dstMedia = await createMediaStore(dstMediaRoot, 'dst');
    final oldRef = await dstMedia.importImage(XFile(raw.path));
    await LocalDocumentStore(dstDb)
        .put('day:2026-11-19', 0, {'weightKg': 80.0});

    final dstService = ArchiveService(
      data: UserDataRepository(dstDb),
      media: dstMedia,
      fence: OperationFence(),
      credentials: _FakeCredentialStore(),
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}dst_stage'),
      stageMediaOverride: (_) async =>
          throw const FileSystemException('disk full'),
    );

    final preview = await dstService.inspect(encrypted, password);
    await expectLater(
      dstService.restore(preview),
      throwsA(isA<FileSystemException>()),
    );

    // Old DB and old media remain intact
    expect(
      (await LocalDocumentStore(dstDb).read('day:2026-11-19'))
          ?.data['weightKg'],
      80.0,
    );
    expect(await dstMedia.resolve(oldRef), isNotNull);
  });

  test(
      'injected DB failure after media staging cleans only new media and keeps old DB',
      () async {
    final tempRoot = await Directory.systemTemp.createTemp('salu_arch_dbfail_');
    addTearDown(() => tempRoot.delete(recursive: true));

    final srcDb = AppDatabase.memory();
    addTearDown(srcDb.close);
    final srcMedia = await createMediaStore(
      await Directory('${tempRoot.path}${Platform.pathSeparator}src').create(),
      'src',
    );
    final raw = File('${tempRoot.path}${Platform.pathSeparator}b.jpg');
    await raw.writeAsBytes([40, 50, 60]);
    final srcRef = await srcMedia.importImage(XFile(raw.path));
    await DriftPhotoMealRepository(srcDb).saveNew(
      PhotoMeal(
        id: 'new-meal',
        date: DiaryDate.parse('2026-11-19'),
        slot: MealSlot.lunch,
        caption: 'New',
        createdAt: DateTime.utc(2026, 11, 19, 12, 0),
        photoPath: srcRef,
      ),
    );

    final srcService = ArchiveService(
      data: UserDataRepository(srcDb),
      media: srcMedia,
      fence: OperationFence(),
      credentials: _FakeCredentialStore(),
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}src_stage'),
    );
    final encrypted =
        await srcService.export(password: password, includeMedia: true);

    final dstDb = AppDatabase.memory();
    addTearDown(dstDb.close);
    final dstMediaRoot =
        await Directory('${tempRoot.path}${Platform.pathSeparator}dst')
            .create();
    final dstMedia = await createMediaStore(dstMediaRoot, 'dst');
    final oldRef = await dstMedia.importImage(XFile(raw.path));
    await LocalDocumentStore(dstDb)
        .put('day:2026-11-19', 0, {'weightKg': 81.0});

    final dstService = ArchiveService(
      data: _FailingReplaceRepository(dstDb),
      media: dstMedia,
      fence: OperationFence(),
      credentials: _FakeCredentialStore(),
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}dst_stage'),
    );

    final preview = await dstService.inspect(encrypted, password);
    await expectLater(
      dstService.restore(preview),
      throwsStateError,
    );

    // Old DB and old media remain intact; newly staged media was cleaned up
    expect(
      (await LocalDocumentStore(dstDb).read('day:2026-11-19'))
          ?.data['weightKg'],
      81.0,
    );
    expect(await dstMedia.resolve(oldRef), isNotNull);
    final mediaFiles = await Directory(
      '${dstMediaRoot.path}${Platform.pathSeparator}meal-images',
    ).list().toList();
    expect(mediaFiles, hasLength(1));
  });

  test(
      'interrupted credential cleanup leaves marker in durable markerDirectory, still fires onRestored, and resumes cleanly',
      () async {
    final tempRoot = await Directory.systemTemp.createTemp('salu_arch_cred_');
    addTearDown(() => tempRoot.delete(recursive: true));

    final db = AppDatabase.memory();
    addTearDown(db.close);
    await LocalDocumentStore(db).put('day:2026-11-19', 0, {'weightKg': 73.0});
    final media = await createMediaStore(tempRoot, 'm');
    final creds = _FakeCredentialStore();
    await creds.write('openai', 'token');
    creds.failNextClear = true;
    var restoredCallbacks = 0;

    final markerDir =
        Directory('${tempRoot.path}${Platform.pathSeparator}durable_support');
    final service = ArchiveService(
      data: UserDataRepository(db),
      media: media,
      fence: OperationFence(),
      credentials: creds,
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}stage'),
      markerDirectory: () async => markerDir,
      onRestored: () => restoredCallbacks++,
    );

    final encrypted =
        await service.export(password: password, includeMedia: false);
    final preview = await service.inspect(encrypted, password);

    // Restore commits DB, fails credential clear, leaves marker in durable dir,
    // and still invokes onRestored because DB commit succeeded.
    await expectLater(service.restore(preview), throwsStateError);
    expect(await creds.read('openai'), 'token');
    expect(restoredCallbacks, 1);
    expect(
      await File(
        '${markerDir.path}${Platform.pathSeparator}pending-credential-cleanup.marker',
      ).exists(),
      isTrue,
    );

    // Resuming completes the credential wipe and removes marker
    await service.resumePendingCredentialCleanup();
    expect(await creds.read('openai'), isNull);
    expect(creds.clearCalls, 2);
    expect(
      await File(
        '${markerDir.path}${Platform.pathSeparator}pending-credential-cleanup.marker',
      ).exists(),
      isFalse,
    );

    // Calling resume again is a no-op
    await service.resumePendingCredentialCleanup();
    expect(creds.clearCalls, 2);
  });

  test('inspect rejects archive with broken foreign key before restore',
      () async {
    final tempRoot = await Directory.systemTemp.createTemp('salu_arch_fk_');
    addTearDown(() => tempRoot.delete(recursive: true));

    final db = AppDatabase.memory();
    addTearDown(db.close);
    final media = await createMediaStore(tempRoot, 'm');
    final service = ArchiveService(
      data: UserDataRepository(db),
      media: media,
      fence: OperationFence(),
      credentials: _FakeCredentialStore(),
      gate: DataWriteGate(),
      stagingDirectory: () async =>
          Directory('${tempRoot.path}${Platform.pathSeparator}stage'),
    );

    final brokenSnapshot = UserDataSnapshot(
      entries: const [],
      entryItems: [
        {
          'id': 'item-1',
          'entryId': 'missing-entry',
          'foodId': null,
          'name': 'Apple',
          'grams': 100.0,
          'nutrientsJson': '{}',
          'position': 0,
        },
      ],
      meals: const [],
      documents: const [],
      mutations: const [],
    );

    final zipBytes = encodeArchive(
      ArchiveContents(
        records: brokenSnapshot.toJson(),
        media: const {},
        catalogueManifest: const {},
        mediaOmitted: true,
      ),
    );
    final encrypted = await encryptArchive(zipBytes, password);

    await expectLater(
      service.inspect(encrypted, password),
      throwsA(isA<FormatException>()),
    );
  });
}
