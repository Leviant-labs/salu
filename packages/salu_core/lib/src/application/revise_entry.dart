import '../domain/nutrition_contract.dart';
import '../domain/time.dart';

final class ReviseEntryCommand {
  ReviseEntryCommand(
      {required this.requestId,
      required this.entryId,
      required this.expectedRevision,
      required this.recordedAt,
      this.multiplier,
      this.diaryDate,
      this.delete = false}) {
    if (requestId.isEmpty ||
        entryId.isEmpty ||
        expectedRevision < 1 ||
        (multiplier != null && !multiplier!.positive) ||
        (delete && multiplier != null)) {
      throw ArgumentError('Invalid entry correction');
    }
  }
  final String requestId, entryId;
  final int expectedRevision;
  final DateTime recordedAt;
  final Exact? multiplier;
  final DiaryDate? diaryDate;
  final bool delete;
}
