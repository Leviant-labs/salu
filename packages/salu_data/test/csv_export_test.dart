import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:test/test.dart';

void main() {
  test('CSV protects formula-like names while preserving the full archive',
      () async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final stamp =
        EventStamp(instant: DateTime.utc(2026, 1, 1), offsetMinutes: 0);
    await DriftEntryRepository(db).append(LoggedEntry(
      id: 'entry',
      requestId: 'request',
      diaryDate: DiaryDate(2026, 1, 1),
      stamp: stamp,
      channel: EntryChannel.manual,
      recordedAt: stamp.instantUtc,
      items: [
        for (final name in [
          '=SUM(1,2)',
          '  +1',
          '-1',
          '@name',
          '\tleading',
          'Apple "red"'
        ])
          LoggedItem(
              name: name, grams: 100, nutrients: const NutrientProfile.empty()),
      ],
    ));
    final service = ArchiveService(db);
    final csv = await service.exportCsv();
    expect(csv, contains('"\'=SUM(1,2)"'));
    expect(csv, contains('"\'  +1"'));
    expect(csv, contains('"\'-1"'));
    expect(csv, contains('"\'@name"'));
    expect(csv, contains('"\'\tleading"'));
    expect(csv, contains('"Apple ""red"""'));
    expect(await service.exportJson(), contains('=SUM(1,2)'));
  });
}
