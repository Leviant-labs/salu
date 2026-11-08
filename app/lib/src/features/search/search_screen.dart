import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../intake_moment.dart';
import 'saved_meals_screen.dart';
import '../../ui_support.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  String query = '';
  String view = 'search';
  List<Food>? barcodeMatches;
  @override
  Widget build(BuildContext c) {
    final results = barcodeMatches == null
        ? (view == 'favorites'
            ? ref.watch(favoriteFoodsProvider)
            : view == 'recent'
                ? ref.watch(recentFoodsProvider)
                : ref.watch(foodSearchProvider(query)))
        : AsyncValue.data(barcodeMatches!);
    final favoriteIds = ref
            .watch(favoriteFoodsProvider)
            .asData
            ?.value
            .map((f) => f.id)
            .toSet() ??
        <String>{};
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
              decoration: InputDecoration(
                  labelText:
                      tr(c, 'Search local foods', 'Pesquisar alimentos locais'),
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder()),
              onChanged: (s) => setState(() {
                    query = s;
                    barcodeMatches = null;
                    view = 'search';
                  }))),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            for (final choice in [
              ('search', tr(c, 'Search', 'Pesquisar')),
              ('favorites', tr(c, 'Favourites', 'Favoritos')),
              ('recent', tr(c, 'Recently recorded', 'Registados recentemente'))
            ])
              ChoiceChip(
                  label: Text(choice.$2),
                  selected: view == choice.$1,
                  onSelected: (_) => setState(() {
                        view = choice.$1;
                        barcodeMatches = null;
                      })),
            ActionChip(
                label:
                    Text(tr(c, 'Enter barcode', 'Introduzir código de barras')),
                onPressed: () => _barcode(c)),
            ActionChip(
                label: Text(tr(c, 'Saved meals', 'Refeições guardadas')),
                onPressed: () => Navigator.of(c).push<void>(MaterialPageRoute(
                    builder: (_) => const SavedMealsScreen()))),
          ])),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                  icon: const Icon(Icons.add),
                  label:
                      Text(tr(c, 'Create a custom food', 'Criar um alimento')),
                  onPressed: () async {
                    await Navigator.of(c).push<void>(MaterialPageRoute(
                        builder: (_) => const CustomFoodScreen()));
                    ref.invalidate(foodSearchProvider(query));
                  }))),
      Expanded(
          child: results.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, s) => Center(child: Text('$e')),
              data: (foods) => foods.isEmpty
                  ? Center(
                      child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(tr(
                              c,
                              'Type two characters to search. If there is no match, create a food from its label.',
                              'Escreve dois caracteres para pesquisar. Se não houver resultados, cria um alimento a partir do rótulo.'))))
                  : ListView.builder(
                      itemCount: foods.length,
                      itemBuilder: (c, i) {
                        final f = foods[i];
                        return ListTile(
                            title: Text(f.name),
                            subtitle: Text(
                                '${f.source.dataset} · ${f.basisValue} ${f.basisUnit.name}\n${tr(c, 'Source:', 'Fonte:')} ${f.source.datasetVersion ?? tr(c, 'version unknown', 'versão desconhecida')}'),
                            isThreeLine: true,
                            onTap: () => showDialog<void>(
                                context: c,
                                builder: (_) => AlertDialog(
                                        title: Text(f.name),
                                        content: SingleChildScrollView(
                                            child: Text(
                                                '${f.source.dataset} · ${f.source.datasetId}\n${f.source.datasetVersion ?? tr(c, "Version unknown", "Versão desconhecida")}\n${f.source.licence ?? tr(c, "Licence unknown", "Licença desconhecida")}\n${f.preparation.name}\n${f.observations.map((o) => '${o.nutrient.id} (${o.nutrient.unit}; ${o.nutrient.definition}): ${o.qualifier.name} ${o.amount ?? ""}').join('\n')}')),
                                        actions: [
                                          TextButton(
                                              onPressed: () => Navigator.pop(c),
                                              child: Text(
                                                  tr(c, 'Close', 'Fechar')))
                                        ])),
                            trailing:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                  tooltip: tr(c, 'Toggle favourite',
                                      'Alterar favorito'),
                                  icon: Icon(favoriteIds.contains(f.id)
                                      ? Icons.star
                                      : Icons.star_border),
                                  onPressed: () async {
                                    try {
                                      await ref
                                          .read(foodLibraryProvider)
                                          .setFavorite(SetFavoriteFoodCommand(
                                              requestId: ref
                                                  .read(idGeneratorProvider)
                                                  .next(),
                                              foodId: f.id,
                                              favorite:
                                                  !favoriteIds.contains(f.id)));
                                      ref.invalidate(favoriteFoodsProvider);
                                      ref.invalidate(foodSearchProvider(query));
                                    } catch (e) {
                                      if (c.mounted) showFailure(c, e);
                                    }
                                  }),
                              IconButton(
                                  tooltip: tr(c, 'Choose quantity and log',
                                      'Escolher quantidade e registar'),
                                  icon: const Icon(Icons.add_circle_outline),
                                  onPressed: () => _log(c, f))
                            ]));
                      })))
    ]);
  }

  Future<void> _barcode(BuildContext c) async {
    final text = await askText(c,
        title: tr(c, 'Product barcode', 'Código de barras do produto'));
    if (text == null) return;
    try {
      final barcode = ProductBarcode(text);
      final matches = await DriftFoodRepository(ref.read(databaseProvider))
          .findByBarcode(barcode);
      if (!c.mounted) return;
      if (matches.isEmpty) {
        if (await confirmAction(
            c,
            tr(c, 'No local match', 'Sem resultado local'),
            tr(
                c,
                'Create a food from the product label? No network lookup will be made.',
                'Criar um alimento a partir do rótulo? Não será feita uma pesquisa na rede.'))) {
          if (!c.mounted) return;
          await Navigator.of(c).push<void>(MaterialPageRoute(
              builder: (_) => CustomFoodScreen(barcode: barcode.value)));
          ref.invalidate(foodSearchProvider(query));
        }
      } else {
        setState(() {
          barcodeMatches = matches;
          view = 'search';
        });
      }
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _log(BuildContext c, Food food) async {
    final day = ref.read(todayDiaryDateProvider);
    final now = ref.read(clockProvider).nowUtc().toLocal();
    final wall = DateTime(day.year, day.month, day.day, now.hour, now.minute);
    final amount = await showDialog<_RecordedQuantity>(
        context: c,
        builder: (_) => _QuantityDialog(
            food: food,
            day: day,
            stamp: EventStamp(
                instant: wall, offsetMinutes: wall.timeZoneOffset.inMinutes)));
    if (amount == null) return;
    try {
      final result = await ref.read(logFoodHandlerProvider).handle(
          LogFoodCommand(
              requestId: ref.read(idGeneratorProvider).next(),
              foodId: food.id,
              quantity: amount.quantity,
              exactQuantity: amount.exact,
              diaryDate: amount.day,
              eatenAt: amount.stamp.instantUtc,
              offsetMinutes: amount.stamp.offsetMinutes));
      if (!c.mounted) return;
      switch (result) {
        case LoggedFood():
          ref.invalidate(todayEntriesProvider);
          ref.invalidate(recentFoodsProvider);
          ScaffoldMessenger.of(c).showSnackBar(SnackBar(
              content: Text(tr(c, 'Food recorded', 'Alimento registado'))));
        case LogFoodRejected():
          showFailure(c, result.message);
      }
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }
}

final class _RecordedQuantity {
  _RecordedQuantity(this.quantity, this.exact, this.stamp, this.day);
  final Quantity quantity;
  final FoodAmount exact;
  final EventStamp stamp;
  final DiaryDate day;
}

class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog(
      {required this.food, required this.day, required this.stamp});
  final Food food;
  final DiaryDate day;
  final EventStamp stamp;
  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final TextEditingController text =
      TextEditingController(text: widget.food.basisValue);
  late FoodUnit unit = widget.food.basisUnit;
  String? error;
  late final moment = IntakeMomentInput(widget.stamp, widget.day);
  @override
  void dispose() {
    text.dispose();
    moment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text(widget.food.name),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: text,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: tr(c, 'Consumed amount', 'Quantidade consumida'),
                    errorText: error)),
            DropdownButton<FoodUnit>(
                value: unit,
                isExpanded: true,
                items: [
                  for (final u in FoodUnit.values)
                    DropdownMenuItem(value: u, child: Text(u.name))
                ],
                onChanged: (u) => setState(() => unit = u!)),
            Text(tr(
                c,
                'Confirm what you consumed. A planned meal is not recorded automatically.',
                'Confirma o que consumiste. Uma refeição planeada não é registada automaticamente.')),
            moment.fields(c),
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(c, 'Cancel', 'Cancelar'))),
            FilledButton(
                onPressed: () {
                  try {
                    final value = Exact.parse(text.text.replaceAll(',', '.'));
                    if (!value.positive) throw ArgumentError();
                    final n = value.toDouble();
                    final quantity = switch (unit) {
                      FoodUnit.g => MassQuantity(n),
                      FoodUnit.ml => VolumeQuantity(n),
                      FoodUnit.item => PieceQuantity(n),
                      FoodUnit.serving => ServingQuantity(n)
                    };
                    Navigator.pop(
                        c,
                        _RecordedQuantity(
                            quantity,
                            FoodAmount.exact(value, unit,
                                measureId: unit == FoodUnit.item
                                    ? 'piece'
                                    : unit == FoodUnit.serving
                                        ? 'serving'
                                        : null),
                            moment.stamp,
                            moment.diaryDate));
                  } catch (_) {
                    setState(() => error = tr(c, 'Enter a positive quantity',
                        'Introduz uma quantidade positiva'));
                  }
                },
                child: Text(tr(c, 'Confirm intake', 'Confirmar consumo')))
          ]);
}

class CustomFoodScreen extends ConsumerStatefulWidget {
  const CustomFoodScreen({super.key, this.barcode});
  final String? barcode;
  @override
  ConsumerState<CustomFoodScreen> createState() => _CustomFoodState();
}

class _CustomFoodState extends ConsumerState<CustomFoodScreen> {
  final name = TextEditingController(),
      basis = TextEditingController(text: '100'),
      allergens = TextEditingController();
  final values = {
    for (final key in NutrientKey.values) key: TextEditingController()
  };
  late final barcode = TextEditingController(text: widget.barcode ?? '');
  final aliases = TextEditingController();
  String carbohydrateDefinition = 'unspecified';
  FoodUnit unit = FoodUnit.g;
  Preparation preparation = Preparation.unspecified;
  bool busy = false;
  @override
  void dispose() {
    barcode.dispose();
    aliases.dispose();
    name.dispose();
    basis.dispose();
    allergens.dispose();
    for (final c in values.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar:
          AppBar(title: Text(tr(c, 'Custom food', 'Alimento personalizado'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(tr(
            c,
            'Copy declared values from a label. Leave absent values blank. A printed zero is a reported zero.',
            'Copia os valores declarados no rótulo. Deixa em branco os valores ausentes. Um zero impresso é um zero declarado.')),
        TextField(
            controller: name,
            decoration: InputDecoration(
                labelText: tr(c, 'Food name', 'Nome do alimento'))),
        TextField(
            controller: barcode,
            decoration: InputDecoration(
                labelText: tr(
                    c, 'Barcode (optional)', 'Código de barras (opcional)'))),
        TextField(
            controller: aliases,
            decoration: InputDecoration(
                labelText: tr(c, 'Search aliases, comma separated',
                    'Nomes de pesquisa, separados por vírgula'))),
        DropdownButtonFormField<String>(
            initialValue: carbohydrateDefinition,
            decoration: InputDecoration(
                labelText: tr(c, 'Carbohydrate definition',
                    'Definição de hidratos de carbono')),
            items: [
              DropdownMenuItem(
                  value: 'unspecified',
                  child: Text(
                      tr(c, 'Unknown definition', 'Definição desconhecida'))),
              DropdownMenuItem(
                  value: 'eu_available_including_polyols',
                  child: Text(tr(c, 'EU available carbohydrate',
                      'Hidratos de carbono disponíveis (UE)'))),
              DropdownMenuItem(
                  value: 'us_total_including_fibre',
                  child: Text(tr(c, 'US total carbohydrate',
                      'Hidratos de carbono totais (EUA)'))),
            ],
            onChanged: (v) => setState(() => carbohydrateDefinition = v!)),
        Text(tr(
            c,
            'Only the EU definition contributes to available carbohydrate totals. Other declarations are preserved in food details.',
            'Só a definição da UE contribui para os totais de hidratos disponíveis. As restantes declarações ficam nos detalhes do alimento.')),
        TextField(
            controller: basis,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: tr(c, 'Label basis amount',
                    'Quantidade de referência do rótulo'))),
        DropdownButton<FoodUnit>(
            value: unit,
            items: [
              for (final u in FoodUnit.values)
                DropdownMenuItem(value: u, child: Text(u.name))
            ],
            onChanged: (u) => setState(() => unit = u!)),
        DropdownButton<Preparation>(
            value: preparation,
            items: [
              for (final p in Preparation.values)
                DropdownMenuItem(value: p, child: Text(p.name))
            ],
            onChanged: (p) => setState(() => preparation = p!)),
        TextField(
            controller: allergens,
            decoration: InputDecoration(
                labelText: tr(c, 'Declared allergens, comma separated',
                    'Alergénios declarados, separados por vírgula'),
                helperText: tr(c, 'Blank means unknown, not allergen-free.',
                    'Em branco significa desconhecido, não significa ausência de alergénios.'))),
        for (final key in NutrientKey.values)
          TextField(
              controller: values[key],
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: '${nutrientLabel(c, key.wire)} (${key.unit})')),
        const SizedBox(height: 20),
        FilledButton(
            onPressed: busy ? null : _save,
            child: Text(tr(c, 'Save custom food', 'Guardar alimento')))
      ]));
  Future<void> _save() async {
    setState(() => busy = true);
    try {
      final b = Exact.parse(basis.text.replaceAll(',', '.'));
      if (!b.positive || name.text.trim().isEmpty) {
        throw ArgumentError('Name and positive basis required');
      }
      final id = ref.read(idGeneratorProvider).next();
      final observations = <NutrientObservation>[];
      for (final entry in values.entries) {
        if (entry.value.text.trim().isNotEmpty) {
          final n = Exact.parse(entry.value.text.trim().replaceAll(',', '.'));
          observations.add(NutrientObservation(
              nutrient: NutrientIdentity(
                  entry.key.wire,
                  entry.key.unit,
                  entry.key == NutrientKey.carbohydrateG
                      ? carbohydrateDefinition
                      : entry.key.wire),
              basis: FoodAmount.exact(b, unit,
                  measureId: unit == FoodUnit.item
                      ? 'piece'
                      : unit == FoodUnit.serving
                          ? 'serving'
                          : null),
              qualifier: n == Exact.zero
                  ? ObservationQualifier.reportedZero
                  : ObservationQualifier.reported,
              sourceId: id,
              sourceVersion: '1',
              origin: 'user-label',
              exactAmount: n));
        }
      }
      final completed = completeEnergyUnits(observations);
      final repository = DriftFoodRepository(ref.read(databaseProvider));
      await repository.replaceCatalogueBatch([
        Food(
            id: 'custom:$id',
            name: name.text.trim(),
            per100g: projectObservations(completed,
                basis: FoodAmount.exact(b, unit,
                    measureId: unit == FoodUnit.item
                        ? 'piece'
                        : unit == FoodUnit.serving
                            ? 'serving'
                            : null)),
            observations: completed,
            barcodes: barcode.text.trim().isEmpty
                ? []
                : [ProductBarcode(barcode.text).value],
            aliases: aliases.text
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
            source: FoodSource(
                dataset: 'custom-user-entry',
                datasetId: id,
                datasetVersion: '1'),
            basisUnit: unit,
            basisValue: basis.text.replaceAll(',', '.'),
            quality: DataQuality.userEntered,
            preparation: preparation,
            allergens: allergens.text.trim().isEmpty
                ? null
                : allergens.text
                    .split(',')
                    .map((x) => x.trim().toLowerCase())
                    .toSet())
      ]);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
