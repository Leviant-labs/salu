/// Coordinates epoch-based cancellation across asynchronous credential reads,
/// network transport calls, and result commits.
final class OperationFence {
  int _epoch = 0;
  int _nextSubscriberId = 0;
  final Map<int, void Function()> _subscribers = <int, void Function()>{};

  /// Captures the current epoch before starting an asynchronous operation.
  int capture() => _epoch;

  /// Returns `true` if [epoch] has not been invalidated.
  bool isCurrent(int epoch) => epoch == _epoch;

  /// Registers [abort] to run once on the next invalidation, returning an
  /// idempotent unregister callback.
  void Function() onInvalidate(void Function() abort) {
    final id = _nextSubscriberId++;
    _subscribers[id] = abort;
    return () {
      _subscribers.remove(id);
    };
  }

  /// Advances the epoch before invoking all registered abort subscribers.
  ///
  /// Subscriber errors are isolated so every registered abort callback runs.
  void invalidate() {
    _epoch++;
    if (_subscribers.isEmpty) return;
    final callbacks = List<void Function()>.of(_subscribers.values);
    _subscribers.clear();
    for (final abort in callbacks) {
      try {
        abort();
      } on Object {
        // Isolate subscriber failures so all registered aborts run.
      }
    }
  }
}
