import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../intake_moment.dart';
import 'saved_meals_screen.dart';
import 'drafts_screen.dart';
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
                label: Text(tr(c, 'Drafts', 'Rascunhos')),
                onPressed: () => Navigator.of(c).push<void>(
                    MaterialPageRoute(builder: (_) => const DraftsScreen()))),
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
                          child: Text(_emptyMessage(c))))
                  : ListView.builder(
                      itemCount: foods.length,
                      itemBuilder: (c, i) {
                        final f = foods[i];
                        return ListTile(
                            title: Text(f.name),
                            subtitle: Text(_resultSubtitle(c, f)),
                            isThreeLine: true,
                            onTap: () => _showFoodDetails(c, f),
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
                      }))),
      const _CatalogueNotice()
    ]);
  }

  /// Provenance line for one result. The development fixture is labelled as an
  /// unverified placeholder so it can never be mistaken for imported INSA data.
  String _resultSubtitle(BuildContext c, Food f) {
    final provenance =
        '${f.source.dataset} · ${f.basisValue} ${f.basisUnit.name}\n'
        '${tr(c, 'Source:', 'Fonte:')} ${f.source.datasetVersion ?? tr(c, 'version unknown', 'versão desconhecida')}';
    if (f.source.dataset == 'dev-fixture') {
      return '$provenance\n${tr(c, 'Placeholder fixture - not verified data', 'Dados de exemplo - não verificados')}';
    }
    return provenance;
  }

  /// An empty list can mean an incomplete query, a bounded local search with no
  /// match, or an empty favourites/recent list. They get distinct guidance so a
  /// miss reads as "not in the installed catalogue", never as an error.
  String _emptyMessage(BuildContext c) {
    if (view == 'favorites') {
      return tr(
          c,
          'No favourite foods yet. Tap the star on a result to keep it here.',
          'Ainda não há favoritos. Toca na estrela de um resultado para o guardar aqui.');
    }
    if (view == 'recent') {
      return tr(
          c,
          'Nothing recorded recently yet. Foods you record appear here.',
          'Ainda não há alimentos registados recentemente. Os alimentos que registares aparecem aqui.');
    }
    if (query.trim().length < 2) {
      return tr(c, 'Type at least two characters to search.',
          'Escreve pelo menos dois caracteres para pesquisar.');
    }
    return tr(
        c,
        'No local match. Create a food from its label or check the barcode; no network lookup is made.',
        'Sem resultados locais. Cria um alimento a partir do rótulo ou verifica o código de barras; não é feita nenhuma pesquisa na rede.');
  }

  /// Shows one catalogue record: provenance plus every retained nutrient
  /// observation, including explicit source gaps.
  ///
  /// The list is the source's own record, not a reference comparison. Blank
  /// source cells remain unknown observations and are never shown as zero.
  Future<void> _showFoodDetails(BuildContext c, Food f) {
    final observations = f.observations;
    final valued = observations.where((o) => o.amount != null).toList();
    final unquantified = observations
        .where((o) =>
            o.amount == null &&
            (o.qualifier == ObservationQualifier.trace ||
                o.qualifier == ObservationQualifier.belowDetection))
        .toList();
    final unknown = observations
        .where((o) => o.qualifier == ObservationQualifier.unknown)
        .toList();
    final projectedKeys = f.per100g.knownKeys.toList();
    final manifests = ref.read(installedCataloguesProvider).asData?.value ??
        const <InstalledCatalogueManifest>[];
    String? attribution;
    for (final manifest in manifests) {
      if (manifest.dataset == f.source.dataset &&
          manifest.attribution.trim().isNotEmpty) {
        attribution = manifest.attribution;
        break;
      }
    }
    return showDialog<void>(
        context: c,
        builder: (dialogContext) => AlertDialog(
            title: Text(f.name),
            content: SingleChildScrollView(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(
                          '${f.source.dataset} · ${f.source.datasetId}'),
                      SelectableText(
                          '${tr(c, 'Version', 'Versão')}: ${f.source.datasetVersion ?? tr(c, 'unknown', 'desconhecida')}'),
                      SelectableText(
                          '${tr(c, 'Licence', 'Licença')}: ${f.source.licence ?? tr(c, 'unknown', 'desconhecida')}'),
                      if (attribution != null) SelectableText(attribution),
                      SelectableText(
                          '${tr(c, 'State', 'Estado')}: ${f.preparation.name}'),
                      const SizedBox(height: 12),
                      Text(
                          tr(
                              c,
                              'Nutrient observations: ${observations.length}; with a value: ${valued.length}',
                              'Observações de nutrientes: ${observations.length}; com valor: ${valued.length}'),
                          style:
                              Theme.of(dialogContext).textTheme.titleSmall),
                      if (observations.isEmpty && projectedKeys.isEmpty)
                        Text(tr(c, 'This record carries no nutrient values.',
                            'Este registo não contém valores de nutrientes.')),
                      if (observations.isEmpty)
                        for (final key in projectedKeys)
                          SelectableText(_projectedNutrientLine(c, f, key)),
                      for (final observation in valued)
                        SelectableText(_observationLine(c, observation)),
                      for (final observation in unquantified)
                        SelectableText(_observationLine(c, observation)),
                      if (unknown.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SelectableText(
                            '${tr(c, 'Not provided by this source', 'Não fornecido por esta fonte')}: ${unknown.map((o) => nutrientLabel(c, o.nutrient.id)).join(', ')}'),
                      ],
                      const SizedBox(height: 8),
                      Text(tr(
                          c,
                          'Missing values are unknown, not zero. This is a source record, not a nutrient reference comparison or an intake assessment.',
                          'Valores em falta são desconhecidos, não zero. Este é o registo da fonte, não uma comparação com referências nem uma avaliação da ingestão.')),
                    ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(tr(c, 'Close', 'Fechar')))
            ]));
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
    // A food reached from the barcode sheet keeps its capture channel; the entry
    // snapshot is otherwise identical to a typed search pick.
    final fromBarcode =
        barcodeMatches?.any((match) => match.id == food.id) ?? false;
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
      if (amount.saveDraft) {
        final ids = ref.read(idGeneratorProvider);
        final store = MealDraftStore(ref.read(databaseProvider));
        final values = <String, Object?>{
          'food': foodSnapshot(food),
          'amount': amount.exact.toJson(),
          'instant': amount.stamp.instantUtc.toIso8601String(),
          'offset': amount.stamp.offsetMinutes,
          'day': amount.day.toIso(),
        };
        final draft = await store.create(
            id: ids.next(), requestId: ids.next(), values: values);
        await store.receiveValidated(
            id: draft.id,
            requestId: ids.next(),
            expectedRevision: draft.revision,
            suggestion: values);
        if (c.mounted) {
          ScaffoldMessenger.of(c).showSnackBar(SnackBar(
              content: Text(tr(c, 'Draft saved; nothing recorded',
                  'Rascunho guardado; nada foi registado'))));
        }
        return;
      }
      final result = await ref.read(logFoodHandlerProvider).handle(
          LogFoodCommand(
              requestId: ref.read(idGeneratorProvider).next(),
              foodId: food.id,
              channel: fromBarcode ? EntryChannel.barcode : EntryChannel.search,
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
  _RecordedQuantity(this.quantity, this.exact, this.stamp, this.day,
      {this.saveDraft = false});
  final bool saveDraft;
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
      TextEditingController(text: widget.food.basisValue.trim());
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
            TextButton(
                onPressed: () => submit(c, true),
                child: Text(tr(c, 'Save draft', 'Guardar rascunho'))),
            FilledButton(
                onPressed: () => submit(c, false),
                child: Text(tr(c, 'Confirm intake', 'Confirmar consumo')))
          ]);

  void submit(BuildContext c, bool saveDraft) {
    try {
      final value = Exact.parse(text.text.trim().replaceAll(',', '.'));
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
              moment.diaryDate,
              saveDraft: saveDraft));
    } catch (_) {
      setState(() => error = tr(
          c, 'Enter a positive quantity', 'Introduz uma quantidade positiva'));
    }
  }
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
      // The stored basis is the exact decimal text, trimmed: stray whitespace
      // must not become part of a value that logging parses again later.
      final basisText = basis.text.trim().replaceAll(',', '.');
      final b = Exact.parse(basisText);
      if (!b.positive || name.text.trim().isEmpty) {
        throw ArgumentError('Name and positive basis required');
      }
      final basisAmount = FoodAmount.exact(b, unit,
          measureId: unit == FoodUnit.item
              ? 'piece'
              : unit == FoodUnit.serving
                  ? 'serving'
                  : null);
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
              basis: basisAmount,
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
            per100g: projectObservations(completed, basis: basisAmount),
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
            basisValue: basisText,
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

/// Exact source amounts are not re-rounded through the shortest double string.
String _exactAmountLabel(Exact value) {
  var text = value.toDouble().toStringAsFixed(3);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  text = text.replaceFirst(RegExp(r'\.$'), '');
  return text.isEmpty ? '0' : text;
}

/// One retained observation as a readable line, preserving its qualifier and
/// any source definition that differs from the canonical nutrient identity.
String _observationLine(BuildContext c, NutrientObservation observation) {
  final label = nutrientLabel(c, observation.nutrient.id);
  final definition = observation.nutrient.definition == observation.nutrient.id
      ? ''
      : ' [${observation.nutrient.definition}]';
  final state = switch (observation.qualifier) {
    ObservationQualifier.estimated => tr(c, ' (estimated)', ' (estimado)'),
    ObservationQualifier.trace => tr(c, ' (trace)', ' (vestígios)'),
    ObservationQualifier.belowDetection =>
      tr(c, ' (below detection)', ' (abaixo do limite)'),
    ObservationQualifier.reported ||
    ObservationQualifier.reportedZero ||
    ObservationQualifier.unknown =>
      '',
  };
  final amount = observation.amount;
  if (amount == null) return '$label$state$definition';
  return '$label: ${_exactAmountLabel(amount)} '
      '${observation.nutrient.unit}$state$definition';
}

/// Fallback line for a record that stores only its legacy per-100 g profile.
String _projectedNutrientLine(BuildContext c, Food food, NutrientKey key) {
  final value = food.per100g[key];
  final amount = value.exactValue;
  final state = value is NutrientEstimated
      ? tr(c, ' (estimated)', ' (estimado)')
      : value is NutrientTrace
          ? tr(c, ' (trace)', ' (vestígios)')
          : '';
  if (amount == null) return nutrientLabel(c, key.wire);
  return '${nutrientLabel(c, key.wire)}: ${_exactAmountLabel(amount)} '
      '${key.unit}$state';
}

/// Source attribution and built-in catalogue status under local search.
///
/// The source's required citation is shown wherever its records appear; the
/// family-test disclosure makes clear that bundling the workbook is not a
/// redistributable licence or a review of its content. A startup failure is
/// shown here instead of silently leaving search empty.
class _CatalogueNotice extends ConsumerWidget {
  const _CatalogueNotice();

  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final catalogue = ref.watch(catalogueProvisioningProvider);
    // Outside the real composition root (tests, isolated previews) there is no
    // startup outcome; skip the manifest read entirely rather than opening a
    // database future for a footer that cannot show a provisioning result.
    if (catalogue == null) return const SizedBox.shrink();
    final failure = catalogue.failure;
    final manifests = ref.watch(installedCataloguesProvider).asData?.value ??
        const <InstalledCatalogueManifest>[];
    final attributed = [
      for (final manifest in manifests)
        if (manifest.attribution.trim().isNotEmpty) manifest
    ];
    final hasInsa = attributed
        .any((manifest) => manifest.dataset == InsaBdcaWorkbookAdapter.dataset);
    if (failure == null && attributed.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(c);
    final style = theme.textTheme.bodySmall;
    return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (failure != null) ...[
            Text(
                tr(c,
                    'Built-in INSA catalogue unavailable. Your own foods and diary are unchanged.',
                    'Catálogo INSA integrado indisponível. Os teus alimentos e diário não foram alterados.'),
                style: style?.copyWith(color: theme.colorScheme.error)),
            SelectableText('$failure', style: style),
          ],
          for (final manifest in attributed)
            SelectableText(manifest.attribution, style: style),
          if (hasInsa)
            Text(
                tr(c,
                    'The INSA BDCA workbook is bundled only for this private family-testing build. Its inclusion is not a redistributable licence and does not constitute a review of the data.',
                    'O livro BDCA do INSA está integrado apenas para este build privado de teste familiar. A inclusão não é uma licença de redistribuição nem constitui uma revisão dos dados.'),
                style: style),
        ]));
  }
}
