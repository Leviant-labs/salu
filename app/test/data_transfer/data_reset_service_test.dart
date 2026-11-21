import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/credential_store.dart';
import 'package:salu/src/assistant/operation_fence.dart';
import 'package:salu/src/data_transfer/data_reset_service.dart';
import 'package:salu/src/data_transfer/data_write_gate.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<void> clearSaluCredentials() async {
    values.removeWhere((key, _) => key.startsWith('salu.'));
  }
}

Future<void> _seedUserAndSystemData(
  AppDatabase db,
  Directory supportDir,
  _MemoryCredentialStore creds,
) async {
  await installBundledCatalogue(db);
  final docs = LocalDocumentStore(db);
  await docs.put(
    'planning-profile',
    0,
    <String, Object?>{'onboarded': true},
  );
  await docs.put('endpoint-connections', 0, <String, Object?>{});
  await docs.put(
    'catalogue-edition:usda',
    0,
    <String, Object?>{'version': '2026-01'},
  );
  await docs.put(
    'search-index-state',
    0,
    <String, Object?>{'ready': true},
  );

  final meals = DriftPhotoMealRepository(db);
  await meals.saveNew(
    PhotoMeal(
      id: 'meal-1',
      date: DiaryDate.parse('2026-11-19'),
      slot: MealSlot.lunch,
      caption: 'Soup',
      createdAt: DateTime.utc(2026, 11, 19, 12),
      items: <PhotoMealItem>[
        PhotoMealItem(name: 'Tomato soup'),
      ],
    ),
  );

  // Owned directories and files
  final mediaDir =
      await Directory('${supportDir.path}${Platform.pathSeparator}meal-images')
          .create(recursive: true);
  await File('${mediaDir.path}${Platform.pathSeparator}photo1.jpg')
      .writeAsBytes(<int>[1, 2, 3]);
  final thumbDir =
      await Directory('${supportDir.path}${Platform.pathSeparator}thumbnails')
          .create(recursive: true);
  await File('${thumbDir.path}${Platform.pathSeparator}thumb1.jpg')
      .writeAsBytes(<int>[4, 5, 6]);

  // Legacy JSON files that must be deleted so they cannot reimport
  await File(
    '${supportDir.path}${Platform.pathSeparator}planning_profile_v1.json',
  ).writeAsString('{"onboarded":true}');
  await File(
    '${supportDir.path}${Platform.pathSeparator}week_plan_v1_2026-11-16.json',
  ).writeAsString('{"days":[]}');

  // Unrelated file in supportDir that must NOT be deleted
  await File('${supportDir.path}${Platform.pathSeparator}unrelated.txt')
      .writeAsString('keep-me');

  // Credentials: salu.* cleared, unrelated kept
  await creds.write('salu.endpoint.primary', 'secret-token');
  await creds.write('other.app.key', 'keep-this-secret');
}

void main() {
  late AppDatabase db;
  late Directory supportDir;
  late Directory stagingDir;
  late _MemoryCredentialStore creds;
  late OperationFence fence;
  late DataWriteGate gate;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    supportDir = await Directory.systemTemp.createTemp('salu_reset_support_');
    stagingDir = await Directory.systemTemp.createTemp('salu_reset_staging_');
    creds = _MemoryCredentialStore();
    fence = OperationFence();
    gate = DataWriteGate();
  });

  tearDown(() async {
    await db.close();
    if (await supportDir.exists()) {
      await supportDir.delete(recursive: true);
    }
    if (await stagingDir.exists()) {
      await stagingDir.delete(recursive: true);
    }
  });

  test(
      'erase clears owned data, legacy files, and salu.* credentials while preserving catalogue and unrelated files',
      () async {
    await _seedUserAndSystemData(db, supportDir, creds);
    await Directory('${stagingDir.path}${Platform.pathSeparator}export-123')
        .create(recursive: true);
    await File('${stagingDir.path}${Platform.pathSeparator}unrelated-tmp.txt')
        .writeAsString('keep-tmp');

    final token = fence.capture();
    var resetCalled = false;

    final service = DataResetService(
      data: UserDataRepository(db),
      credentials: creds,
      fence: fence,
      gate: gate,
      supportDirectory: () async => supportDir,
      stagingDirectory: () async => stagingDir,
      onReset: () => resetCalled = true,
    );

    await service.erase();

    expect(resetCalled, isTrue);
    expect(fence.isCurrent(token), isFalse);

    // Marker removed on full success
    expect(
      await File(
        '${supportDir.path}${Platform.pathSeparator}${DataResetService.markerFileName}',
      ).exists(),
      isFalse,
    );

    // User data erased
    final snapshot = await UserDataRepository(db).snapshot();
    expect(snapshot.meals, isEmpty);
    expect(snapshot.entries, isEmpty);
    expect(snapshot.documents, isEmpty);

    // Catalogue and nonpersonal system/edition docs preserved
    final foods = await DriftFoodRepository(db).search('oat');
    expect(foods, isNotEmpty);
    final docs = LocalDocumentStore(db);
    expect(await docs.read('catalogue-edition:usda'), isNotNull);
    expect(await docs.read('search-index-state'), isNotNull);
    expect(await docs.read('endpoint-connections'), isNull);

    // Owned dirs & legacy files deleted
    expect(
      await Directory('${supportDir.path}${Platform.pathSeparator}meal-images')
          .exists(),
      isFalse,
    );
    expect(
      await Directory('${supportDir.path}${Platform.pathSeparator}thumbnails')
          .exists(),
      isFalse,
    );
    expect(
      await File(
        '${supportDir.path}${Platform.pathSeparator}planning_profile_v1.json',
      ).exists(),
      isFalse,
    );
    expect(
      await File(
        '${supportDir.path}${Platform.pathSeparator}week_plan_v1_2026-11-16.json',
      ).exists(),
      isFalse,
    );
    expect(
      await Directory('${stagingDir.path}${Platform.pathSeparator}export-123')
          .exists(),
      isFalse,
    );

    // Unrelated files and credentials untouched
    expect(
      await File('${supportDir.path}${Platform.pathSeparator}unrelated.txt')
          .readAsString(),
      'keep-me',
    );
    expect(
      await File('${stagingDir.path}${Platform.pathSeparator}unrelated-tmp.txt')
          .readAsString(),
      'keep-tmp',
    );
    expect(await creds.read('salu.endpoint.primary'), isNull);
    expect(await creds.read('other.app.key'), 'keep-this-secret');
  });

  test(
      'rejected concurrent exclusive operation never leaves an orphan reset marker',
      () async {
    final blocker = Completer<void>();
    final activeExclusive = gate.exclusive(() => blocker.future);

    final service = DataResetService(
      data: UserDataRepository(db),
      credentials: creds,
      fence: fence,
      gate: gate,
      supportDirectory: () async => supportDir,
    );

    await expectLater(service.erase(), throwsA(isA<StateError>()));

    final marker = File(
      '${supportDir.path}${Platform.pathSeparator}${DataResetService.markerFileName}',
    );
    expect(await marker.exists(), isFalse);

    blocker.complete();
    await activeExclusive;
  });

  for (final failPhase in const <String>[
    'after_marker',
    'after_db',
    'after_media',
  ]) {
    test(
        'resumeIfPending idempotently completes erase after failure at $failPhase',
        () async {
      await _seedUserAndSystemData(db, supportDir, creds);

      final failingService = DataResetService(
        data: UserDataRepository(db),
        credentials: creds,
        fence: fence,
        gate: gate,
        supportDirectory: () async => supportDir,
        onPhaseForTest: (phase) async {
          if (phase == failPhase) {
            throw StateError('Simulated crash at $phase');
          }
        },
      );

      await expectLater(
        failingService.erase(),
        throwsA(isA<StateError>()),
      );

      // Marker must still be present on disk!
      final marker = File(
        '${supportDir.path}${Platform.pathSeparator}${DataResetService.markerFileName}',
      );
      expect(await marker.exists(), isTrue);

      // Resume on next launch
      var resumed = false;
      final recoveryService = DataResetService(
        data: UserDataRepository(db),
        credentials: creds,
        fence: fence,
        gate: gate,
        supportDirectory: () async => supportDir,
        onReset: () => resumed = true,
      );

      await recoveryService.resumeIfPending();

      expect(resumed, isTrue);
      expect(await marker.exists(), isFalse);
      expect((await UserDataRepository(db).snapshot()).meals, isEmpty);
      expect(
        await File(
          '${supportDir.path}${Platform.pathSeparator}planning_profile_v1.json',
        ).exists(),
        isFalse,
      );
      expect(await creds.read('salu.endpoint.primary'), isNull);
      expect(await creds.read('other.app.key'), 'keep-this-secret');
      expect(
        await File('${supportDir.path}${Platform.pathSeparator}unrelated.txt')
            .exists(),
        isTrue,
      );
    });
  }

  test(
      'erase blocks concurrent runWrite calls until exclusive section completes',
      () async {
    await _seedUserAndSystemData(db, supportDir, creds);
    final events = <String>[];
    final eraseStarted = Completer<void>();
    final holdErase = Completer<void>();

    final service = DataResetService(
      data: UserDataRepository(db),
      credentials: creds,
      fence: fence,
      gate: gate,
      supportDirectory: () async => supportDir,
      onPhaseForTest: (phase) async {
        if (phase == 'after_marker') {
          events.add('erase_started');
          eraseStarted.complete();
          await holdErase.future;
        }
      },
    );

    final eraseFuture = service.erase().then((_) => events.add('erase_done'));
    await eraseStarted.future;

    await expectLater(
      gate.runWrite(() async {
        events.add('blocked_write_ran');
      }),
      throwsA(isA<DataWriteBlockedException>()),
    );
    expect(events, <String>['erase_started']);

    holdErase.complete();
    await eraseFuture;
    expect(events, <String>['erase_started', 'erase_done']);

    // Once erase completes, writes are accepted again.
    await gate.runWrite(() async {
      events.add('post_erase_write');
    });
    expect(events, <String>['erase_started', 'erase_done', 'post_erase_write']);
  });
}
