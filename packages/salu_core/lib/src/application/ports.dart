/// Ports the application layer needs. Implementations live outside this package
/// (SQLite via drift, platform health, provider transport), so the domain stays
/// testable with in-memory fakes and cannot import Flutter or a network client.
library;

import '../domain/entry.dart';
import '../domain/food.dart';
import '../domain/time.dart';

/// A clock the application reads instead of `DateTime.now()`.
abstract interface class Clock {
  /// Current instant.
  DateTime nowUtc();
}

/// The real clock.
final class SystemClock implements Clock {
  /// Creates a system clock.
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// Generates opaque identifiers for new records.
abstract interface class IdGenerator {
  /// A new identifier, unique within the local database.
  String next();
}

/// Reads catalogue foods. Replaceable catalogue data, not user data.
abstract interface class FoodRepository {
  /// Looks up a food by local id.
  Future<Food?> findById(String id);

  /// Searches by name, best match first.
  Future<List<Food>> search(String query, {int limit = 20});
}

/// Reads and writes the user's intake history.
abstract interface class EntryRepository {
  /// The entry previously written for [requestId], if any.
  Future<LoggedEntry?> findByRequestId(String requestId);

  /// Appends [entry] and its items atomically.
  Future<void> append(LoggedEntry entry);

  /// All entries assigned to [date], oldest first.
  Future<List<LoggedEntry>> entriesFor(DiaryDate date);
}

/// Durable idempotency for recipe logs with explicitly assigned time or date.
/// Implementations atomically commit the receipt with the entry.
abstract interface class RecipeLogReceiptRepository {
  Future<LoggedEntry?> replayRecipeLog(String requestId, String? fingerprint);
  Future<LoggedEntry> appendRecipeLog(LoggedEntry entry, String fingerprint);
}
