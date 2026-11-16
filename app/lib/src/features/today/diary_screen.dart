import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../intake_moment.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import '../progress/checkin_details.dart';
import 'weight_log_screen.dart';
import 'weight_visibility.dart';
/// The guided diary: recording/history, corrections, saved meals,
/// completeness, nutrients and water. Moved verbatim from the old Today
/// screen; step 8 replaces Today with the guided meal landing surface.
class DiaryScreen extends ConsumerWidget {
  const DiaryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(todayEntriesProvider);
    final date = ref.watch(todayDiaryDateProvider);
    final settings = ref.watch(settingsProvider);
    final support = settings['support'] == true;
    final hideCalories = hidesCalories(settings);
    final hideWeight = hidesWeight(settings);
    return entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('$e')),
        data: (list) => ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                IconButton(
                    tooltip: tr(context, 'Previous day', 'Dia anterior'),
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _move(ref, date, -1)),
                Expanded(
                    child: Text(date.toIso(), textAlign: TextAlign.center)),
                IconButton(
                    tooltip: tr(context, 'Next day', 'Dia seguinte'),
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _move(ref, date, 1))
              ]),
              if (!support)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  tr(context, 'Recorded nutrition',
                                      'Nutrição registada'),
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 12),
                              for (final key in [
                                if (!hideCalories) NutrientKey.energyKcal,
                                NutrientKey.proteinG,
                                NutrientKey.carbohydrateG,
                                NutrientKey.fatG,
                                NutrientKey.fiberG
                              ])
                                _NutrientRow(keyValue: key, entries: list),
                              ExpansionTile(
                                  title: Text(tr(context, 'More nutrients',
                                      'Mais nutrientes')),
                                  children: [
                                    _AdditionalNutrients(
                                        entries: list,
                                        hideCalories: hideCalories)
                                  ]),
                              Text(
                                  tr(
                                      context,
                                      'Recorded amounts describe your log. Missing values stay unknown.',
                                      'Os valores descrevem o registo. Os valores em falta permanecem desconhecidos.'),
                                  style: Theme.of(context).textTheme.bodySmall),
                            ]))),
              if (list.isEmpty)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(children: [
                      const Icon(Icons.restaurant_outlined, size: 40),
                      Text(
                          tr(context, 'Nothing logged yet',
                              'Ainda não há registos'),
                          style: Theme.of(context).textTheme.titleMedium),
                      Text(tr(
                          context,
                          'Search the Food tab or add your own food.',
                          'Pesquisa no separador Alimentos ou cria um alimento.'))
                    ])),
              for (final entry in list)
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_entryTitle(entry)),
                    subtitle: Text(_portionLabel(context, entry) ??
                        entry.items.map((i) => _itemAmount(context, i)).join(' · ')),
                    onTap: () => showModalBottomSheet<void>(
                        context: context, useSafeArea: true,
                        builder: (sheetContext) => ListView(
                          shrinkWrap: true, padding: const EdgeInsets.all(16),
                          children: [
                            Text(_entryTitle(entry), style: Theme.of(sheetContext).textTheme.titleLarge),
                            for (final item in entry.items)
                              ListTile(title: Text(item.name),
                                  subtitle: Text(_itemAmount(sheetContext, item))),
                          ])),
                    trailing: PopupMenuButton<String>(
                        tooltip: tr(context, 'Edit entry', 'Editar registo'),
                        onSelected: (action) =>
                            _edit(context, ref, entry, action),
                        itemBuilder: (c) => [
                              PopupMenuItem(
                                  value: 'save',
                                  child: Text(
                                      tr(c, 'Save meal', 'Guardar refeição'))),
                              PopupMenuItem(
                                  value: 'time',
                                  child: Text(tr(c, 'Correct time or diary day',
                                      'Corrigir hora ou dia do diário'))),
                              PopupMenuItem(
                                  value: 'edit',
                                  child: Text(tr(c, 'Change quantity',
                                      'Alterar quantidade'))),
                              PopupMenuItem(
                                  value: 'substitute',
                                  child: Text(tr(c, 'Substitute food',
                                      'Substituir alimento'))),
                              PopupMenuItem(
                                  value: 'copy',
                                  child: Text(
                                      tr(c, 'Repeat now', 'Repetir agora'))),
                              PopupMenuItem(
                                  value: 'delete',
                                  child: Text(tr(
                                      c, 'Delete entry', 'Eliminar registo')))
                            ])),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text(tr(context, 'Declare day completeness',
                      'Declarar estado do dia')),
                  onPressed: () => _complete(context, ref, date)),
              OutlinedButton.icon(
                  icon: const Icon(Icons.insights),
                  label:
                      Text(tr(context, 'Weekly check-in', 'Balanço semanal')),
                  onPressed: () => showCheckInDetails(context, ref, date)),
              OutlinedButton.icon(
                  icon: const Icon(Icons.water_drop_outlined),
                  label: Text(tr(context, 'Record water', 'Registar água')),
                  onPressed: () => _record(context, ref, 'water', 'ml')),
              if (!hideWeight)
                OutlinedButton.icon(
                    icon: const Icon(Icons.monitor_weight_outlined),
                    label: Text(tr(context, 'Record weight', 'Registar peso')),
                    onPressed: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const WeightLogScreen()))),
            ]));
  }

  String _entryTitle(LoggedEntry entry) {
    final recipeId = entry.items.firstOrNull?.sourceSnapshot?['recipeId'];
    final recipeRevision = entry.items.firstOrNull?.sourceSnapshot?['recipeRevision'];
    final recipeName = entry.items.firstOrNull?.sourceSnapshot?['recipeName'];
    if (recipeId is String &&
        recipeName is String &&
        recipeRevision is int &&
        entry.items.every((i) =>
            i.sourceSnapshot?['recipeId'] == recipeId &&
            i.sourceSnapshot?['recipeRevision'] == recipeRevision &&
            i.sourceSnapshot?['recipeName'] == recipeName)) {
      return recipeName;
    }
    return entry.items.map((i) => i.name).join(', ');
  }

  String? _portionLabel(BuildContext context, LoggedEntry entry) {
    if (entry.items.isEmpty) return null;
    final first = entry.items.first.sourceSnapshot;
    final id = first?['recipeId'];
    final revision = first?['recipeRevision'];
    final name = first?['recipeName'];
    final raw = first?['recipePortions'];
    if (id is! String || revision is! int || name is! String || raw is! Map) {
      return null;
    }
    try {
      final portions = Exact.fromJson(Map<String,Object?>.from(raw));
      if (!entry.items.every((item) {
        final source = item.sourceSnapshot;
        final amount = source?['recipePortions'];
        return source?['recipeId'] == id && source?['recipeRevision'] == revision &&
            source?['recipeName'] == name && amount is Map &&
            Exact.fromJson(Map<String,Object?>.from(amount)) == portions;
      })) {
        return null;
      }
      return '${number(portions.toDouble())} ${tr(context, 'portions', 'porções')}';
    } catch (_) {
      return null;
    }
  }

  void _move(WidgetRef ref, DiaryDate date, int delta) {
    final d = DateTime.utc(date.year, date.month, date.day)
        .add(Duration(days: delta));
    ref.read(selectedDiaryDateProvider.notifier).state =
        DiaryDate(d.year, d.month, d.day);
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, LoggedEntry entry,
      String action) async {
    try {
      if (action == 'save') {
        final name = await askText(context,
            title: tr(context, 'Meal name', 'Nome da refeição'));
        if (name == null) return;
        await ref.read(foodLibraryProvider).saveMeal(SaveMealCommand(
            requestId: ref.read(idGeneratorProvider).next(),
            entryRequestId: entry.requestId,
            name: name));
        ref.invalidate(savedMealsProvider);
      } else if (action == 'time') {
        final result = await showDialog<ReviewedIntakeMoment>(
            context: context,
            builder: (_) => IntakeMomentDialog(
                stamp: entry.stamp,
                day: entry.diaryDate,
                title: tr(context, 'Correct consumed time',
                    'Corrigir hora de consumo')));
        if (result == null) return;
        await DriftEntryRepository(ref.read(databaseProvider)).revise(
            ReviseEntryCommand(
                requestId: ref.read(idGeneratorProvider).next(),
                entryId: entry.id,
                expectedRevision: entry.revision,
                recordedAt: ref.read(clockProvider).nowUtc(),
                stamp: result.stamp,
                diaryDate: result.day));
      } else if (action == 'substitute') {
        final repository = ref.read(entryRepositoryProvider);
        if (repository is! DriftEntryRepository) {
          throw StateError('Editing repository unavailable');
        }
        if (!await _substitute(context, ref, repository, entry)) return;
      } else if (action == 'copy') {
        if (entry.items.any(_isBatchItem)) {
          throw StateError('BATCH_SELECTION_REQUIRED');
        }
        if (!await confirmAction(
            context,
            tr(context, 'Repeat meal now?', 'Repetir refeição agora?'),
            tr(
                context,
                'This records another consumed meal with the saved snapshots.',
                'Isto regista outra refeição consumida com os valores guardados.'))) {
          return;
        }
        final stamp = EventStamp(
            instant: ref.read(clockProvider).nowUtc(),
            offsetMinutes: currentOffsetMinutes());
        final id = ref.read(idGeneratorProvider).next();
        await ref.read(entryRepositoryProvider).append(LoggedEntry(
            id: id,
            requestId: 'repeat:$id',
            diaryDate: DiaryDate.assign(stamp),
            stamp: stamp,
            channel: EntryChannel.manual,
            items: entry.items,
            recordedAt: ref.read(clockProvider).nowUtc()));
      } else {
        ({Exact factor, int? itemIndex})? correction;
        if (action == 'edit') {
          correction = await _quantityCorrection(context, entry);
          if (correction == null) return;
        } else {
          final batchPortion = entry.items.any(_isBatchItem);
          final detail = batchPortion
              ? tr(
                  context,
                  'The current diary entry will be removed. Revision history remains in your local archive. The cooked batch keeps this amount recorded as consumed; removing the entry does not return it to stock.',
                  'O registo será removido do diário. O histórico de revisões permanece no arquivo local. O lote confecionado mantém esta quantidade como consumida; remover o registo não a devolve ao stock.')
              : tr(
                  context,
                  'The current diary entry will be removed. Revision history remains in your local archive.',
                  'O registo será removido do diário. O histórico de revisões permanece no arquivo local.');
          if (!await confirmAction(
              context, tr(context, 'Delete entry?', 'Eliminar registo?'),
              detail)) {
            return;
          }
        }
        final repository = ref.read(entryRepositoryProvider);
        if (repository is! DriftEntryRepository) {
          throw StateError('Editing repository unavailable');
        }
        await repository.revise(ReviseEntryCommand(
            requestId: ref.read(idGeneratorProvider).next(),
            entryId: entry.id,
            expectedRevision: entry.revision,
            recordedAt: ref.read(clockProvider).nowUtc(),
            multiplier: correction?.factor,
            itemIndex: correction?.itemIndex,
            delete: action == 'delete'));
      }
      ref.invalidate(todayEntriesProvider);
      ref.invalidate(recentFoodsProvider);
    } catch (e) {
      if (context.mounted) _reportFailure(context, e);
    }
  }

  /// Replaces one frozen item with an explicitly chosen food and amount.
  ///
  /// The replacement food's source and nutrients are frozen only after a review
  /// that names the removed and added item; cancelling at any step writes
  /// nothing. Cooked-batch portions are refused because their single stock
  /// allocation cannot be split item by item.
  Future<bool> _substitute(BuildContext context, WidgetRef ref,
      DriftEntryRepository repository, LoggedEntry entry) async {
    if (entry.items.any(_isBatchItem)) {
      throw StateError('BATCH_ITEM_SUBSTITUTION_UNSUPPORTED');
    }
    if (entry.items.isEmpty) {
      throw StateError('ITEM_INDEX_OUT_OF_RANGE');
    }
    final index = entry.items.length == 1
        ? 0
        : await _chooseItem(context, entry,
            title: tr(context, 'Which item to replace?',
                'Qual item substituir?'));
    if (index == null || !context.mounted) return false;
    final foods = ref.read(foodRepositoryProvider);
    final replacement = await showDialog<Food>(
        context: context,
        builder: (_) => _SubstitutionFoodPicker(foods: foods));
    if (replacement == null || !context.mounted) return false;
    final current = entry.items[index];
    final units = _substitutionUnits(replacement);
    final initial = current.quantity != null &&
            units.contains(current.quantity!.unit) &&
            current.quantity!.value.positive
        ? current.quantity
        : null;
    final amount = await showDialog<FoodAmount>(
        context: context,
        builder: (_) => _SubstitutionAmountDialog(
            food: replacement, units: units, initial: initial));
    if (amount == null || !context.mounted) return false;
    final detail = tr(
        context,
        'Replace “${current.name}” (${_itemAmount(context, current)}) with '
            '“${replacement.name}” (${_amountLabel(amount)})?\n\n'
            'Only this item changes. The other items and every earlier revision '
            'stay unchanged, and the new source and nutrients are frozen from '
            'this food. Nothing is written until you confirm.\n\n'
            'Source: ${replacement.source.dataset} · '
            '${replacement.source.datasetVersion ?? 'version unknown'}',
        'Substituir “${current.name}” (${_itemAmount(context, current)}) por '
            '“${replacement.name}” (${_amountLabel(amount)})?\n\n'
            'Apenas este item muda. Os outros itens e todas as revisões '
            'anteriores permanecem inalterados, e a nova fonte e os nutrientes '
            'são congelados a partir deste alimento. Nada é escrito até '
            'confirmares.\n\n'
            'Fonte: ${replacement.source.dataset} · '
            '${replacement.source.datasetVersion ?? 'versão desconhecida'}');
    if (!await confirmAction(
        context,
        tr(context, 'Substitute food?', 'Substituir alimento?'),
        detail)) {
      return false;
    }
    await repository.substituteItem(SubstituteEntryItemCommand(
        requestId: ref.read(idGeneratorProvider).next(),
        entryId: entry.id,
        expectedRevision: entry.revision,
        recordedAt: ref.read(clockProvider).nowUtc(),
        itemIndex: index,
        replacement: replacement,
        amount: amount));
    return true;
  }

  /// Units a replacement amount may use for [food].
  ///
  /// Grams and the food's own label basis always apply. Volume and piece units
  /// are offered only when the food declares a valid conversion, so the picker
  /// cannot produce an amount the write would have to guess at.
  Set<FoodUnit> _substitutionUnits(Food food) {
    final density = food.portions.densityGramsPerMillilitre;
    final portion = food.portions.portionGrams;
    return {
      FoodUnit.g,
      food.basisUnit,
      if (density != null && density.isFinite && density > 0) FoodUnit.ml,
      if (portion != null && portion.isFinite && portion > 0) ...[
        FoodUnit.item,
        FoodUnit.serving
      ]
    };
  }

  String _amountLabel(FoodAmount amount) =>
      '${number(amount.value.toDouble())} ${amount.unit.name}';

  /// Chooses which frozen item to correct and by how much.
  ///
  /// A multi-item entry is corrected one item at a time so unrelated items keep
  /// their recorded amounts and nutrients. A finite cooked-batch portion keeps a
  /// single stock allocation for all its ingredients, so a multi-item batch
  /// entry is scaled as a whole instead.
  Future<({Exact factor, int? itemIndex})?> _quantityCorrection(
      BuildContext context, LoggedEntry entry) async {
    if (entry.items.length == 1) {
      final factor = await _itemFactor(context, entry.items.single);
      return factor == null ? null : (factor: factor, itemIndex: null);
    }
    if (entry.items.any(_isBatchItem)) {
      final factor = await _askPositiveFactor(context,
          title: tr(context, 'Whole-portion multiplier (cooked batch)',
              'Multiplicador da porção total (lote confecionado)'),
          initial: '1',
          divideBy: null);
      return factor == null ? null : (factor: factor, itemIndex: null);
    }
    final index = await _chooseItem(context, entry);
    if (index == null || !context.mounted) return null;
    final factor = await _itemFactor(context, entry.items[index]);
    return factor == null ? null : (factor: factor, itemIndex: index);
  }

  bool _isBatchItem(LoggedItem item) =>
      item.sourceSnapshot?['batchId'] is String;

  Future<int?> _chooseItem(BuildContext context, LoggedEntry entry,
          {String? title}) =>
      showDialog<int>(
          context: context,
          builder: (c) => SimpleDialog(
              title: Text(title ?? tr(c, 'Which item?', 'Qual item?')),
              children: [
                for (var i = 0; i < entry.items.length; i++)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(c, i),
                      child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry.items[i].name),
                          subtitle: Text(_itemAmount(c, entry.items[i]))))
              ]));

  /// Prompts for an item's eaten amount in its recorded unit, or a multiplier
  /// when the frozen snapshot has no display amount to divide by. Finite-batch
  /// ingredients are always corrected proportionally.
  Future<Exact?> _itemFactor(BuildContext context, LoggedItem item) async {
    final current = item.quantity;
    final grams = item.grams;
    final batchPortion = _isBatchItem(item);
    if (current != null && current.value.positive && !batchPortion) {
      return _askPositiveFactor(context,
          title: tr(context, 'New amount (${current.unit.name})',
              'Nova quantidade (${current.unit.name})'),
          initial: current.value.toString(),
          divideBy: current.value);
    }
    // Older rows froze only the eaten mass; they still have no unit amount.
    if (current == null && grams != null && grams > 0 && !batchPortion) {
      final stored = Exact.parse(grams.toString());
      return _askPositiveFactor(context,
          title: tr(context, 'New amount (g)', 'Nova quantidade (g)'),
          initial: grams.toString(),
          divideBy: stored);
    }
    return _askPositiveFactor(context,
        title: batchPortion
            ? tr(context, 'Whole-portion multiplier (cooked batch)',
                'Multiplicador da porção total (lote confecionado)')
            : tr(context, 'Quantity multiplier',
                'Multiplicador da quantidade'),
        initial: '1',
        divideBy: null);
  }

  String _itemAmount(BuildContext context, LoggedItem item) =>
      item.quantity != null
          ? '${number(item.quantity!.value.toDouble())} ${item.quantity!.unit.name}${item.sourceSnapshot?['quantityBasis'] == 'raw-edible-ingredient-allocation' ? tr(context, ' (ingredient allocation)', ' (quantidade do ingrediente)') : ''}'
          : item.grams == null
              ? tr(context, 'Equal recipe serving', 'Porção igual da receita')
              : '${number(item.grams!)} g';

  Future<Exact?> _askPositiveFactor(BuildContext context,
      {required String title,
      required String initial,
      required Exact? divideBy}) async {
    while (true) {
      if (!context.mounted) return null;
      final text = await askText(context, title: title, initial: initial);
      if (text == null) return null;
      try {
        final value = Exact.parse(text.trim().replaceAll(',', '.'));
        if (!value.positive) throw const FormatException('Positive required');
        return divideBy == null ? value : value / divideBy;
      } on FormatException {
        if (!context.mounted) return null;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(tr(context, 'Enter a positive number',
                'Introduz um número positivo'))));
      }
    }
  }

  /// Turns expected refusals into actionable text. Unexpected errors keep the
  /// raw detail so a real fault is not disguised as a user mistake.
  void _reportFailure(BuildContext context, Object error) {
    final known = error is StateError
        ? switch (error.message) {
            'BATCH_SELECTION_REQUIRED' => tr(
                context,
                'This meal uses finite cooked-batch stock. Record a new portion from the batch instead.',
                'Esta refeição vem de um lote confecionado com quantidade limitada. Regista uma nova porção a partir do lote.'),
            'STALE_ENTRY' => tr(
                context,
                'This entry changed in another operation. Reopen the day and try again.',
                'Este registo mudou noutra operação. Volta a abrir o dia e tenta novamente.'),
            'REQUEST_ID_REUSED' => tr(
                context,
                'This action conflicts with an earlier correction. Reopen the day and try again.',
                'Esta ação entra em conflito com uma correção anterior. Volta a abrir o dia e tenta novamente.'),
            'ITEM_INDEX_OUT_OF_RANGE' => tr(
                context,
                'That item is no longer in this entry. Reopen the day and try again.',
                'Esse item já não faz parte deste registo. Volta a abrir o dia e tenta novamente.'),
            'BATCH_ITEM_CORRECTION_UNSUPPORTED' => tr(
                context,
                'This meal comes from a finite cooked batch with one stock allocation for all ingredients. Correct the whole portion instead.',
                'Esta refeição vem de um lote confecionado com uma única reserva de stock para todos os ingredientes. Corrige a porção total.'),
            'BATCH_ITEM_SUBSTITUTION_UNSUPPORTED' => tr(
                context,
                'This meal comes from a finite cooked batch with one stock allocation for all ingredients. Substituting an item would leave the batch and its stock inconsistent. Record a new portion from the batch or correct the whole portion instead.',
                'Esta refeição vem de um lote confecionado com uma única reserva de stock para todos os ingredientes. Substituir um item deixaria o lote e o stock inconsistentes. Regista uma nova porção a partir do lote ou corrige a porção total.'),
            'INCOMPATIBLE_SUBSTITUTION_AMOUNT' => tr(
                context,
                'That amount has no recorded conversion for the replacement food. Choose grams or a unit this food declares.',
                'Essa quantidade não tem conversão registada para o alimento substituto. Escolhe gramas ou uma unidade declarada por este alimento.'),
            'BATCH_OVERALLOCATED' => tr(
                context,
                'That amount uses more cooked stock than the batch has. Reduce the portion or cook another batch.',
                'Essa quantidade usa mais stock do que o lote tem. Reduz a porção ou confeciona outro lote.'),
            'BATCH_RECONCILIATION_REQUIRED' => tr(
                context,
                'The stock record for this meal cannot be reconciled automatically. Check the cooked batch and its portions.',
                'O registo de stock desta refeição não pode ser reconciliado automaticamente. Verifica o lote e as suas porções.'),
            'DAY_HAS_INTAKE' => tr(
                context,
                'This day already has recorded intake, so it cannot be declared as no intake.',
                'Este dia já tem consumo registado, por isso não pode ser declarado sem ingestão.'),
            _ => null,
          }
        : null;
    if (known == null) {
      showFailure(context, error);
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(known)));
  }

  Future<void> _complete(
      BuildContext context, WidgetRef ref, DiaryDate date) async {
    final choice = await showDialog<DiaryCompleteness>(
        context: context,
        builder: (c) => SimpleDialog(
                title: Text(tr(c, 'Day completeness', 'Estado do dia')),
                children: [
                  for (final value in DiaryCompleteness.values)
                    SimpleDialogOption(
                        onPressed: () => Navigator.pop(c, value),
                        child: Text(switch (value) {
                          DiaryCompleteness.unknown =>
                            tr(c, 'Unknown', 'Desconhecido'),
                          DiaryCompleteness.partial =>
                            tr(c, 'Partial record', 'Registo parcial'),
                          DiaryCompleteness.userDeclaredComplete => tr(
                              c,
                              'I recorded all intake',
                              'Registei tudo o que consumi'),
                          DiaryCompleteness.confirmedNoIntake => tr(
                              c,
                              'I confirm no intake',
                              'Confirmo que não consumi alimentos')
                        }))
                ]));
    if (choice == null) return;
    try {
      if (choice == DiaryCompleteness.confirmedNoIntake &&
          (await ref.read(entryRepositoryProvider).entriesFor(date))
              .isNotEmpty) {
        throw StateError('DAY_HAS_INTAKE');
      }
      final w = LocalWorkspace(ref.read(databaseProvider));
      final old = await w.read('day', date.toIso());
      await w.put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'day',
          id: date.toIso(),
          expectedRevision: old?.revision ?? 0,
          data: {'completeness': choice.name});
      await w.invalidateHistory();
      await w.reward('day-review:${date.toIso()}');
    } catch (e) {
      if (context.mounted) _reportFailure(context, e);
    }
  }

  Future<void> _record(
      BuildContext c, WidgetRef ref, String collection, String unit) async {
    final text =
        await askText(c, title: tr(c, 'Amount ($unit)', 'Quantidade ($unit)'));
    if (text == null) return;
    try {
      final value = Exact.parse(text.replaceAll(',', '.'));
      if (!value.positive) throw ArgumentError('Positive amount required');
      final id = ref.read(idGeneratorProvider).next();
      await LocalWorkspace(ref.read(databaseProvider)).put(
          requestId: id,
          collection: collection,
          id: id,
          expectedRevision: 0,
          data: {
            'value': value.toJson(),
            'unit': unit,
            'time': ref.read(clockProvider).nowUtc().toIso8601String(),
            'offsetMinutes': currentOffsetMinutes()
          });
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }
}

/// Calorie visibility switch.
///
/// `support` is the master switch: when it is on, calorie visibility is hidden
/// regardless of the individual preference. A missing key keeps the previous
/// visible behavior. Weight uses the shared [hidesWeight] helper.
bool hidesCalories(Map<String, Object?> settings) =>
    settings['support'] == true || settings['hideCalorieNudges'] == true;

/// Searches the local catalogue for an explicit replacement food.
///
/// Only installed local foods are offered; no network lookup is made, and the
/// current entry is untouched until the whole flow is confirmed.
class _SubstitutionFoodPicker extends StatefulWidget {
  const _SubstitutionFoodPicker({required this.foods});
  final FoodRepository foods;
  @override
  State<_SubstitutionFoodPicker> createState() =>
      _SubstitutionFoodPickerState();
}

class _SubstitutionFoodPickerState extends State<_SubstitutionFoodPicker> {
  final search = TextEditingController();
  List<Food> results = const [];
  bool searching = false;
  int generation = 0;
  String? hint;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _run(String text) async {
    final token = ++generation;
    final query = text.trim();
    if (query.length < 2) {
      setState(() {
        results = const [];
        searching = false;
        hint = null;
      });
      return;
    }
    setState(() => searching = true);
    try {
      final found = await widget.foods.search(query);
      if (!mounted) return;
      if (token != generation) return;
      setState(() {
        results = found;
        searching = false;
        hint = found.isEmpty
            ? tr(context, 'No local match for that name.',
                'Sem resultado local para esse nome.')
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      if (token != generation) return;
      setState(() {
        searching = false;
        hint = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text(tr(c, 'Replacement food', 'Alimento substituto')),
          content: SizedBox(
              // Bounded and aligned to AlertDialog's 56 px intrinsic step so
              // its IntrinsicWidth short-circuits instead of asking the
              // ListView for intrinsic dimensions.
              width: 448,
              height: 360,
              child: Column(children: [
                TextField(
                    controller: search,
                    autofocus: true,
                    onChanged: (text) {
                      _run(text);
                    },
                    decoration: InputDecoration(
                        labelText: tr(
                            c, 'Search local foods', 'Pesquisar alimentos locais'),
                        prefixIcon: const Icon(Icons.search))),
                if (searching) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Expanded(
                    child: results.isEmpty
                        ? Center(
                            child: Text(hint ??
                                tr(
                                    c,
                                    'Type at least two characters to search.',
                                    'Escreve pelo menos dois caracteres para pesquisar.')))
                        : ListView.builder(
                            itemCount: results.length,
                            itemBuilder: (c, i) {
                              final food = results[i];
                              return ListTile(
                                  title: Text(food.name),
                                  subtitle: Text(
                                      '${food.source.dataset} · ${food.basisValue} ${food.basisUnit.name}'),
                                  onTap: () => Navigator.pop(c, food));
                            })),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(c, 'Cancel', 'Cancelar')))
          ]);
}

/// Collects an explicit amount in a unit the replacement food declares.
class _SubstitutionAmountDialog extends StatefulWidget {
  const _SubstitutionAmountDialog(
      {required this.food, required this.units, this.initial});
  final Food food;
  final Set<FoodUnit> units;
  final FoodAmount? initial;
  @override
  State<_SubstitutionAmountDialog> createState() =>
      _SubstitutionAmountDialogState();
}

class _SubstitutionAmountDialogState extends State<_SubstitutionAmountDialog> {
  late FoodUnit unit;
  late final TextEditingController text;
  String? error;
  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final usable = initial != null &&
        widget.units.contains(initial.unit) &&
        initial.value.positive;
    unit = usable ? initial.unit : widget.food.basisUnit;
    text = TextEditingController(
        text:
            usable ? initial.value.toString() : widget.food.basisValue.trim());
  }

  @override
  void dispose() {
    text.dispose();
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
                    labelText: tr(c, 'Replacement amount (${unit.name})',
                        'Quantidade substituta (${unit.name})'),
                    errorText: error)),
            DropdownButton<FoodUnit>(
                value: unit,
                isExpanded: true,
                items: [
                  for (final u in widget.units)
                    DropdownMenuItem(value: u, child: Text(u.name))
                ],
                onChanged: (u) => setState(() => unit = u!)),
            Text(tr(
                c,
                'Only units this food declares a conversion for are accepted. Nothing is recorded until you review and confirm.',
                'Só são aceites unidades com conversão declarada por este alimento. Nada é registado até reveres e confirmares.')),
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(c, 'Cancel', 'Cancelar'))),
            FilledButton(
                onPressed: () => submit(c),
                child: Text(tr(c, 'Continue', 'Continuar')))
          ]);

  void submit(BuildContext c) {
    try {
      final value = Exact.parse(text.text.trim().replaceAll(',', '.'));
      if (!value.positive) throw ArgumentError('Positive amount required');
      final amount = FoodAmount.exact(value, unit,
          measureId: unit == FoodUnit.item
              ? 'piece'
              : unit == FoodUnit.serving
                  ? 'serving'
                  : null);
      // Refuse before leaving the dialog when the food declares no conversion.
      resolveFoodAmount(widget.food, amount);
      Navigator.pop(c, amount);
    } catch (_) {
      setState(() => error = tr(
          c,
          'Enter a positive amount this food can convert',
          'Introduz uma quantidade positiva convertível por este alimento'));
    }
  }
}

class _AdditionalNutrients extends StatelessWidget {
  const _AdditionalNutrients(
      {required this.entries, required this.hideCalories});
  final List<LoggedEntry> entries;
  final bool hideCalories;

  @override
  Widget build(BuildContext context) {
    final totals = NutrientProfile.combine(
        entries.expand((entry) => entry.items.map((item) => item.nutrients)));
    const primary = {
      NutrientKey.energyKcal,
      NutrientKey.proteinG,
      NutrientKey.carbohydrateG,
      NutrientKey.fatG,
      NutrientKey.fiberG,
    };
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final key in NutrientKey.values)
            if (!primary.contains(key) &&
                !(hideCalories && key == NutrientKey.energyKj))
              _NutrientRow(keyValue: key, entries: entries, totals: totals),
        ]);
  }
}

class _NutrientRow extends StatelessWidget {
  const _NutrientRow(
      {required this.keyValue, required this.entries, this.totals});
  final NutrientKey keyValue;
  final List<LoggedEntry> entries;
  final Map<NutrientKey, NutrientSum>? totals;
  @override
  Widget build(BuildContext c) {
    final sums = totals ??
        NutrientProfile.combine(
            entries.expand((e) => e.items.map((i) => i.nutrients)));
    final sum = sums[keyValue];
    final value = sum?.recordedValue;
    final label = switch (keyValue) {
      NutrientKey.energyKcal => tr(c, 'Energy', 'Energia'),
      NutrientKey.proteinG => tr(c, 'Protein', 'Proteína'),
      NutrientKey.carbohydrateG => tr(c, 'Carbohydrate', 'Hidratos de carbono'),
      NutrientKey.fatG => tr(c, 'Fat', 'Lípidos'),
      NutrientKey.fiberG => tr(c, 'Fibre', 'Fibra'),
      _ => nutrientLabel(c, keyValue.wire)
    };
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Wrap(spacing: 12, children: [
          Text(label),
          Text(value == null
              ? '-- ${keyValue.unit}'
              : '${number(value)} ${keyValue.unit}'),
          if (value != null && !sum!.isComplete)
            Text(tr(c, 'partial record', 'registo parcial')),
          if (sum?.includesEstimate == true)
            Text(tr(c, 'estimated', 'estimado'))
        ]));
  }
}
