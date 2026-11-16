import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

NutritionWrite write(String id, DateTime at, {double energy = 50}) =>
    NutritionWrite(externalId: id, startedAt: at, energyKcal: energy);

void main() {
  test('pending export and deletion marker survive reopening SQLite', () async {
    final dir = await Directory.systemTemp.createTemp('salu-outbox-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/data.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    final entry = NutritionWrite(
        externalId: 'entry-1',
        startedAt: DateTime.utc(2026, 1, 1),
        energyKcal: 50,
        proteinG: 2);
    var store = SqliteHealthOutboxStore(db);
    await store.put(HealthOutboxItem(entry, HealthOutboxState.pending));
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    store = SqliteHealthOutboxStore(db);
    expect((await store.pending()).single.write.proteinG, 2);
    await store
        .put(HealthOutboxItem(entry, HealthOutboxState.externallyDeleted));
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    store = SqliteHealthOutboxStore(db);
    expect((await store.get('entry-1'))!.state,
        HealthOutboxState.externallyDeleted);
    expect(await store.pending(), isEmpty);
    await expectLater(
        store.put(HealthOutboxItem(entry, HealthOutboxState.pending)),
        throwsStateError);
    await db.close();
  });

  test('pending recovery is deterministic and excludes settled exports',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = SqliteHealthOutboxStore(db);
    Future<void> put(String id, DateTime at, HealthOutboxState state) =>
        store.put(HealthOutboxItem(write(id, at), state));
    await put('third', DateTime.utc(2026, 1, 3), HealthOutboxState.pending);
    await put('first-b', DateTime.utc(2026, 1, 1), HealthOutboxState.pending);
    await put('first-a', DateTime.utc(2026, 1, 1), HealthOutboxState.pending);
    await put('synced', DateTime.utc(2026, 1, 2), HealthOutboxState.synced);
    await put('deleted', DateTime.utc(2026, 1, 2),
        HealthOutboxState.externallyDeleted);
    await put('edited', DateTime.utc(2026, 1, 2),
        HealthOutboxState.externallyEdited);
    await put('restored', DateTime.utc(2026, 1, 2),
        HealthOutboxState.restoreReviewRequired);
    expect((await store.pending()).map((item) => item.write.externalId),
        ['first-a', 'first-b', 'third']);
  });

  test('review states cannot be overwritten by pending or synced writes',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = SqliteHealthOutboxStore(db);
    final entry = write('entry', DateTime.utc(2026));

    await store
        .put(HealthOutboxItem(entry, HealthOutboxState.restoreReviewRequired));
    await expectLater(
        store.put(HealthOutboxItem(entry, HealthOutboxState.pending)),
        throwsStateError);
    await expectLater(
        store.put(HealthOutboxItem(entry, HealthOutboxState.synced)),
        throwsStateError);
    expect((await store.get('entry'))!.state,
        HealthOutboxState.restoreReviewRequired);

    await store
        .put(HealthOutboxItem(entry, HealthOutboxState.externallyEdited));
    await expectLater(
        store.put(HealthOutboxItem(entry, HealthOutboxState.pending)),
        throwsStateError);
    await expectLater(
        store.put(HealthOutboxItem(entry, HealthOutboxState.synced)),
        throwsStateError);

    await store
        .put(HealthOutboxItem(entry, HealthOutboxState.externallyDeleted));
    await expectLater(
        store.put(HealthOutboxItem(entry, HealthOutboxState.synced)),
        throwsStateError);
    expect((await store.get('entry'))!.state,
        HealthOutboxState.externallyDeleted);
  });

  test('export instants persist independently of zone representation', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = SqliteHealthOutboxStore(db);
    final local = DateTime(2026, 1, 1, 12);
    final entry = NutritionWrite(
        externalId: 'entry', startedAt: local, energyKcal: 10);
    await store.put(HealthOutboxItem(entry, HealthOutboxState.pending));
    final recovered = (await store.get('entry'))!.write.startedAt;
    expect(recovered.isUtc, isTrue);
    expect(recovered.isAtSameMomentAs(local), isTrue);
  });

  test('each durable put advances the document revision', () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final store = SqliteHealthOutboxStore(db);
    final entry = write('entry', DateTime.utc(2026));
    await store.put(HealthOutboxItem(entry, HealthOutboxState.pending));
    await store.put(HealthOutboxItem(entry, HealthOutboxState.synced));
    await expectLater(
        store.put(HealthOutboxItem(entry, HealthOutboxState.pending)),
        throwsStateError);
    final rows = await (db.select(db.userDocuments)
          ..where((t) => t.id.equals('entry')))
        .get();
    final row = rows.singleWhere((candidate) =>
        candidate.collection == SqliteHealthOutboxStore.collection);
    expect(row.revision, 2);
    expect((await store.get('entry'))!.state, HealthOutboxState.synced);
  });

  test('restore does not replay unverified exports and deletion removes them',
      () async {
    final original = AppDatabase.memory();
    final restored = AppDatabase.memory();
    addTearDown(original.close);
    addTearDown(restored.close);
    final store = SqliteHealthOutboxStore(original);
    final entry = NutritionWrite(
        externalId: 'entry', startedAt: DateTime.utc(2026), energyKcal: 100);
    await store.put(HealthOutboxItem(entry, HealthOutboxState.pending));
    final archive = await ArchiveService(original).exportJson();
    await ArchiveService(restored).restoreJson(archive, confirmed: true);
    final recovered = SqliteHealthOutboxStore(restored);
    expect((await recovered.get('entry'))!.state,
        HealthOutboxState.restoreReviewRequired);
    expect(await recovered.pending(), isEmpty);
    await ArchiveService(restored).deleteLocalData(confirmed: true);
    expect(await recovered.get('entry'), isNull);
  });

  test('corrupt or untrusted export payloads are rejected', () {
    final entry = NutritionWrite(
        externalId: 'entry', startedAt: DateTime.utc(2026), energyKcal: 100);
    for (final state in HealthOutboxState.values) {
      final payload =
          encodeHealthOutbox(HealthOutboxItem(entry, state));
      expect(decodeHealthOutbox('entry', payload).state, state);
    }
    final valid = encodeHealthOutbox(
        HealthOutboxItem(entry, HealthOutboxState.pending));
    expect(decodeHealthOutbox('entry', valid).write.energyKcal, 100);
    expect(() => decodeHealthOutbox('other', valid), throwsFormatException);
    expect(() => decodeHealthOutbox('', valid), throwsFormatException);
    expect(
        () => decodeHealthOutbox('entry', 'not json'), throwsFormatException);
    expect(() => decodeHealthOutbox('entry', '[]'), throwsFormatException);

    Map<String, Object?> payload({
      Object? state = 'pending',
      Object? energy = 100,
      Object? startedAt,
    }) =>
        {
          'id': 'entry',
          'startedAt': startedAt ?? DateTime.utc(2026).toIso8601String(),
          'energyKcal': energy,
          'state': state,
        };

    expect(
        () => decodeHealthOutbox('entry', jsonEncode(payload(state: 'future'))),
        throwsFormatException);
    expect(
        () => decodeHealthOutbox('entry', jsonEncode(payload(energy: -1))),
        throwsFormatException);
    expect(
        () => decodeHealthOutbox('entry', jsonEncode(payload(energy: '100'))),
        throwsFormatException);
    expect(
        () => decodeHealthOutbox(
            'entry', jsonEncode(payload(startedAt: 'not a date'))),
        throwsFormatException);
    expect(
        () => decodeHealthOutbox(
            'entry', jsonEncode(payload(state: null))),
        throwsFormatException);
  });

  test('legacy payloads without optional macros still decode', () {
    final legacy = jsonEncode({
      'id': 'entry',
      'startedAt': DateTime.utc(2026).toIso8601String(),
      'energyKcal': 100.0,
      'proteinG': null,
      'carbohydrateG': null,
      'fatG': null,
      'state': 'pending',
    });
    final item = decodeHealthOutbox('entry', legacy);
    expect(item.write.proteinG, isNull);
    expect(item.write.carbohydrateG, isNull);
    expect(item.write.fatG, isNull);
    expect(item.state, HealthOutboxState.pending);

    final local = DateTime(2026, 1, 1, 12);
    final legacyLocal = jsonEncode({
      'id': 'entry',
      'startedAt': local.toIso8601String(),
      'energyKcal': 100.0,
      'proteinG': null,
      'carbohydrateG': null,
      'fatG': null,
      'state': 'synced',
    });
    final localItem = decodeHealthOutbox('entry', legacyLocal);
    expect(localItem.write.startedAt.isAtSameMomentAs(local), isTrue);
    expect(localItem.state, HealthOutboxState.synced);
  });
}
