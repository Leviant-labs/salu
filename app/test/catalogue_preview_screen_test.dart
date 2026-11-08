import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/features/catalogue/catalogue_preview_screen.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'offline_flows_test.dart' as harness;

void main() {
  testWidgets('catalogue preview shows provenance and never installs',
      (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final candidate = CataloguePack(
        dataset: 'fixture',
        version: '1',
        licence: 'fixture-only',
        attribution: 'Test source',
        foods: [
          Food(
              id: 'fixture:apple',
              name: 'Apple',
              per100g: const NutrientProfile.empty(),
              source: const FoodSource(
                  dataset: 'fixture',
                  datasetId: 'apple',
                  datasetVersion: '1',
                  licence: 'fixture-only'))
        ]);
    final before = await ArchiveService(db).exportJson();
    await harness.pump(t, db,
        CataloguePreviewScreen(loadPack: () async => candidate.encode()));
    await t.tap(find.text('Choose catalogue pack'));
    await t.pumpAndSettle();
    expect(find.text('fixture · 1'), findsOneWidget);
    expect(find.text('Licence: fixture-only'), findsOneWidget);
    expect(find.text('Added: 1'), findsOneWidget);
    expect(find.text('fixture:apple'), findsOneWidget);
    expect(await ArchiveService(db).exportJson(), before);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('invalid catalogue does not show a preview', (t) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await harness.pump(
        t, db, CataloguePreviewScreen(loadPack: () async => 'not json'));
    await t.tap(find.text('Choose catalogue pack'));
    await t.pumpAndSettle();
    expect(find.text('Could not read this catalogue pack.'), findsOneWidget);
    expect(find.textContaining('Added:'), findsNothing);
  });
}
