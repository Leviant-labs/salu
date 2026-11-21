import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/data_transfer/data_write_gate.dart';
import 'package:salu/src/features/onboarding/planning_profile.dart';
import 'package:salu/src/features/plan/plan_controller.dart';
import 'package:salu/src/features/plan/week_plan.dart';
import 'package:salu_data/salu_data.dart';

final class _ControlledWeekPlanStore extends WeekPlanStore {
  _ControlledWeekPlanStore(this._loaders);

  final Map<DateTime, Completer<WeekPlan>> _loaders;

  @override
  Future<WeekPlan> load(DateTime monday) =>
      _loaders[monday]?.future ?? Future.value(WeekPlan(monday));
}

void main() {
  late AppDatabase db;
  late LocalDocumentStore docs;
  late Directory tempDir;
  late WeekPlanStore store;
  late PlanningProfileStore profiles;
  final monday = startOfPlanWeek(DateTime(2026, 11, 21));

  setUp(() async {
    db = AppDatabase.memory();
    docs = LocalDocumentStore(db);
    tempDir = await Directory.systemTemp.createTemp('salu_plan_ctrl_test_');
    store = WeekPlanStore(documents: docs, directory: () async => tempDir);
    profiles = PlanningProfileStore(
      documents: docs,
      directory: () async => tempDir,
    );
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('loads week, edits and toggles groceries, and advances revision',
      () async {
    final controller = PlanController(
      store: store,
      profileStore: profiles,
      initialWeek: monday,
    );
    addTearDown(controller.dispose);

    await controller.loadWeek(monday);
    expect(controller.plan, isNotNull);
    expect(controller.plan!.revision, 0);

    final added = await controller.editGrocery(name: 'Apples', details: '4');
    expect(added, isTrue);
    expect(controller.plan!.groceries, hasLength(1));
    expect(controller.plan!.revision, 1);

    final toggled = await controller.toggleGrocery(0, true);
    expect(toggled, isTrue);
    expect(controller.plan!.groceries.single.checked, isTrue);
    expect(controller.plan!.revision, 2);
  });

  test('stale week load result is ignored after switching weeks', () async {
    final nextMonday = monday.add(const Duration(days: 7));
    final firstLoad = Completer<WeekPlan>();
    final secondLoad = Completer<WeekPlan>();
    final controlled = _ControlledWeekPlanStore({
      monday: firstLoad,
      nextMonday: secondLoad,
    });

    final controller = PlanController(
      store: controlled,
      profileStore: profiles,
      initialWeek: monday,
    );
    addTearDown(controller.dispose);

    final f1 = controller.loadWeek(monday);
    final f2 = controller.loadWeek(nextMonday);

    secondLoad.complete(
      WeekPlan(nextMonday, groceries: const [GroceryItem('Next week item')]),
    );
    await f2;
    expect(controller.plan?.groceries.single.name, 'Next week item');

    // Completing the stale load must not overwrite next week's plan.
    firstLoad.complete(
      WeekPlan(monday, groceries: const [GroceryItem('Stale week item')]),
    );
    await f1;
    expect(controller.week, nextMonday);
    expect(controller.plan?.groceries.single.name, 'Next week item');
  });

  test('write gate blocks savePlan while exclusive operation is active',
      () async {
    final gate = DataWriteGate();
    final blocker = Completer<void>();
    final gateEntered = Completer<void>();
    final exclusive = gate.exclusive(() async {
      gateEntered.complete();
      await blocker.future;
    });
    await gateEntered.future;

    final controller = PlanController(
      store: store,
      profileStore: profiles,
      gate: gate,
      initialWeek: monday,
    );
    addTearDown(controller.dispose);
    await controller.loadWeek(monday);

    expect(
      await controller.editGrocery(name: 'Bread', details: '1 loaf'),
      isFalse,
    );

    blocker.complete();
    await exclusive;
    expect(
      await controller.editGrocery(name: 'Bread', details: '1 loaf'),
      isTrue,
    );
    expect(controller.plan!.groceries.single.name, 'Bread');
  });
}
