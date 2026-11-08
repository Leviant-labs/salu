/// Logged intake: an immutable snapshot of what was recorded, not a live view
/// of today's catalogue values.
library;

import 'nutrients.dart';
import 'time.dart';

/// Which input produced an entry. Provenance is user-visible and exportable.
enum EntryChannel {
  /// Typed by the user into a form.
  manual,

  /// Picked from catalogue search.
  search,

  /// Created from a scanned barcode match.
  barcode,

  /// Created from a label OCR draft after review.
  labelOcr,

  /// Created from a meal-photo suggestion after review.
  mealPhoto,

  /// Created from a natural-language request after review.
  naturalLanguage,

  /// Logged from a generated plan after separate confirmation.
  plan,

  /// Restored from an export or platform health record.
  imported,
}

/// One line of a logged entry, frozen as consumed.
final class LoggedItem {
  /// Creates a logged item. [nutrients] are for the eaten amount, not per 100 g.
  const LoggedItem({
    required this.name,
    required this.grams,
    required this.nutrients,
    this.foodId,
  }) : assert(grams >= 0, 'grams must be >= 0');

  /// Display name captured at log time.
  final String name;

  /// Eaten mass in grams.
  final double grams;

  /// Nutrients for [grams], as recorded.
  final NutrientProfile nutrients;

  /// Catalogue food this came from, when it came from one.
  final String? foodId;

  @override
  String toString() => 'LoggedItem($name, ${grams}g)';
}

/// A logged meal or snack.
///
/// [requestId] is the idempotency key: retries of the same user action return
/// the existing entry instead of appending a duplicate.
final class LoggedEntry {
  /// Creates a logged entry. [items] are frozen for the lifetime of the entry.
  LoggedEntry({
    required this.id,
    required this.requestId,
    required this.diaryDate,
    required this.stamp,
    required this.channel,
    required List<LoggedItem> items,
    required this.recordedAt,
    this.revision = 1,
    this.note,
  }) : items = List<LoggedItem>.unmodifiable(items);

  /// Stable local identifier.
  final String id;

  /// Idempotency key from the originating request.
  final String requestId;

  /// The diary date this entry counts towards.
  final DiaryDate diaryDate;

  /// When it was eaten, with the offset in effect.
  final EventStamp stamp;

  /// How it was captured.
  final EntryChannel channel;

  /// Frozen item snapshots.
  final List<LoggedItem>
      items; // ignore: prefer_const_constructors_in_immutables

  /// When the record was written (audit trail, distinct from [stamp]).
  final DateTime recordedAt;

  /// Revision number, incremented by explicit corrections.
  final int revision;

  /// Optional user note.
  final String? note;

  /// Total eaten mass in grams.
  double get grams => items.fold(0, (sum, item) => sum + item.grams);

  /// Per-nutrient totals with their completeness flags.
  Map<NutrientKey, NutrientSum> get nutrientSums => NutrientProfile.combine(
        items.map((item) => item.nutrients),
      );

  /// Sum for [key]; [NutrientSum.noData] when no item carries that nutrient, so
  /// a missing value is never displayed as a verified zero.
  NutrientSum nutrientSum(NutrientKey key) =>
      nutrientSums[key] ?? NutrientSum.noData;

  @override
  String toString() =>
      'LoggedEntry($id, $diaryDate, ${items.length} items, ${grams}g)';
}
