import '../domain/food.dart';
import '../domain/nutrition_contract.dart';
import '../domain/time.dart';

/// An explicit correction to one logged entry.
///
/// The command is the idempotency boundary: [requestId] must be stable across
/// retries of the same user action. An applied correction records the previous
/// entry and item snapshots in revision history before scaling the current
/// revision, so history is never rewritten without a recoverable predecessor.
final class ReviseEntryCommand {
  ReviseEntryCommand(
      {required this.requestId,
      required this.entryId,
      required this.expectedRevision,
      required this.recordedAt,
      this.multiplier,
      this.itemIndex,
      this.diaryDate,
      this.stamp,
      this.delete = false}) {
    if (requestId.isEmpty ||
        entryId.isEmpty ||
        expectedRevision < 1 ||
        (multiplier != null && !multiplier!.positive) ||
        (delete && multiplier != null) ||
        (delete && itemIndex != null) ||
        (itemIndex != null && (itemIndex! < 0 || multiplier == null))) {
      throw ArgumentError('Invalid entry correction');
    }
  }

  /// Idempotency key for this correction action.
  final String requestId;

  /// Entry being corrected.
  final String entryId;

  /// Revision the caller saw; a mismatch is rejected instead of overwritten.
  final int expectedRevision;

  /// When the correction was recorded, for the audit trail.
  final DateTime recordedAt;

  /// Exact factor applied to the frozen quantity and nutrients. When
  /// [itemIndex] is set, only that item is scaled.
  final Exact? multiplier;

  /// Position in the entry's frozen item list to scale, or null to scale every
  /// item together. Per-item selection exists so unrelated items in a multi-item
  /// entry keep their recorded amounts and nutrients.
  final int? itemIndex;

  /// New diary date, when the correction moves the entry between days.
  final DiaryDate? diaryDate;

  /// Corrected eaten instant and offset, when the time itself changes.
  final EventStamp? stamp;

  /// Whether this correction removes the entry. Revision history is retained.
  final bool delete;
}

/// An explicit replacement of one frozen item with another catalogue food.
///
/// The command is the idempotency boundary: [requestId] must be stable across
/// retries of the same user action. The replacement is carried exactly as the
/// user reviewed it; the repository freezes [replacement]'s source and
/// nutrients for [amount] at write time. Other items and the previous revision
/// are never rewritten.
///
/// A finite cooked-batch portion cannot be substituted item by item: one stock
/// allocation covers the whole portion, so replacing one ingredient would leave
/// the batch and its stock inconsistent. That case is refused, not approximated.
final class SubstituteEntryItemCommand {
  /// Creates the command. Structural validity is checked here; whether
  /// [amount] has a recorded conversion for [replacement] is validated when the
  /// correction is applied.
  SubstituteEntryItemCommand({
    required this.requestId,
    required this.entryId,
    required this.expectedRevision,
    required this.recordedAt,
    required this.itemIndex,
    required this.replacement,
    required this.amount,
  }) {
    if (requestId.isEmpty ||
        entryId.isEmpty ||
        expectedRevision < 1 ||
        itemIndex < 0 ||
        !amount.value.positive) {
      throw ArgumentError('Invalid item substitution');
    }
  }

  /// Idempotency key for this substitution action.
  final String requestId;

  /// Entry being corrected.
  final String entryId;

  /// Revision the user reviewed; a mismatch is rejected instead of overwritten.
  final int expectedRevision;

  /// When the correction was recorded, for the audit trail.
  final DateTime recordedAt;

  /// Position in the entry's frozen item list to replace.
  final int itemIndex;

  /// Food explicitly chosen by the user as the replacement.
  final Food replacement;

  /// Explicit eaten amount of [replacement] in a unit it declares.
  final FoodAmount amount;
}
