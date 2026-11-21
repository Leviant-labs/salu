import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/bootstrap.dart';
import 'package:salu/src/providers.dart';
import 'package:salu_data/salu_data.dart';

class _TrackingDatabase extends AppDatabase {
  _TrackingDatabase() : super.memory();

  int closeCalls = 0;

  @override
  Future<void> close() {
    closeCalls++;
    return super.close();
  }
}

void main() {
  testWidgets('failing openDatabase shows Retry screen and recovers on Retry',
      (tester) async {
    var attempts = 0;
    final opened = <_TrackingDatabase>[];

    await tester.pumpWidget(
      BootstrapApp(
        openDatabase: () async {
          attempts++;
          if (attempts == 1) {
            throw StateError('Disk temporarily unavailable');
          }
          final db = _TrackingDatabase();
          opened.add(db);
          return db;
        },
        initialize: (_) async {},
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final db = ref.watch(databaseProvider);
              return Scaffold(body: Text('Ready: ${db.schemaVersion}'));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not open local data'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(opened, isEmpty);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Ready: 4'), findsOneWidget);
    expect(attempts, 2);
    expect(opened, hasLength(1));

    // Unmounting disposes BootstrapController and closes the owned DB once.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(opened.single.closeCalls, 1);
  });

  testWidgets(
      'failing initialize closes failed DB, shows Retry, and recovers on Retry',
      (tester) async {
    var attempts = 0;
    final opened = <_TrackingDatabase>[];

    await tester.pumpWidget(
      BootstrapApp(
        openDatabase: () async {
          final db = _TrackingDatabase();
          opened.add(db);
          return db;
        },
        initialize: (_) async {
          attempts++;
          if (attempts == 1) {
            throw StateError('Interrupted reset recovery');
          }
        },
        child: const MaterialApp(
          home: Scaffold(body: Text('App Mounted')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    expect(opened, hasLength(1));
    expect(opened.first.closeCalls, 1);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('App Mounted'), findsOneWidget);
    expect(opened, hasLength(2));
    expect(opened.last.closeCalls, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(opened.last.closeCalls, 1);
  });

  test('double start does not open duplicate databases', () async {
    var openCalls = 0;
    final gate = Completer<void>();
    final opened = <_TrackingDatabase>[];

    final controller = BootstrapController(
      openDatabase: () async {
        openCalls++;
        await gate.future;
        final db = _TrackingDatabase();
        opened.add(db);
        return db;
      },
      initialize: (_) async {},
    );

    final first = controller.start();
    final second = controller.start();
    gate.complete();
    await Future.wait([first, second]);

    expect(openCalls, 1);
    expect(opened, hasLength(1));
    expect(controller.database, same(opened.single));

    controller.dispose();
    expect(opened.single.closeCalls, 1);
  });

  test('dispose while starting closes opened DB without post-dispose notify',
      () async {
    final gate = Completer<void>();
    final opened = <_TrackingDatabase>[];
    var notifications = 0;

    final controller = BootstrapController(
      openDatabase: () async {
        await gate.future;
        final db = _TrackingDatabase();
        opened.add(db);
        return db;
      },
      initialize: (_) async {},
    );
    controller.addListener(() => notifications++);

    final future = controller.start();
    expect(notifications, 1);
    controller.dispose();

    gate.complete();
    await future;

    expect(notifications, 1);
    expect(opened, hasLength(1));
    expect(opened.single.closeCalls, 1);
  });
}
