import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

class MemoryOutbox implements HealthOutboxStore {
  final items = <String, HealthOutboxItem>{};
  @override
  Future<HealthOutboxItem?> get(String id) async => items[id];
  @override
  Future<void> put(HealthOutboxItem item) async {
    items[item.write.externalId] = item;
  }
}

class FakeHealth implements HealthPort {
  Set<HealthDataType> supported = HealthDataType.values.toSet();
  HealthAccess access = HealthAccess.granted;
  Set<HealthDataType>? checked;
  int writes = 0;
  bool offline = false;
  @override
  Future<Set<HealthDataType>> availableTypes() async => supported;
  @override
  Future<HealthAccess> authorization(Set<HealthDataType> types) async {
    checked = types;
    return access;
  }

  @override
  Future<void> writeNutrition(NutritionWrite write) async {
    if (offline) throw StateError('offline');
    writes++;
  }

  @override
  Future<HealthAccess> request(Set<HealthDataType> types) async => access;
  @override
  Future<void> deleteNutrition(String externalId) async {}
  @override
  Future<List<WeightSample>> readBodyMass(DateTime from, DateTime to) async =>
      [];
}

void main() {
  late FakeHealth platform;
  late MemoryOutbox store;
  late HealthOutbox outbox;
  late NutritionWrite entry;
  setUp(() {
    platform = FakeHealth();
    store = MemoryOutbox();
    outbox = HealthOutbox(platform, store);
    entry = NutritionWrite(
        externalId: 'entry',
        startedAt: DateTime.utc(2026),
        energyKcal: 100,
        proteinG: 5);
  });

  test('offline export survives retry and duplicate enqueue', () async {
    await outbox.enqueueConfirmed(entry);
    platform.offline = true;
    expect(await outbox.dispatch('entry'), HealthDispatchResult.retryLater);
    expect(store.items['entry']!.state, HealthOutboxState.pending);
    platform.offline = false;
    await outbox.enqueueConfirmed(entry);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.sent);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.alreadySynced);
    expect(platform.writes, 1);
    expect(platform.checked,
        {HealthDataType.dietaryEnergy, HealthDataType.dietaryProtein});
  });
  test('revocation and unsupported types do not dispatch', () async {
    await outbox.enqueueConfirmed(entry);
    platform.access = HealthAccess.denied;
    expect(
        await outbox.dispatch('entry'), HealthDispatchResult.permissionDenied);
    platform.access = HealthAccess.granted;
    platform.supported.remove(HealthDataType.dietaryProtein);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.unsupported);
    expect(platform.writes, 0);
    expect(store.items['entry']!.state, HealthOutboxState.pending);
  });
  test('external edits or deletions block automatic retry and recreation',
      () async {
    await outbox.enqueueConfirmed(entry);
    await outbox.recordExternalChange('entry', HealthExternalChange.deleted);
    await outbox.recordExternalChange('entry', HealthExternalChange.edited);
    await outbox.enqueueConfirmed(entry);
    expect(store.items['entry']!.state, HealthOutboxState.externallyDeleted);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.needsReview);
    expect(platform.writes, 0);
  });
  test('a stable ID cannot be reused with different contents', () async {
    await outbox.enqueueConfirmed(entry);
    final changed = NutritionWrite(
        externalId: 'entry', startedAt: entry.startedAt, energyKcal: 200);
    await expectLater(outbox.enqueueConfirmed(changed), throwsStateError);
  });
  test('an external edit to a synced export requires review', () async {
    await outbox.enqueueConfirmed(entry);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.sent);
    await outbox.recordExternalChange('entry', HealthExternalChange.edited);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.needsReview);
    expect(platform.writes, 1);
  });
  test('invalid nutrient amounts cannot enter the outbox', () async {
    final invalid = NutritionWrite(
        externalId: 'invalid',
        startedAt: entry.startedAt,
        energyKcal: double.nan);
    await expectLater(outbox.enqueueConfirmed(invalid), throwsArgumentError);
    expect(store.items, isEmpty);
  });
}
