import 'dart:async';

/// Thrown when an ordinary write or nested exclusive operation is attempted
/// while an exclusive data-lifecycle operation (restore or erase) holds or is
/// waiting for the [DataWriteGate].
class DataWriteBlockedException extends StateError {
  DataWriteBlockedException(super.message);
}

/// App-wide write gate that drains admitted writes before running an exclusive
/// data-lifecycle operation (restore or erase), and rejects new writes or
/// nested exclusive acquisitions until the exclusive section finishes.
final class DataWriteGate {
  bool _exclusiveRequested = false;
  int _activeWrites = 0;
  Completer<void>? _drained;

  /// Whether an exclusive operation is currently requested or running.
  bool get blocked => _exclusiveRequested;

  /// Runs an ordinary database/document write [work] if the gate is open.
  ///
  /// Throws [DataWriteBlockedException] immediately if an exclusive operation
  /// has been requested or is active.
  Future<T> runWrite<T>(Future<T> Function() work) async {
    if (_exclusiveRequested) {
      throw DataWriteBlockedException(
        'Cannot write while an exclusive data operation is active.',
      );
    }
    _activeWrites++;
    try {
      return await work();
    } finally {
      _activeWrites--;
      if (_activeWrites == 0) {
        final drained = _drained;
        if (drained != null && !drained.isCompleted) {
          drained.complete();
        }
      }
    }
  }

  /// Acquires exclusive access: immediately blocks new [runWrite] calls,
  /// waits for all already-admitted [runWrite] calls to complete, then runs
  /// [work].
  ///
  /// Rejects concurrent or nested [exclusive] calls with
  /// [DataWriteBlockedException] so callers can never deadlock. Always
  /// releases the gate in `finally`, even if [work] throws.
  Future<T> exclusive<T>(Future<T> Function() work) async {
    if (_exclusiveRequested) {
      throw DataWriteBlockedException(
        'An exclusive data operation is already active or pending.',
      );
    }
    _exclusiveRequested = true;
    try {
      if (_activeWrites > 0) {
        final drained = Completer<void>();
        _drained = drained;
        await drained.future;
      }
      return await work();
    } finally {
      _drained = null;
      _exclusiveRequested = false;
    }
  }
}
