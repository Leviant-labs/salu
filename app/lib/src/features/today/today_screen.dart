import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../intake_moment.dart';
import '../../providers.dart';
import '../../ui_support.dart';

class TodayScreen extends ConsumerWidget {
  const TodayScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(todayEntriesProvider);
    final date = ref.watch(todayDiaryDateProvider);
    final support = ref.watch(settingsProvider)['support'] == true;
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
                                NutrientKey.energyKcal,
                                NutrientKey.proteinG,
                                NutrientKey.carbohydrateG,
                                NutrientKey.fatG,
                                NutrientKey.fiberG
                              ])
                                _NutrientRow(keyValue: key, entries: list),
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
                    title: Text(entry.items.map((i) => i.name).join(', ')),
                    subtitle: Text(entry.items
                        .map((i) => i.quantity != null
                            ? '${number(i.quantity!.value.toDouble())} ${i.quantity!.unit.name}${i.sourceSnapshot?['quantityBasis'] == 'raw-edible-ingredient-allocation' ? tr(context, ' (ingredient allocation)', ' (quantidade do ingrediente)') : ''}'
                            : i.grams == null
                                ? tr(context, 'Equal recipe serving',
                                    'Porção igual da receita')
                                : '${number(i.grams!)} g')
                        .join(' · ')),
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
                  onPressed: () => _checkIn(context, ref, date)),
              OutlinedButton.icon(
                  icon: const Icon(Icons.water_drop_outlined),
                  label: Text(tr(context, 'Record water', 'Registar água')),
                  onPressed: () => _record(context, ref, 'water', 'ml')),
              if (!support)
                OutlinedButton.icon(
                    icon: const Icon(Icons.monitor_weight_outlined),
                    label: Text(tr(context, 'Record weight', 'Registar peso')),
                    onPressed: () => _record(context, ref, 'weight', 'kg')),
            ]));
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
      } else if (action == 'copy') {
        if (entry.items.any((i) => i.sourceSnapshot?['batchId'] != null)) {
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
        Exact? factor;
        if (action == 'edit') {
          final text = await askText(context,
              title: tr(context, 'Quantity multiplier',
                  'Multiplicador da quantidade'),
              initial: '1');
          if (text == null) return;
          factor = Exact.parse(text.replaceAll(',', '.'));
        } else {
          if (!await confirmAction(
              context,
              tr(context, 'Delete entry?', 'Eliminar registo?'),
              tr(
                  context,
                  'The current diary entry will be removed. Revision history remains in your local archive.',
                  'O registo será removido do diário. O histórico de revisões permanece no arquivo local.'))) {
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
            multiplier: factor,
            delete: action == 'delete'));
      }
      ref.invalidate(todayEntriesProvider);
      ref.invalidate(recentFoodsProvider);
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
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
      if (context.mounted) showFailure(context, e);
    }
  }

  Future<void> _checkIn(
      BuildContext context, WidgetRef ref, DiaryDate date) async {
    try {
      final w = LocalWorkspace(ref.read(databaseProvider));
      final days = <CoachingDay>[];
      final entries = <LoggedEntry>[];
      for (var i = 6; i >= 0; i--) {
        final d = DateTime.utc(date.year, date.month, date.day)
            .subtract(Duration(days: i));
        final diaryDate = DiaryDate(d.year, d.month, d.day);
        final key = diaryDate.toIso();
        entries.addAll(
            await ref.read(entryRepositoryProvider).entriesFor(diaryDate));
        final record = await w.read('day', key);
        if (record == null) continue;
        days.add(CoachingDay(
            date: key,
            revision: record.revision,
            completeness: DiaryCompleteness.values
                .byName(record.data['completeness'] as String? ?? 'unknown')));
      }
      final profile = await w.read('profile', 'safety');
      final showWeight = ref.read(settingsProvider)['support'] != true;
      final weights = showWeight ? await w.list('weight') : <StoredDocument>[];
      final result = const CoachingService().checkIn(
          profile == null
              ? const SafetyProfile()
              : SafetyProfile.fromJson(profile.data),
          days,
          window: CoachingWindow(date.addDays(-6), date),
          entries: entries,
          weights: [
            for (final weight in weights)
              if (weight.data['offsetMinutes'] is int)
                CoachingWeight(
                  id: weight.id,
                  revision: weight.revision,
                  stamp: EventStamp(
                      instant: DateTime.parse(weight.data['time']! as String),
                      offsetMinutes: weight.data['offsetMinutes']! as int),
                  kilograms: Exact.fromJson(
                      Map<String, Object?>.from(weight.data['value']! as Map)),
                )
          ]);
      await w.reward('checkin:${date.toIso()}');
      if (!context.mounted) return;
      await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
                  title: Text(tr(c, 'Weekly check-in', 'Balanço semanal')),
                  content: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(tr(
                            c,
                            'Adaptation is disabled. Targets remain under your control.',
                            'A adaptação está desativada. As metas continuam sob o teu controlo.')),
                        for (final finding in result.findings)
                          Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text(switch (finding.action) {
                                CoachingAction.seekAdvice => tr(
                                    c,
                                    'Your declarations call for qualified advice. Automatic energy advice is suspended.',
                                    'As tuas declarações justificam aconselhamento qualificado. O aconselhamento energético automático está suspenso.'),
                                CoachingAction.improveData => tr(
                                    c,
                                    'Some days are incomplete or unknown. Complete a record, mark an estimate explicitly, or take a logging break. Missing days are never counted as zero.',
                                    'Alguns dias estão incompletos ou são desconhecidos. Completa um registo, identifica as estimativas ou faz uma pausa. Dias em falta nunca contam como zero.'),
                                _ => tr(
                                    c,
                                    'Your day records are declared complete. You can keep your current approach without changing targets. This does not establish nutritional adequacy.',
                                    'Os dias estão declarados completos. Podes manter a abordagem sem alterar metas. Isto não estabelece adequação nutricional.')
                              })),
                        const SizedBox(height: 16),
                        Text(
                            '${result.window!.start.toIso()} — ${result.window!.end.toIso()}'),
                        Text(tr(
                            c,
                            '${result.quality.completeDays} days declared complete; ${result.quality.confirmedNoIntakeDays} declared no intake; ${result.quality.partialDays + result.quality.unknownDays + result.quality.missingDates.length} incomplete or not declared.',
                            '${result.quality.completeDays} dias declarados completos; ${result.quality.confirmedNoIntakeDays} declarados sem ingestão; ${result.quality.partialDays + result.quality.unknownDays + result.quality.missingDates.length} incompletos ou não declarados.')),
                        if (result.fibreCoverage case final coverage?) ...[
                          const SizedBox(height: 16),
                          Text(tr(
                              c,
                              'Fibre in recorded items: ${coverage.reported} reported, ${coverage.estimated} estimated, ${coverage.trace} trace, ${coverage.unknown} unknown. Missing food and nutrient values do not count as zero; this does not assess adequacy.',
                              'Fibra nos alimentos registados: ${coverage.reported} declarados, ${coverage.estimated} estimados, ${coverage.trace} vestígios, ${coverage.unknown} desconhecidos. Alimentos e valores em falta não contam como zero; isto não avalia a adequação.')),
                        ],
                        if (showWeight && result.weightObservation != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(result.weightObservation!.changeKg
                                        .compareTo(Exact.zero) ==
                                    0
                                ? tr(
                                    c,
                                    'The first and last recorded weights in this window are equal.',
                                    'O primeiro e o último peso registados neste período são iguais.')
                                : result.weightObservation!.changeKg.positive
                                    ? tr(
                                        c,
                                        'The last recorded weight in this window is higher than the first.',
                                        'O último peso registado neste período é superior ao primeiro.')
                                    : tr(
                                        c,
                                        'The last recorded weight in this window is lower than the first.',
                                        'O último peso registado neste período é inferior ao primeiro.')),
                          ),
                        if (showWeight && result.weightObservation != null)
                          Text(tr(
                              c,
                              'Scale readings can fluctuate; this comparison does not measure fat change or establish its cause.',
                              'O peso pode variar; esta comparação não mede alterações de gordura nem estabelece a sua causa.')),
                        if (showWeight &&
                            result.weightObservation == null &&
                            result.weightInputRevisions.isNotEmpty)
                          Text(tr(
                              c,
                              'There are not enough distinct, ordered weight readings to compare in this period.',
                              'Não há registos de peso suficientes, distintos e ordenados, para comparar neste período.')),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: Text(tr(c, 'Close', 'Fechar')))
                  ]));
    } catch (e) {
      if (context.mounted) showFailure(context, e);
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

class _NutrientRow extends StatelessWidget {
  const _NutrientRow({required this.keyValue, required this.entries});
  final NutrientKey keyValue;
  final List<LoggedEntry> entries;
  @override
  Widget build(BuildContext c) {
    final sums = NutrientProfile.combine(
        entries.expand((e) => e.items.map((i) => i.nutrients)));
    final sum = sums[keyValue];
    final value = sum?.recordedValue;
    final label = switch (keyValue) {
      NutrientKey.energyKcal => tr(c, 'Energy', 'Energia'),
      NutrientKey.proteinG => tr(c, 'Protein', 'Proteína'),
      NutrientKey.carbohydrateG => tr(c, 'Carbohydrate', 'Hidratos de carbono'),
      NutrientKey.fatG => tr(c, 'Fat', 'Lípidos'),
      NutrientKey.fiberG => tr(c, 'Fibre', 'Fibra'),
      _ => keyValue.wire
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
