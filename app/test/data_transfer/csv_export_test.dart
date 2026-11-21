import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/data_transfer/csv_export.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';

void main() {
  test('CSV quotes delimiters and neutralizes formula-like food names', () {
    expect(csvCell('=1+1'), '"\'=1+1"');
    expect(csvCell('Soup, "large"'), '"Soup, ""large"""');
    expect(csvCell('line\nbreak'), '"line\nbreak"');
  });

  test('csvCell neutralizes +, -, @ and leading whitespace/control variants',
      () {
    expect(csvCell('+SUM(A1:A2)'), '"\'+SUM(A1:A2)"');
    expect(csvCell('-2+3'), '"\'-2+3"');
    expect(csvCell('@cmd'), '"\'@cmd"');
    expect(csvCell('  =1+1'), '"\'  =1+1"');
    expect(csvCell('\t+1'), '"\'\t+1"');
    expect(csvCell('\r\n-1'), '"\'\r\n-1"');
    expect(csvCell('\x01@evil'), '"\'\x01@evil"');
    expect(csvCell('Oats'), '"Oats"');
    expect(csvCell(''), '""');
  });

  test(
      'exportDiaryCsv emits photo meals and legacy entries with numeric columns and explicit unknown state',
      () {
    final mealItem = PhotoMealItem(
      id: 'item-1',
      name: '=HYPERLINK("http://bad","Oats")',
      portion: MealPortion(60, MealUnit.grams),
      nutrients: NutrientProfile(<NutrientKey, NutrientValue>{
        NutrientKey.energyKcal: NutrientMeasured(230.5),
        NutrientKey.proteinG: NutrientEstimated(8.2, basis: 'photo-estimate'),
        NutrientKey.carbohydrateG: NutrientReported(40),
        NutrientKey.fatG: NutrientValue.trace,
        NutrientKey.fiberG: NutrientValue.unknown,
      }),
      source: '+ai-estimate',
    );

    final entryNutrients = NutrientProfile(<NutrientKey, NutrientValue>{
      NutrientKey.energyKcal: NutrientMeasured(95),
      NutrientKey.proteinG: NutrientValue.unknown,
    });

    final snapshot = UserDataSnapshot(
      entries: <Map<String, Object?>>[
        <String, Object?>{
          'id': 'entry-1',
          'requestId': 'req-1',
          'diaryDate': '2026-11-18',
          'instantUtcMs': 1763460000000,
          'offsetMinutes': 0,
          'channel': 'manual',
          'recordedAtMs': 1763460000000,
          'revision': 1,
          'note': null,
        },
      ],
      entryItems: <Map<String, Object?>>[
        <String, Object?>{
          'id': 'ei-1',
          'entryId': 'entry-1',
          'foodId': 'food-apple',
          'name': '@Apple, "crisp"',
          'grams': 150.0,
          'nutrientsJson': jsonEncode(entryNutrients.toJson()),
          'position': 0,
        },
      ],
      meals: <Map<String, Object?>>[
        <String, Object?>{
          'id': 'meal-1',
          'diaryDate': '2026-11-19',
          'slot': 'breakfast',
          'caption': 'Morning oats',
          'createdAtMs': 1763546400000,
          'revision': 1,
          'photoPath': null,
          'itemsJson': jsonEncode(<Object?>[encodePhotoMealItem(mealItem)]),
          'estimateStatus': 'complete',
          'recordedOffsetMinutes': 0,
        },
      ],
      documents: const <Map<String, Object?>>[],
      mutations: const <Map<String, Object?>>[],
    );

    final csv = exportDiaryCsv(snapshot);
    final lines = csv.trimRight().split('\n');

    expect(
      lines.first,
      'date,meal_id,slot,food_name,portion_amount,portion_unit,nutrient_key,value,state,provenance',
    );

    // 5 nutrients on meal-1 + 2 nutrients on entry-1 = 7 data rows + 1 header
    expect(lines.length, 8);

    // Photo meal rows
    expect(
      lines,
      contains(
        '"2026-11-19","meal-1","breakfast","\'=HYPERLINK(""http://bad"",""Oats"")",60,"g","energy_kcal",230.5,"measured","\'+ai-estimate"',
      ),
    );
    expect(
      lines,
      contains(
        '"2026-11-19","meal-1","breakfast","\'=HYPERLINK(""http://bad"",""Oats"")",60,"g","protein_g",8.2,"estimated","\'+ai-estimate"',
      ),
    );
    expect(
      lines,
      contains(
        '"2026-11-19","meal-1","breakfast","\'=HYPERLINK(""http://bad"",""Oats"")",60,"g","carbohydrate_g",40,"reported","\'+ai-estimate"',
      ),
    );
    expect(
      lines,
      contains(
        '"2026-11-19","meal-1","breakfast","\'=HYPERLINK(""http://bad"",""Oats"")",60,"g","fat_g",,"trace","\'+ai-estimate"',
      ),
    );
    // Unknown value MUST be empty, never 0, with explicit "unknown" state
    expect(
      lines,
      contains(
        '"2026-11-19","meal-1","breakfast","\'=HYPERLINK(""http://bad"",""Oats"")",60,"g","fiber_g",,"unknown","\'+ai-estimate"',
      ),
    );

    // Legacy entry rows
    expect(
      lines,
      contains(
        '"2026-11-18","entry-1","","\'@Apple, ""crisp""",150,"g","energy_kcal",95,"measured","manual"',
      ),
    );
    expect(
      lines,
      contains(
        '"2026-11-18","entry-1","","\'@Apple, ""crisp""",150,"g","protein_g",,"unknown","manual"',
      ),
    );
  });
}
