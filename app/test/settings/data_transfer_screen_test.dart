import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/assistant/credential_store.dart';
import 'package:salu/src/assistant/operation_fence.dart';
import 'package:salu/src/data_transfer/archive_service.dart';
import 'package:salu/src/data_transfer/data_reset_service.dart';
import 'package:salu/src/data_transfer/data_transfer_screen.dart';
import 'package:salu/src/data_transfer/data_write_gate.dart';
import 'package:salu/src/features/settings/settings_screen.dart';
import 'package:salu/src/media/managed_media_store.dart';
import 'package:salu/src/providers.dart';
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

void main() {
  late AppDatabase db;
  late Directory supportDir;
  late Directory stagingDir;
  late _MemoryCredentialStore creds;
  late OperationFence fence;
  late DataWriteGate gate;
  late ArchiveService archiveService;
  late DataResetService resetService;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await installBundledCatalogue(db);
    supportDir = await Directory.systemTemp.createTemp('salu_ui_support_');
    stagingDir = await Directory.systemTemp.createTemp('salu_ui_staging_');
    creds = _MemoryCredentialStore();
    fence = OperationFence();
    gate = DataWriteGate();
    final media = ManagedMediaStore(
      directory: () async => supportDir,
      newId: RandomIdGenerator().next,
    );
    archiveService = ArchiveService(
      data: UserDataRepository(db),
      media: media,
      fence: fence,
      credentials: creds,
      gate: gate,
      stagingDirectory: () async => stagingDir,
      markerDirectory: () async => supportDir,
    );
    resetService = DataResetService(
      data: UserDataRepository(db),
      credentials: creds,
      fence: fence,
      gate: gate,
      supportDirectory: () async => supportDir,
      stagingDirectory: () async => stagingDir,
    );
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

  Widget wrap(Widget child) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        credentialStoreProvider.overrideWithValue(creds),
        operationFenceProvider.overrideWithValue(fence),
        dataWriteGateProvider.overrideWithValue(gate),
        archiveServiceProvider.overrideWithValue(archiveService),
        dataResetServiceProvider.overrideWithValue(resetService),
      ],
      child: MaterialApp(home: child),
    );
  }

  testWidgets('SettingsScreen replaces placeholders with real data actions',
      (tester) async {
    await tester.pumpWidget(wrap(const Scaffold(body: SettingsScreen())));
    await tester.pump();

    expect(find.text('not built yet'), findsNothing);
    expect(find.text('Encrypted backup & restore'), findsOneWidget);
    expect(find.text('Export CSV'), findsOneWidget);
    expect(find.text('Delete local data'), findsOneWidget);
  });

  testWidgets(
      'Backup validates password >= 12 chars, obscures input, and cancel reports no success',
      (tester) async {
    var wroteFile = false;
    await tester.pumpWidget(
      wrap(
        DataTransferScreen(
          pickSavePath: ({
            required suggestedName,
            required extension,
            required label,
          }) async =>
              null, // user cancels file picker
          writeBytes: (path, bytes) async => wroteFile = true,
        ),
      ),
    );

    await tester.tap(find.text('Encrypted backup'));
    await tester.pumpAndSettle();

    final pwField = tester.widget<TextField>(
      find.byKey(const Key('backup-password-field')),
    );
    final confirmField = tester.widget<TextField>(
      find.byKey(const Key('backup-confirm-field')),
    );
    expect(pwField.obscureText, isTrue);
    expect(confirmField.obscureText, isTrue);
    expect(find.textContaining('cannot be recovered'), findsOneWidget);

    // Too short
    await tester.enterText(
      find.byKey(const Key('backup-password-field')),
      'short',
    );
    await tester.enterText(
      find.byKey(const Key('backup-confirm-field')),
      'short',
    );
    await tester.tap(find.text('Create backup'));
    await tester.pumpAndSettle();
    expect(
      find.text('Password must be at least 12 characters.'),
      findsOneWidget,
    );

    // Valid password, but file picker cancelled
    await tester.enterText(
      find.byKey(const Key('backup-password-field')),
      'correct-horse-battery',
    );
    await tester.enterText(
      find.byKey(const Key('backup-confirm-field')),
      'correct-horse-battery',
    );
    await tester.tap(find.text('Create backup'));
    await tester.pumpAndSettle();

    expect(wroteFile, isFalse);
    expect(find.text('Encrypted backup saved.'), findsNothing);
    expect(creds.values.values, isNot(contains('correct-horse-battery')));
  });

  testWidgets(
      'Restore shows preview counts and requires second explicit confirmation',
      (tester) async {
    late Uint8List archiveBytes;
    await tester.runAsync(() async {
      await DriftPhotoMealRepository(db).saveNew(
        PhotoMeal(
          id: 'meal-1',
          date: DiaryDate.parse('2026-11-19'),
          slot: MealSlot.breakfast,
          caption: 'Oats',
          createdAt: DateTime.utc(2026, 11, 19, 8),
          items: <PhotoMealItem>[PhotoMealItem(name: 'Oats')],
        ),
      );
      archiveBytes = await archiveService.export(
        password: 'strong-backup-password',
        includeMedia: false,
      );

      // Erase DB so we can verify restore replaces it only after confirmation
      await UserDataRepository(db).erase();
      expect((await UserDataRepository(db).snapshot()).meals, isEmpty);
    });

    await tester.pumpWidget(
      wrap(
        DataTransferScreen(
          pickArchiveBytes: () async => archiveBytes,
        ),
      ),
    );

    await tester.tap(find.text('Restore backup'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('restore-password-field')),
      'strong-backup-password',
    );
    await tester.tap(find.text('Inspect backup'));
    await tester.pump();
    // Wait for Isolate.run Argon2id inspection to complete and dialog to open
    for (var i = 0;
        i < 60 && find.text('Replace local data?').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }

    // Second confirmation dialog shows counts & replacement warning
    expect(find.text('Replace local data?'), findsOneWidget);
    expect(find.textContaining('1 meals'), findsOneWidget);
    expect(find.textContaining('reconnected'), findsOneWidget);

    // Confirm restore
    await tester.tap(find.text('Replace local data'));
    await tester.pump();
    for (var i = 0;
        i < 40 && find.text('Backup restored.').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(find.text('Backup restored.'), findsOneWidget);
    final restored = await tester.runAsync(
      () => UserDataRepository(db).snapshot(),
    );
    expect(restored!.meals.length, 1);
  });

  testWidgets('Export CSV warns plaintext and writes CSV on confirm',
      (tester) async {
    Uint8List? written;
    await tester.pumpWidget(
      wrap(
        DataTransferScreen(
          pickSavePath: ({
            required suggestedName,
            required extension,
            required label,
          }) async =>
              '${stagingDir.path}${Platform.pathSeparator}$suggestedName',
          writeBytes: (path, bytes) async => written = bytes,
        ),
      ),
    );

    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();

    expect(find.textContaining('plaintext'), findsOneWidget);
    expect(find.textContaining('not a full backup'), findsOneWidget);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(written, isNotNull);
    expect(find.text('CSV exported.'), findsOneWidget);
  });

  testWidgets(
      'Delete local data lists scope and limitations and erases on confirm',
      (tester) async {
    await DriftPhotoMealRepository(db).saveNew(
      PhotoMeal(
        id: 'meal-del',
        date: DiaryDate.parse('2026-11-19'),
        slot: MealSlot.lunch,
        caption: 'Salad',
        createdAt: DateTime.utc(2026, 11, 19, 12),
        items: <PhotoMealItem>[PhotoMealItem(name: 'Salad')],
      ),
    );
    var erasedCallbackCalled = false;

    await tester.pumpWidget(
      wrap(
        DataTransferScreen(
          onDataErased: () => erasedCallbackCalled = true,
        ),
      ),
    );

    await tester.tap(find.text('Delete local data'));
    await tester.pumpAndSettle();

    expect(find.text('Delete local data?'), findsOneWidget);
    expect(find.textContaining('flash-forensics'), findsOneWidget);
    expect(find.textContaining('remote AI provider logs'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete local data'));
    await tester.pump();
    for (var i = 0; i < 40 && !erasedCallbackCalled; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    expect(erasedCallbackCalled, isTrue);
    final afterErase = await tester.runAsync(
      () => UserDataRepository(db).snapshot(),
    );
    expect(afterErase!.meals, isEmpty);
  });
}
