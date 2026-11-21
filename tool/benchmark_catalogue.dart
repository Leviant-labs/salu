import 'dart:io';

import 'package:drift/native.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

const _fixtureCount = 25000;
const _queries = [
  'chicken',
  'lentils',
  'quinoa',
  'almond',
  'olive oil',
  'chickpeas',
  'salmon',
  'oatmeal',
  'spinach',
  'yogurt',
];

const _bases = [
  'Chicken breast',
  'Red lentils',
  'Organic quinoa',
  'Roasted almond',
  'Extra virgin olive oil',
  'Cooked chickpeas',
  'Atlantic salmon',
  'Rolled oatmeal',
  'Baby spinach',
  'Greek yogurt',
];

const _modifiers = [
  'raw',
  'grilled',
  'steamed',
  'baked',
  'roasted',
  'unsalted',
  'organic',
  'sliced',
  'diced',
  'plain',
];

Food _syntheticFood(int index) {
  final base = _bases[index % _bases.length];
  final mod = _modifiers[(index ~/ _bases.length) % _modifiers.length];
  final id = 'fixture:${index.toString().padLeft(6, '0')}';
  return Food(
    id: id,
    name: '$base ($mod #$index)',
    per100g: const NutrientProfile.empty(),
    source: FoodSource(
      dataset: 'fixture',
      datasetId: index.toString().padLeft(6, '0'),
      datasetVersion: 'synthetic-benchmark',
    ),
  );
}

double _percentileMs(List<int> micros, double p) {
  final sorted = List<int>.from(micros)..sort();
  final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[idx] / 1000.0;
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('salu_bench_');
  final file = File('${dir.path}${Platform.pathSeparator}catalogue.sqlite');

  try {
    final foods = List<Food>.generate(_fixtureCount, _syntheticFood);

    final coldWatch = Stopwatch()..start();
    final db1 = AppDatabase(NativeDatabase(file));
    await DriftFoodRepository(db1).replaceCatalogueBatch(foods);
    final index1 = SearchIndex(db1);
    final ready1 = await index1.ensureReady();
    coldWatch.stop();

    if (!ready1) {
      stderr.writeln('ERROR: FTS5 index did not initialize.');
      exitCode = 1;
      return;
    }

    // Mutate one row so its rowid moves past _fixtureCount; a rebuild on reopen
    // would renumber it back to 1.
    await DriftFoodRepository(db1).replaceCatalogueBatch([_syntheticFood(0)]);
    final beforeRow = await db1
        .customSelect(
          "SELECT rowid FROM food_names WHERE food_id = 'fixture:000000'",
        )
        .getSingle();
    final beforeRowId = beforeRow.read<int>('rowid');
    await db1.close();

    final warmWatch = Stopwatch()..start();
    final db2 = AppDatabase(NativeDatabase(file));
    final index2 = SearchIndex(db2);
    final ready2 = await index2.ensureReady();
    warmWatch.stop();

    final afterRow = await db2
        .customSelect(
          "SELECT rowid FROM food_names WHERE food_id = 'fixture:000000'",
        )
        .getSingle();
    final afterRowId = afterRow.read<int>('rowid');
    final rowIdPreserved = ready2 && beforeRowId == afterRowId;

    final ftsSamples = <int>[];
    for (final q in _queries) {
      final sw = Stopwatch()..start();
      await index2.searchIds(q);
      sw.stop();
      ftsSamples.add(sw.elapsedMicroseconds);
    }

    final fallback = SearchIndex(db2, forceFallback: true);
    final fallbackSamples = <int>[];
    for (final q in _queries) {
      final sw = Stopwatch()..start();
      await fallback.searchIds(q);
      sw.stop();
      fallbackSamples.add(sw.elapsedMicroseconds);
    }

    await db2.close();
    final dbBytes = await file.length();

    stdout.writeln('Salu Catalogue Benchmark (synthetic fixtures)');
    stdout.writeln('Dataset count: $_fixtureCount (dataset=fixture)');
    stdout.writeln('Dart SDK: ${Platform.version}');
    stdout.writeln(
      'OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    stdout.writeln(
      'Cold open + insert + index build: '
      '${(coldWatch.elapsedMicroseconds / 1000.0).toStringAsFixed(2)} ms',
    );
    stdout.writeln(
      'Warm reopen + ensureReady: '
      '${(warmWatch.elapsedMicroseconds / 1000.0).toStringAsFixed(2)} ms',
    );
    stdout.writeln(
      'Rowid preserved on reopen: $rowIdPreserved '
      '(before=$beforeRowId, after=$afterRowId)',
    );
    stdout.writeln(
      'FTS5 search (${_queries.length} queries): '
      'p50=${_percentileMs(ftsSamples, 0.50).toStringAsFixed(2)} ms, '
      'p95=${_percentileMs(ftsSamples, 0.95).toStringAsFixed(2)} ms',
    );
    stdout.writeln(
      'Fallback keyset search (${_queries.length} queries): '
      'p50=${_percentileMs(fallbackSamples, 0.50).toStringAsFixed(2)} ms, '
      'p95=${_percentileMs(fallbackSamples, 0.95).toStringAsFixed(2)} ms',
    );
    stdout.writeln(
      'SQLite file size: $dbBytes bytes '
      '(${(dbBytes / (1024 * 1024)).toStringAsFixed(2)} MiB)',
    );
  } finally {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
