import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/today/diary_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu_core/salu_core.dart';

/// Diary fake: the screen must work against the port, not a database.
final class _FakeEntryRepository implements EntryRepository {
  _FakeEntryRepository(this.entries);

  final List<LoggedEntry> entries;

  @override
  Future<LoggedEntry?> findByRequestId(String requestId) async {
    for (final entry in entries) {
      if (entry.requestId == requestId) return entry;
    }
    return null;
  }

  @override
  Future<void> append(LoggedEntry entry) async => entries.add(entry);

  @override
  Future<List<LoggedEntry>> entriesFor(DiaryDate date) async =>
      entries.where((entry) => entry.diaryDate == date).toList(growable: false);
}

DiaryDate get _today => DiaryDate.assign(
      EventStamp(
        instant: DateTime.now(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      ),
    );

LoggedEntry _chickenEntry() => LoggedEntry(
      id: 'entry-1',
      requestId: 'req-1',
      diaryDate: _today,
      stamp: EventStamp(
        instant: DateTime.now().toUtc(),
        offsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
      ),
      channel: EntryChannel.search,
      items: [
        LoggedItem(
          name: 'Chicken breast, cooked',
          grams: 150,
          nutrients: NutrientProfile({
            NutrientKey.energyKcal: NutrientMeasured(247.5),
            NutrientKey.proteinG: NutrientMeasured(46.5),
            NutrientKey.sugarsG: NutrientMeasured(7),
          }),
          foodId: 'food-chicken',
        ),
      ],
      recordedAt: DateTime.now().toUtc(),
    );

Future<void> _pumpToday(WidgetTester tester, List<LoggedEntry> entries) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        todayDiaryDateProvider.overrideWithValue(_today),
        entryRepositoryProvider.overrideWithValue(
          _FakeEntryRepository(entries),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: DiaryScreen())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('empty diary explains what to do next', (tester) async {
    await _pumpToday(tester, const []);

    expect(find.text('Nothing logged yet'), findsOneWidget);
    expect(find.text('-- kcal'), findsOneWidget);
  });

  testWidgets('a logged entry renders its items and energy', (tester) async {
    await _pumpToday(tester, [_chickenEntry()]);

    expect(find.text('Chicken breast, cooked'), findsOneWidget);
    expect(find.textContaining('247.5 kcal'), findsOneWidget);
    expect(find.textContaining('150 g'), findsOneWidget);
    expect(find.text('Nothing logged yet'), findsNothing);
  });

  testWidgets('missing nutrient coverage is shown as unknown, not zero', (
    tester,
  ) async {
    await _pumpToday(tester, [_chickenEntry()]);

    // Carbs, fat and fiber are absent from the only item, so the chips must not
    // claim 0 g; protein is known and keeps its number.
    expect(find.text('-- g'), findsNWidgets(3));
    expect(find.text('46.5 g'), findsOneWidget);
  });
  testWidgets('additional nutrients show recorded values and unknowns',
      (tester) async {
    await _pumpToday(tester, [_chickenEntry()]);
    await tester.tap(find.text('More nutrients'));
    await tester.pumpAndSettle();
    expect(find.text('Total sugars'), findsOneWidget);
    expect(find.text('7 g'), findsOneWidget);
    expect(find.text('-- µg'), findsWidgets);
  });
}
