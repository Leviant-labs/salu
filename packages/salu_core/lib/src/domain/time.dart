/// Diary time semantics: an event has an instant, the zone offset it was
/// recorded in, and a diary date that follows local wall time - not UTC and not
/// a stored calendar string that silently moves when the user travels.
library;

/// A record's instant plus the UTC offset in effect where it was recorded.
///
/// The offset is stored because a timestamp alone cannot say which local day the
/// user considered it to be.
final class EventStamp {
  /// Creates a stamp from any [instant]; it is normalised to UTC.
  EventStamp({required DateTime instant, required this.offsetMinutes})
      : instantUtc = instant.toUtc() {
    if (offsetMinutes.abs() > 840) {
      throw ArgumentError('UTC offset must be within ±14 hours');
    }
  }

  /// The instant, in UTC.
  final DateTime instantUtc;

  /// Offset east of UTC in minutes, e.g. `60` for WET+1 (Lisbon summer time).
  final int offsetMinutes;

  /// Wall-clock time at the recording location, still flagged `isUtc` because it
  /// is a synthetic civil time with no attachable zone database.
  DateTime get localWallTime =>
      instantUtc.add(Duration(minutes: offsetMinutes));

  @override
  bool operator ==(Object other) =>
      other is EventStamp &&
      other.instantUtc == instantUtc &&
      other.offsetMinutes == offsetMinutes;

  @override
  int get hashCode => Object.hash(instantUtc, offsetMinutes);

  @override
  String toString() => 'EventStamp(${instantUtc.toIso8601String()}, '
      'offset ${offsetMinutes}min)';
}

/// A day in the user's diary, independent of the instant it was viewed from.
///
/// Stored as its own value (ISO `yyyy-MM-dd`) so that a timezone change or a
/// backdated correction cannot reinterpret history.
final class DiaryDate implements Comparable<DiaryDate> {
  /// Creates a date from its calendar components.
  DiaryDate(this.year, this.month, this.day) {
    if (month < 1 || month > 12) {
      throw ArgumentError.value(month, 'month', 'must be 1..12');
    }
    final maxDay = DateTime.utc(year, month + 1, 0).day;
    if (day < 1 || day > maxDay) {
      throw ArgumentError.value(day, 'day', 'must be 1..$maxDay');
    }
  }

  /// Parses the ISO `yyyy-MM-dd` form produced by [toIso].
  factory DiaryDate.parse(String iso) {
    final parts = iso.split('-');
    if (parts.length != 3) {
      throw FormatException('Expected yyyy-MM-dd diary date', iso);
    }
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) {
      throw FormatException('Expected yyyy-MM-dd diary date', iso);
    }
    return DiaryDate(year, month, day);
  }

  /// Assigns the diary date a record belongs to.
  ///
  /// [dayStartHour] supports users who treat the small hours as the previous
  /// day; a record at 02:00 with `dayStartHour: 4` belongs to yesterday's diary.
  static DiaryDate assign(EventStamp stamp, {int dayStartHour = 0}) {
    if (dayStartHour < 0 || dayStartHour > 23) {
      throw ArgumentError.value(dayStartHour, 'dayStartHour', 'must be 0..23');
    }
    final local = stamp.localWallTime;
    final civil = DateTime.utc(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
    final effective = local.hour < dayStartHour
        ? civil.subtract(const Duration(days: 1))
        : civil;
    return DiaryDate(effective.year, effective.month, effective.day);
  }

  /// The diary date of a local calendar value.
  factory DiaryDate.ofLocal(DateTime local) =>
      DiaryDate(local.year, local.month, local.day);

  /// Calendar year.
  final int year;

  /// Calendar month, 1..12.
  final int month;

  /// Calendar day of month.
  final int day;

  /// ISO `yyyy-MM-dd`, the database and export representation.
  String toIso() => '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  /// Midnight at the start of this diary date, in local civil time.
  DateTime get localMidnight => DateTime(year, month, day);

  /// This date shifted by [days]; negative values go back in time.
  DiaryDate addDays(int days) {
    final shifted = DateTime.utc(year, month, day).add(Duration(days: days));
    return DiaryDate(shifted.year, shifted.month, shifted.day);
  }

  @override
  int compareTo(DiaryDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) =>
      other is DiaryDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => toIso();
}
