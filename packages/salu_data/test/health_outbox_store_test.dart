import 'dart:io';
import 'package:drift/native.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('pending export and deletion marker survive reopening SQLite', () async {
    final dir = await Directory.systemTemp.createTemp('salu-outbox-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/data.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    final write = NutritionWrite(
        externalId: 'entry-1',
        startedAt: DateTime.utc(2026, 1, 1),
        energyKcal: 50,
        proteinG: 2);
    var store = SqliteHealthOutboxStore(db);
    await store.put(HealthOutboxItem(write, HealthOutboxState.pending));
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    store = SqliteHealthOutboxStore(db);
    expect((await store.pending()).single.write.proteinG, 2);
    await store
        .put(HealthOutboxItem(write, HealthOutboxState.externallyDeleted));
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    store = SqliteHealthOutboxStore(db);
    expect((await store.get('entry-1'))!.state,
        HealthOutboxState.externallyDeleted);
    expect(await store.pending(), isEmpty);
    await expectLater(
        store.put(HealthOutboxItem(write, HealthOutboxState.pending)),
        throwsStateError);
    await db.close();
  });

  test('restore does not replay unverified exports and deletion removes them',
      () async {
    final original = AppDatabase.memory();
    final restored = AppDatabase.memory();
    addTearDown(original.close);
    addTearDown(restored.close);
    final store = SqliteHealthOutboxStore(original);
    final write = NutritionWrite(
        externalId: 'entry', startedAt: DateTime.utc(2026), energyKcal: 100);
    await store.put(HealthOutboxItem(write, HealthOutboxState.pending));
    final archive = await ArchiveService(original).exportJson();
    await ArchiveService(restored).restoreJson(archive, confirmed: true);
    final recovered = SqliteHealthOutboxStore(restored);
    expect((await recovered.get('entry'))!.state,
        HealthOutboxState.restoreReviewRequired);
    expect(await recovered.pending(), isEmpty);
    await ArchiveService(restored).deleteLocalData(confirmed: true);
    expect(await recovered.get('entry'), isNull);
  });
}
