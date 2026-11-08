import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});
  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  String query = '';
  @override
  Widget build(BuildContext c) {
    final results = ref.watch(foodSearchProvider(query));
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
              decoration: InputDecoration(
                  labelText:
                      tr(c, 'Search local foods', 'Pesquisar alimentos locais'),
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder()),
              onChanged: (s) => setState(() => query = s))),
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
                            trailing: IconButton(
                                tooltip: tr(c, 'Choose quantity and log',
                                    'Escolher quantidade e registar'),
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: () => _log(c, f)));
                      })))
    ]);
  }

  Future<void> _log(BuildContext c, Food food) async {
    final amount = await showDialog<Quantity>(
        context: c, builder: (_) => _QuantityDialog(food: food));
    if (amount == null) return;
    try {
      final result = await ref.read(logFoodHandlerProvider).handle(
          LogFoodCommand(
              requestId: ref.read(idGeneratorProvider).next(),
              foodId: food.id,
              quantity: amount,
              offsetMinutes: currentOffsetMinutes()));
      if (!c.mounted) return;
      switch (result) {
        case LoggedFood():
          ref.invalidate(todayEntriesProvider);
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

class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({required this.food});
  final Food food;
  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final TextEditingController text =
      TextEditingController(text: widget.food.basisValue);
  late FoodUnit unit = widget.food.basisUnit;
  String? error;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text(widget.food.name),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
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
                'Confirma o que consumiste. Uma refeição planeada não é registada automaticamente.'))
          ]),
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
                    Navigator.pop(
                        c,
                        switch (unit) {
                          FoodUnit.g => MassQuantity(n),
                          FoodUnit.ml => VolumeQuantity(n),
                          FoodUnit.item => PieceQuantity(n),
                          FoodUnit.serving => ServingQuantity(n)
                        });
                  } catch (_) {
                    setState(() => error = tr(c, 'Enter a positive quantity',
                        'Introduz uma quantidade positiva'));
                  }
                },
                child: Text(tr(c, 'Confirm intake', 'Confirmar consumo')))
          ]);
}

class CustomFoodScreen extends ConsumerStatefulWidget {
  const CustomFoodScreen({super.key});
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
  FoodUnit unit = FoodUnit.g;
  Preparation preparation = Preparation.unspecified;
  bool busy = false;
  @override
  void dispose() {
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
      final profile = <NutrientKey, NutrientValue>{};
      for (final entry in values.entries) {
        if (entry.value.text.trim().isNotEmpty) {
          final n = Exact.parse(entry.value.text.trim().replaceAll(',', '.'));
          profile[entry.key] = NutrientReported(n.toDouble());
        }
      }
      final id = ref.read(idGeneratorProvider).next();
      final repository = DriftFoodRepository(ref.read(databaseProvider));
      await repository.replaceCatalogueBatch([
        Food(
            id: 'custom:$id',
            name: name.text.trim(),
            per100g: NutrientProfile(profile),
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
