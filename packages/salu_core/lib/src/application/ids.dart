/// Identifier generation for new records.
library;

import 'dart:math';

import 'ports.dart';

/// Random 128-bit identifiers in hex, from a secure source.
final class RandomIdGenerator implements IdGenerator {
  /// Creates a generator. Inject [random] only for deterministic tests.
  RandomIdGenerator({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  @override
  String next() {
    final buffer = StringBuffer();
    for (var i = 0; i < 4; i++) {
      buffer.write(
          _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'));
    }
    return buffer.toString();
  }
}

/// Monotonic identifiers for tests and fixtures.
final class SequentialIdGenerator implements IdGenerator {
  /// Creates a generator producing `prefix-1`, `prefix-2`, ...
  SequentialIdGenerator({this.prefix = 'id'});

  /// Prefix applied to every identifier.
  final String prefix;

  int _counter = 0;

  @override
  String next() => '$prefix-${++_counter}';
}
