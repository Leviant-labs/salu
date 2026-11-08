/// The typed command for logging one food, and its handler.
///
/// This is the template every write in the app follows: a validated command
/// object, a deterministic handler, an idempotency key, and a domain result that
/// separates "applied", "already applied", and "rejected".
library;

import '../domain/entry.dart';
import '../domain/quantity.dart';
import '../domain/time.dart';
import 'ports.dart';

/// A request to log [grams] of a catalogue food.
final class LogFoodCommand {
  /// Creates the command.
  ///
  /// [requestId] must be stable across retries of the same user action; it is the
  /// idempotency key. [offsetMinutes] is the UTC offset in effect where the user
  /// ate, required because a UTC timestamp alone cannot place a meal on the
  /// correct diary date.
  LogFoodCommand({
    required this.requestId,
    required this.foodId,
    required this.quantity,
    required this.offsetMinutes,
    this.channel = EntryChannel.search,
    this.dayStartHour = 0,
    this.eatenAt,
    this.note,
  }) {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(requestId, 'requestId', 'must not be empty');
    }
    if (foodId.trim().isEmpty) {
      throw ArgumentError.value(foodId, 'foodId', 'must not be empty');
    }
  }

  /// Idempotency key for this log action.
  final String requestId;

  /// Local food identifier to log.
  final String foodId;

  /// Amount as the user expressed it; resolved to grams by the handler.
  final Quantity quantity;

  /// UTC offset in minutes where the meal was eaten.
  final int offsetMinutes;

  /// How the entry was captured.
  final EntryChannel channel;

  /// Hour at which the user's diary day rolls over, 0..23.
  final int dayStartHour;

  /// When the meal was eaten; defaults to "now" from the injected clock.
  final DateTime? eatenAt;

  /// Optional user note.
  final String? note;
}

/// Why a log request was rejected.
enum LogFoodRejection {
  /// No such food in the catalogue.
  unknownFood,

  /// The food declares no conversion for the requested unit.
  unresolvableQuantity,
}

/// Outcome of [LogFoodHandler].
sealed class LogFoodResult {
  const LogFoodResult();
}

/// The entry is in the diary.
final class LoggedFood extends LogFoodResult {
  /// Creates an applied result. [created] is false when the request had already
  /// been applied and this is the existing entry.
  const LoggedFood(this.entry, {required this.created});

  /// The entry that represents the request.
  final LoggedEntry entry;

  /// Whether this call wrote the entry.
  final bool created;

  @override
  String toString() => 'LoggedFood(${entry.id}, created: $created)';
}

/// The request was refused; nothing was written.
final class LogFoodRejected extends LogFoodResult {
  /// Creates a rejection with a machine reason and a user-facing message.
  const LogFoodRejected(this.reason, this.message);

  /// Machine-readable cause.
  final LogFoodRejection reason;

  /// Message suitable for display, naming what the user can do instead.
  final String message;

  @override
  String toString() => 'LogFoodRejected(${reason.name}: $message)';
}

/// Applies [LogFoodCommand] against the catalogue and the diary.
final class LogFoodHandler {
  /// Creates the handler from its ports.
  const LogFoodHandler({
    required this.foods,
    required this.entries,
    required this.clock,
    required this.ids,
  });

  /// Catalogue read access.
  final FoodRepository foods;

  /// Diary access.
  final EntryRepository entries;

  /// Injected clock, so tests control "now".
  final Clock clock;

  /// Injected identifier source.
  final IdGenerator ids;

  /// Executes [command], returning an idempotent result.
  Future<LogFoodResult> handle(LogFoodCommand command) async {
    final existing = await entries.findByRequestId(command.requestId);
    if (existing != null) {
      return LoggedFood(existing, created: false);
    }

    final food = await foods.findById(command.foodId);
    if (food == null) {
      return const LogFoodRejected(
        LogFoodRejection.unknownFood,
        'That food is no longer in the catalogue. Search for it again or add it '
        'manually.',
      );
    }

    final resolution = resolveQuantity(command.quantity, food.portions);
    if (resolution is UnresolvableQuantity) {
      return LogFoodRejected(
        LogFoodRejection.unresolvableQuantity,
        resolution.reason,
      );
    }
    final grams = (resolution as ResolvedMass).grams;

    final stamp = EventStamp(
      instant: command.eatenAt ?? clock.nowUtc(),
      offsetMinutes: command.offsetMinutes,
    );

    final entry = LoggedEntry(
      id: ids.next(),
      requestId: command.requestId,
      diaryDate: DiaryDate.assign(stamp, dayStartHour: command.dayStartHour),
      stamp: stamp,
      channel: command.channel,
      items: [
        LoggedItem(
          name: food.name,
          grams: grams,
          nutrients: food.nutrientsFor(grams),
          foodId: food.id,
        ),
      ],
      recordedAt: clock.nowUtc(),
      note: command.note,
    );

    await entries.append(entry);
    return LoggedFood(entry, created: true);
  }
}
