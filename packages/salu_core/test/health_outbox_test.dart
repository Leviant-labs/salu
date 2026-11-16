import 'package:salu_core/salu_core.dart';
import 'package:test/test.dart';

/// In-memory outbox that mirrors the durable store's transition guards, so core
/// tests fail if deletion protection is only enforced by the SQLite store.
class MemoryOutbox implements HealthOutboxStore {
  final items = <String, HealthOutboxItem>{};

  @override
  Future<HealthOutboxItem?> get(String id) async => items[id];

  @override
  Future<void> put(HealthOutboxItem item) async {
    final previous = items[item.write.externalId];
    if (previous != null) {
      if (previous.state == HealthOutboxState.externallyDeleted &&
          item.state != HealthOutboxState.externallyDeleted) {
        throw StateError('External deletion requires review');
      }
      if (previous.state == HealthOutboxState.synced &&
          item.state == HealthOutboxState.pending) {
        throw StateError('Synced export cannot be re-queued');
      }
      if ((previous.state == HealthOutboxState.externallyEdited ||
              previous.state == HealthOutboxState.restoreReviewRequired) &&
          (item.state == HealthOutboxState.pending ||
              item.state == HealthOutboxState.synced)) {
        throw StateError('External edit requires review');
      }
    }
    items[item.write.externalId] = item;
  }

  @override
  Future<List<HealthOutboxItem>> pending() async {
    final result = items.values
        .where((item) => item.state == HealthOutboxState.pending)
        .toList()
      ..sort((a, b) {
        final byTime = a.write.startedAt.compareTo(b.write.startedAt);
        if (byTime != 0) return byTime;
        return a.write.externalId.compareTo(b.write.externalId);
      });
    return result;
  }
}

/// Simulates the platform write succeeding before local state can be persisted.
class FlakyOutbox extends MemoryOutbox {
  bool failNextSyncedPut = false;

  @override
  Future<void> put(HealthOutboxItem item) async {
    if (failNextSyncedPut && item.state == HealthOutboxState.synced) {
      failNextSyncedPut = false;
      throw StateError('disk full');
    }
    await super.put(item);
  }
}

class FakeHealth implements HealthPort {
  Set<HealthDataType> supported = HealthDataType.values.toSet();
  HealthAccess access = HealthAccess.granted;
  Set<HealthDataType>? checked;
  final List<String> writtenIds = [];
  int permissionPrompts = 0;
  bool offline = false;
  bool denyOnWrite = false;
  bool failAvailability = false;
  Future<void> Function(NutritionWrite write)? onWrite;

  int get writes => writtenIds.length;

  @override
  Future<Set<HealthDataType>> availableTypes() async {
    if (failAvailability) throw StateError('platform unavailable');
    return supported;
  }

  @override
  Future<HealthAccess> authorization(Set<HealthDataType> types) async {
    checked = types;
    return access;
  }

  @override
  Future<HealthAccess> request(Set<HealthDataType> types) async {
    permissionPrompts++;
    return access;
  }

  @override
  Future<void> writeNutrition(NutritionWrite write) async {
    if (offline) throw StateError('offline');
    if (denyOnWrite) throw const HealthPermissionException();
    final callback = onWrite;
    if (callback != null) await callback(write);
    writtenIds.add(write.externalId);
  }

  @override
  Future<void> deleteNutrition(String externalId) async {}

  @override
  Future<List<WeightSample>> readBodyMass(DateTime from, DateTime to) async =>
      <WeightSample>[];
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

  test('queuing never writes before an explicit dispatch', () async {
    await outbox.enqueueConfirmed(entry);
    expect(platform.writes, 0);
    expect(platform.permissionPrompts, 0);
    expect(store.items['entry']!.state, HealthOutboxState.pending);
  });

  test('offline export survives retry without duplicate enqueue or write',
      () async {
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
    expect(platform.permissionPrompts, 0);
  });

  test('revocation and unsupported types do not dispatch or prompt', () async {
    await outbox.enqueueConfirmed(entry);
    platform.access = HealthAccess.denied;
    expect(
        await outbox.dispatch('entry'), HealthDispatchResult.permissionDenied);
    expect(platform.permissionPrompts, 0);
    expect(store.items['entry']!.state, HealthOutboxState.pending);

    platform.access = HealthAccess.granted;
    platform.supported.remove(HealthDataType.dietaryProtein);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.unsupported);
    expect(platform.permissionPrompts, 0);
    expect(platform.writes, 0);

    platform.supported = HealthDataType.values.toSet();
    platform.access = HealthAccess.unavailable;
    expect(await outbox.dispatch('entry'), HealthDispatchResult.unsupported);
    expect(platform.writes, 0);
  });

  test('capability state separates unsupported types from denial', () async {
    platform.supported.remove(HealthDataType.steps);
    var capability = await platform.capabilityFor(
        {HealthDataType.bodyMass, HealthDataType.steps});
    expect(capability.unsupported, contains(HealthDataType.steps));
    expect(capability.unsupported, hasLength(1));
    expect(capability.access, HealthAccess.unavailable);
    expect(capability.granted, isFalse);

    platform.access = HealthAccess.denied;
    capability = await platform.capabilityFor({HealthDataType.bodyMass});
    expect(capability.unsupported, isEmpty);
    expect(capability.access, HealthAccess.denied);
    expect(capability.granted, isFalse);

    platform.access = HealthAccess.granted;
    capability = await platform.capabilityFor({HealthDataType.bodyMass});
    expect(capability.granted, isTrue);
  });

  test('a write requests only the nutrient types it supplies', () {
    final energyOnly = NutritionWrite(
        externalId: 'energy', startedAt: entry.startedAt, energyKcal: 10);
    final energy = requiredHealthTypes(energyOnly);
    expect(energy, contains(HealthDataType.dietaryEnergy));
    expect(energy, hasLength(1));

    final all = requiredHealthTypes(NutritionWrite(
        externalId: 'all',
        startedAt: entry.startedAt,
        energyKcal: 10,
        proteinG: 1,
        carbohydrateG: 2,
        fatG: 3));
    expect(all, hasLength(4));
    expect(all, containsAll(const <HealthDataType>[
      HealthDataType.dietaryEnergy,
      HealthDataType.dietaryProtein,
      HealthDataType.dietaryCarbohydrate,
      HealthDataType.dietaryFat,
    ]));
  });

  test('an energy-only write succeeds when macro types are unsupported',
      () async {
    final energyOnly = NutritionWrite(
        externalId: 'energy', startedAt: entry.startedAt, energyKcal: 10);
    await outbox.enqueueConfirmed(energyOnly);
    platform.supported = {HealthDataType.dietaryEnergy};
    expect(await outbox.dispatch('energy'), HealthDispatchResult.sent);
    expect(platform.checked, {HealthDataType.dietaryEnergy});
  });

  test('a revoked write reports permissionDenied and stays queued', () async {
    await outbox.enqueueConfirmed(entry);
    platform.denyOnWrite = true;
    expect(
        await outbox.dispatch('entry'), HealthDispatchResult.permissionDenied);
    expect(store.items['entry']!.state, HealthOutboxState.pending);
    expect(platform.writes, 0);
    platform.denyOnWrite = false;
    expect(await outbox.dispatch('entry'), HealthDispatchResult.sent);
    expect(platform.writes, 1);
  });

  test('a platform query failure is retried without losing the export',
      () async {
    await outbox.enqueueConfirmed(entry);
    platform.failAvailability = true;
    expect(await outbox.dispatch('entry'), HealthDispatchResult.retryLater);
    expect(store.items['entry']!.state, HealthOutboxState.pending);
    platform.failAvailability = false;
    expect(await outbox.dispatch('entry'), HealthDispatchResult.sent);
  });

  test('external deletion is terminal and late edits cannot clear it',
      () async {
    await outbox.enqueueConfirmed(entry);
    await outbox.recordExternalChange('entry', HealthExternalChange.deleted);
    await outbox.recordExternalChange('entry', HealthExternalChange.edited);
    await outbox.enqueueConfirmed(entry);
    expect(store.items['entry']!.state, HealthOutboxState.externallyDeleted);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.needsReview);
    expect(platform.writes, 0);
  });

  test('deletion reported during a dispatched write is not overwritten',
      () async {
    await outbox.enqueueConfirmed(entry);
    platform.onWrite = (write) async {
      await store.put(
          HealthOutboxItem(write, HealthOutboxState.externallyDeleted));
    };
    expect(await outbox.dispatch('entry'), HealthDispatchResult.needsReview);
    expect(store.items['entry']!.state, HealthOutboxState.externallyDeleted);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.needsReview);
    expect(platform.writes, 1);
  });

  test('restored exports never dispatch without review', () async {
    await store.put(
        HealthOutboxItem(entry, HealthOutboxState.restoreReviewRequired));
    expect(await outbox.pending(), isEmpty);
    expect(await outbox.dispatch('entry'), HealthDispatchResult.needsReview);
    expect(platform.writes, 0);
  });

  test('an external edit to a queued export requires review before writing',
      () async {
    await outbox.enqueueConfirmed(entry);
    await outbox.recordExternalChange('entry', HealthExternalChange.edited);
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

  test('a change for an untracked export is ignored', () async {
    await outbox.recordExternalChange('other', HealthExternalChange.deleted);
    expect(store.items, isEmpty);
    await expectLater(outbox.recordExternalChange(' ', HealthExternalChange.edited),
        throwsArgumentError);
  });

  test('pending exports are recovered by a new outbox instance', () async {
    final later = NutritionWrite(
        externalId: 'later',
        startedAt: DateTime.utc(2026, 1, 2),
        energyKcal: 50);
    await outbox.enqueueConfirmed(later);
    await outbox.enqueueConfirmed(entry);
    final recovered = HealthOutbox(platform, store);
    expect((await recovered.pending()).map((item) => item.write.externalId),
        ['entry', 'later']);
    final outcomes = await recovered.dispatchPending();
    expect(outcomes.keys, ['entry', 'later']);
    expect(outcomes.values, everyElement(HealthDispatchResult.sent));
    expect(platform.writtenIds, ['entry', 'later']);
    expect(await recovered.dispatchPending(), isEmpty);
  });

  test('a drain reports each denied export without writing', () async {
    final second = NutritionWrite(
        externalId: 'second',
        startedAt: DateTime.utc(2026, 1, 2),
        energyKcal: 50);
    await outbox.enqueueConfirmed(second);
    await outbox.enqueueConfirmed(entry);
    platform.access = HealthAccess.denied;
    final outcomes = await outbox.dispatchPending();
    expect(outcomes.keys, ['entry', 'second']);
    expect(
        outcomes.values, everyElement(HealthDispatchResult.permissionDenied));
    expect(platform.writes, 0);
    expect(await outbox.pending(), hasLength(2));
  });

  test('concurrent dispatches of one export write once', () async {
    await outbox.enqueueConfirmed(entry);
    final results = await Future.wait(
        [outbox.dispatch('entry'), outbox.dispatch('entry')]);
    expect(results.toSet(),
        {HealthDispatchResult.sent, HealthDispatchResult.alreadySynced});
    expect(platform.writes, 1);
  });

  test('concurrent identical enqueue binds one export', () async {
    await Future.wait(
        [outbox.enqueueConfirmed(entry), outbox.enqueueConfirmed(entry)]);
    expect(store.items.length, 1);
    expect(store.items['entry']!.state, HealthOutboxState.pending);
  });

  test('a failed state commit is retried without claiming success', () async {
    final flaky = FlakyOutbox();
    final retrying = HealthOutbox(platform, flaky);
    await retrying.enqueueConfirmed(entry);
    flaky.failNextSyncedPut = true;
    expect(await retrying.dispatch('entry'), HealthDispatchResult.retryLater);
    expect(flaky.items['entry']!.state, HealthOutboxState.pending);
    expect(await retrying.dispatch('entry'), HealthDispatchResult.sent);
    expect(flaky.items['entry']!.state, HealthOutboxState.synced);
    expect(platform.writtenIds, ['entry', 'entry']);
  });

  test('unknown export IDs are not written', () async {
    expect(await outbox.dispatch('missing'), HealthDispatchResult.notQueued);
    expect(platform.writes, 0);
  });

  test('invalid nutrient amounts cannot enter the outbox', () async {
    final nonFinite = NutritionWrite(
        externalId: 'invalid',
        startedAt: entry.startedAt,
        energyKcal: double.nan);
    await expectLater(outbox.enqueueConfirmed(nonFinite), throwsArgumentError);
    final negative = NutritionWrite(
        externalId: 'negative',
        startedAt: entry.startedAt,
        energyKcal: 100,
        fatG: -1);
    await expectLater(outbox.enqueueConfirmed(negative), throwsArgumentError);
    final blank = NutritionWrite(
        externalId: '  ', startedAt: entry.startedAt, energyKcal: 100);
    await expectLater(outbox.enqueueConfirmed(blank), throwsArgumentError);
    expect(store.items, isEmpty);
  });

  group('weight import planning', () {
    WeightSample sample(
      String id, {
      double kg = 70,
      DateTime? at,
      String source = 'scale',
      String? appRecordId,
    }) =>
        WeightSample(
            kilograms: kg,
            startedAt: at ?? DateTime.utc(2026),
            source: source,
            externalId: id,
            appRecordId: appRecordId);

    test('own writes are skipped instead of re-imported', () {
      final plan = planWeightImport(
        [
          sample('a', source: 'com.example.salu'),
          sample('b', appRecordId: 'export-1'),
          sample('export-2'),
          sample('c'),
        ],
        ownSources: {'com.example.salu'},
        ownRecordIds: {'export-1', 'export-2'},
      );
      expect(plan.ownWrites.map((s) => s.externalId), ['a', 'b', 'export-2']);
      expect(plan.importable.map((s) => s.externalId), ['c']);
      expect(plan.hasConflicts, isFalse);
    });

    test('identical duplicates are skipped and conflicts are excluded', () {
      final plan = planWeightImport([
        sample('a', kg: 70, source: 'scale'),
        sample('a', kg: 70, source: 'scale'),
        sample('b', kg: 80, source: 'phone'),
        sample('b', kg: 80, source: 'scale'),
        sample('b', kg: 81, source: 'scale'),
      ]);
      expect(plan.duplicates.single.externalId, 'a');
      expect(plan.importable.map((s) => s.externalId), ['a']);
      expect(plan.conflicts.map((s) => s.externalId), ['b', 'b', 'b']);
      expect(plan.hasConflicts, isTrue);
    });

    test('distinct external identities remain separate readings', () {
      final plan = planWeightImport([
        sample('late', kg: 71, at: DateTime.utc(2026, 1, 2), source: 'phone'),
        sample('early', kg: 70, at: DateTime.utc(2026, 1, 1), source: 'scale'),
      ]);
      expect(plan.importable.map((s) => s.externalId), ['early', 'late']);
      expect(plan.conflicts, isEmpty);
    });

    test('unusable records are reported, not imported', () {
      final plan = planWeightImport([
        sample('', kg: 70),
        sample('zero', kg: 0),
        sample('negative', kg: -1),
        sample('nan', kg: double.nan),
        sample('ok'),
      ]);
      expect(plan.invalid.map((s) => s.externalId),
          ['', 'nan', 'negative', 'zero']);
      expect(plan.importable.map((s) => s.externalId), ['ok']);
    });
  });
}
