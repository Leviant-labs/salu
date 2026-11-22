import 'dart:io';

import 'package:salu_core/salu_core.dart'
    show PlanMealPosition, PlanMealSlot, WeekPlan;
import 'package:salu_data/salu_data.dart';

import '../../data_transfer/data_write_gate.dart';
import '../onboarding/local_json_file.dart';

export 'package:salu_core/salu_core.dart'
    show
        GroceryItem,
        PlanMealPosition,
        PlanMealSlot,
        PlannedMeal,
        WeekPlan,
        startOfPlanWeek,
        toIntakeMealSlot;

typedef MealSlot = PlanMealSlot;
typedef MealPosition = PlanMealPosition;

extension PlanMealSlotLabel on PlanMealSlot {
  String get label => switch (this) {
        PlanMealSlot.breakfast => 'Breakfast',
        PlanMealSlot.lunch => 'Lunch',
        PlanMealSlot.dinner => 'Dinner',
      };
}

class WeekPlanStore {
  WeekPlanStore({
    Future<Directory> Function()? directory,
    LocalDocumentStore? documents,
    DataWriteGate? gate,
  })  : _directory = directory,
        _documents = documents,
        _repository = documents != null
            ? WeekPlanRepository(documents, runWrite: gate?.runWrite)
            : null,
        _gate = gate;

  static final local = WeekPlanStore();

  final Future<Directory> Function()? _directory;
  final LocalDocumentStore? _documents;
  final WeekPlanRepository? _repository;
  final DataWriteGate? _gate;
  final _files = <DateTime, LocalJsonFile>{};

  Future<T> _runWrite<T>(Future<T> Function() work) =>
      _gate != null ? _gate.runWrite(work) : work();

  LocalJsonFile _file(DateTime week) => _files.putIfAbsent(week, () {
        final filename =
            'week_plan_v1_${week.year}-${week.month}-${week.day}.json';
        final directory = _directory;
        return directory == null
            ? LocalJsonFile(filename)
            : LocalJsonFile(filename, directory: directory);
      });

  Future<WeekPlan> load(DateTime monday) async {
    final repo = _repository;
    final docs = _documents;
    if (repo != null && docs != null) {
      final saved = await repo.loadIfPresent(monday);
      if (saved != null) return saved;
    }
    final data = await _file(monday).read();
    if (data == null) return WeekPlan(monday);
    final legacy = WeekPlan.fromJson(monday, data);
    if (docs == null) return legacy;
    final key = WeekPlanRepository.keyFor(monday);
    await _runWrite(() => docs.put(key, 0, {...data, ...legacy.toJson()}));
    final migrated = (await docs.read(key))!;
    return WeekPlan.fromJson(
      monday,
      migrated.data,
      revision: migrated.revision,
    );
  }

  Future<void> save(WeekPlan plan) async {
    final repo = _repository;
    if (repo != null) {
      await repo.save(plan);
      return;
    }
    await _runWrite(() => _file(plan.monday).update((saved) {
          if (saved != null) WeekPlan.fromJson(plan.monday, saved);
          return plan.toJson();
        }));
  }
}
