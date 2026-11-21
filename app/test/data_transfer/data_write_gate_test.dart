import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/data_transfer/data_write_gate.dart';

void main() {
  test('admitted writes drain before exclusive runs and new writes reject',
      () async {
    final gate = DataWriteGate();
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final exclusiveRan = Completer<void>();

    final admittedWrite = gate.runWrite(() async {
      writeStarted.complete();
      await releaseWrite.future;
      return 'done';
    });

    await writeStarted.future;
    expect(gate.blocked, isFalse);

    final exclusiveFuture = gate.exclusive(() async {
      exclusiveRan.complete();
      return 42;
    });

    // Gate is immediately blocked while waiting for admitted write to drain
    expect(gate.blocked, isTrue);
    expect(exclusiveRan.isCompleted, isFalse);

    // New writes are rejected immediately
    await expectLater(
      gate.runWrite(() async => 'late'),
      throwsA(isA<DataWriteBlockedException>()),
    );

    // Releasing the admitted write allows exclusive to run
    releaseWrite.complete();
    expect(await admittedWrite, 'done');
    expect(await exclusiveFuture, 42);
    expect(exclusiveRan.isCompleted, isTrue);
    expect(gate.blocked, isFalse);

    // Writes succeed again after exclusive finishes
    expect(await gate.runWrite(() async => 'after'), 'after');
  });

  test('exclusive failure releases the gate for subsequent writes', () async {
    final gate = DataWriteGate();

    await expectLater(
      gate.exclusive<void>(() async {
        expect(gate.blocked, isTrue);
        throw StateError('boom');
      }),
      throwsStateError,
    );

    expect(gate.blocked, isFalse);
    expect(await gate.runWrite(() async => 'recovered'), 'recovered');
  });

  test('nested exclusive is rejected without deadlock', () async {
    final gate = DataWriteGate();

    await gate.exclusive(() async {
      await expectLater(
        gate.exclusive(() async => 'nested'),
        throwsA(isA<DataWriteBlockedException>()),
      );
    });

    expect(gate.blocked, isFalse);
  });
}
