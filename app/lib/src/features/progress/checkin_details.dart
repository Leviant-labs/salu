import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import '../today/weight_visibility.dart';

String _coachingFindingMessage(BuildContext c, CoachingFinding finding) {
  final payload = finding.actionPayload;
  String value(String key) => '${payload[key] ?? ''}';
  return switch (finding.ruleId) {
    'safety-route' => tr(
        c,
        'Your declarations suggest considering qualified advice: ${value('reasons')}.',
        'As suas declarações sugerem procurar aconselhamento qualificado: ${value('reasons')}.'),
    'record-coverage' => tr(
        c,
        'Recording is incomplete for ${value('count')} day(s) in this check-in: ${value('dates')}. Unrecorded intake is unknown, not zero. Complete a record, estimate explicitly, or take a logging break. Missing days are never counted as zero.',
        'O registo está incompleto em ${value('count')} dia(s) deste balanço: ${value('dates')}. O consumo não registado é desconhecido, não é zero. Completa um registo, estima explicitamente ou faz uma pausa. Dias em falta nunca contam como zero.'),
    'hold-course' => tr(
        c,
        'All ${value('count')} considered day(s) are declared complete or confirmed no-intake. Hold the current approach; this check-in provides no reason to change targets.',
        'Todos os ${value('count')} dia(s) considerados estão declarados completos ou sem ingestão confirmada. Mantém a abordagem atual; este balanço não dá motivo para alterar metas.'),
    'weight-readings' => tr(
        c,
        '${value('count')} recorded weight reading(s), first on ${value('firstDate')} and last on ${value('lastDate')}, range from ${value('first')} kg to ${value('last')} kg (${value('change')} kg endpoint difference). No trend or plateau is computed.',
        '${value('count')} registo(s) de peso, o primeiro em ${value('firstDate')} e o último em ${value('lastDate')}, variam de ${value('first')} kg a ${value('last')} kg (diferença de ${value('change')} kg entre extremos). Não é calculada qualquer tendência ou plateau.'),
    'fibre-coverage' => tr(
        c,
        'Fibre values cover ${value('total')} recorded item snapshot(s): ${value('reported')} reported, ${value('estimated')} estimated, ${value('trace')} trace, ${value('unknown')} unknown. All recorded fibre states are explicit; no adequacy verdict is made.',
        'Os valores de fibra abrangem ${value('total')} registo(s) de itens: ${value('reported')} declarados, ${value('estimated')} estimados, ${value('trace')} vestígios, ${value('unknown')} desconhecidos. Todos os estados registados são explícitos; não é emitido veredicto de adequação.'),
    'fibre-coverage-gaps' => tr(
        c,
        'Fibre values are unknown for ${value('unknown')} of ${value('total')} recorded item snapshot(s): ${value('reported')} reported, ${value('estimated')} estimated, ${value('trace')} trace. A numeric total would be incomplete; no adequacy verdict is made.',
        'Os valores de fibra são desconhecidos em ${value('unknown')} de ${value('total')} registo(s) de itens: ${value('reported')} declarados, ${value('estimated')} estimados, ${value('trace')} vestígios. Um total numérico ficaria incompleto; não é emitido veredicto de adequação.'),
    'plan-recording' => tr(
        c,
        'The plan schedules ${value('slots')} meal slot(s) across ${value('days')} day(s); ${value('entries')} separate plan-origin intake record(s) fall on those dates.',
        'O plano agenda ${value('slots')} espaço(s) de refeição em ${value('days')} dia(s); ${value('entries')} registo(s) de consumo separados com origem no plano coincidem nessas datas.'),
    'plan-recording-gaps' => tr(
        c,
        'The plan schedules ${value('slots')} meal slot(s) across ${value('days')} day(s), with ${value('entries')} separate plan-origin intake record(s) on those dates. If you want plan follow-through in the check-in, confirm consumed plan meals separately; skipping a planned meal is not a failure.',
        'O plano agenda ${value('slots')} espaço(s) de refeição em ${value('days')} dia(s), com ${value('entries')} registo(s) de consumo separados com origem no plano nessas datas. Se quiseres acompanhar o plano no balanço, confirma separadamente as refeições planeadas consumidas; não comer uma refeição planeada não é uma falha.'),
    _ => finding.message,
  };
}

String _coachingCaveat(BuildContext c, CoachingCaveat caveat) =>
    switch (caveat) {
      CoachingCaveat.unrecordedUnknown => tr(
          c,
          'Unrecorded intake is unknown and is never counted as zero or estimated here.',
          'O consumo não registado é desconhecido e nunca é contado como zero nem estimado aqui.'),
      CoachingCaveat.declarationsNotAdequacy => tr(
          c,
          'Day declarations describe recording, not nutritional adequacy, measured requirements, or progress.',
          'As declarações dos dias descrevem o registo, não a adequação nutricional, as necessidades medidas ou o progresso.'),
      CoachingCaveat.spotWeightsNotTrend => tr(
          c,
          'Scale readings are spot observations, not a smoothed trend, plateau, fat-loss estimate, or cause.',
          'As leituras da balança são observações pontuais, não uma tendência suavizada, plateau, estimativa de perda de gordura ou causa.'),
      CoachingCaveat.fibreCoverageNotAdequacy => tr(
          c,
          'Fibre coverage describes recorded item snapshots, not intake adequacy or a reference comparison.',
          'A cobertura de fibra descreve os registos de itens, não a adequação do consumo nem uma comparação com referências.'),
      CoachingCaveat.planNotIntake => tr(
          c,
          'A plan is organization only; planned meals are not intake and never write the diary.',
          'Um plano é apenas organização; as refeições planeadas não são consumo e nunca escrevem no diário.'),
      CoachingCaveat.backdatedPreserved => tr(
          c,
          'Backdated and revised records are used with their recorded diary dates and revisions.',
          'Os registos retroativos e revistos são usados com as datas de diário e revisões registadas.'),
      _ => caveat.message,
    };
String _coachingUnavailable(
        BuildContext c, CoachingUnavailableCheck check) =>
    switch (check.id) {
      'weight-trend' => tr(
          c,
          'Weight trend: no approved window or tolerance exists; only spot readings are reported.',
          'Tendência de peso: não existe janela ou tolerância aprovada; apenas são reportadas leituras pontuais.'),
      'possible-progress-plateau' => tr(
          c,
          'Possible plateau: no approved window or tolerance exists; spot readings cannot establish one.',
          'Possível plateau: não existe janela ou tolerância aprovada; leituras pontuais não o podem estabelecer.'),
      'nutrient-adequacy' => tr(
          c,
          'Nutrient adequacy: approved references and population matching are required; only recorded coverage is reported.',
          'Adequação nutricional: são necessárias referências aprovadas e correspondência populacional; apenas é reportada a cobertura registada.'),
      'plan-adherence' => tr(
          c,
          'Plan adherence: confirmation links per slot are required; only date-level counts are reported.',
          'Aderência ao plano: são necessárias ligações de confirmação por espaço; apenas são reportadas contagens por data.'),
      'notification-cooldown' => tr(
          c,
          'Notification and cooldown timing require approved policy; this check-in schedules no notification.',
          'O momento das notificações e do intervalo mínimo exige uma política aprovada; este balanço não agenda notificações.'),
      _ => check.reason,
    };

/// Expandable technical evidence for one weekly check-in.
///
/// The primary weekly check-in is short meal feedback; this is the
/// expandable evidence surface. Progress and Diary invoke it through
/// [showCheckInDetails].
class CheckinDetails extends ConsumerWidget {
  const CheckinDetails({super.key, required this.date});

  final DiaryDate date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<CheckInResult>(
      future: _run(context, ref, date),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('${snapshot.error}'));
        }
        final result = snapshot.data!;
        return _DetailsBody(result: result, showWeight: _showWeight(ref));
      },
    );
  }

  bool _showWeight(WidgetRef ref) => !hidesWeight(ref.read(settingsProvider));

  Future<CheckInResult> _run(
      BuildContext context, WidgetRef ref, DiaryDate date) async {
    final w = LocalWorkspace(ref.read(databaseProvider));
    final window = CoachingWindow(date.addDays(-6), date);
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
      final declared = record.data['completeness'];
      days.add(CoachingDay(
          date: key,
          revision: record.revision,
          completeness: declared is String
              ? enumByWire(DiaryCompleteness.values, declared,
                  DiaryCompleteness.unknown)
              : DiaryCompleteness.unknown));
    }
    // Plan evidence reads every plan document intersecting the window,
    // deduplicated by document id plus slot id.
    final plannedSlots = <CoachingPlanSlot>[];
    final seen = <String>{};
    for (final doc in await w.list('plan')) {
      final schedule = PlanSchedule.fromMetadata(doc.data['schedule']);
      if (schedule == null) continue;
      for (final slot in schedule.slots) {
        final key = slot.date;
        if (!window.dates.contains(key)) continue;
        if (!seen.add('${doc.id}|${slot.id}')) continue;
        plannedSlots.add(CoachingPlanSlot(
            slotId: slot.id, date: key, revision: doc.revision));
      }
    }
    final profile = await w.read('profile', 'safety');
    final showWeight = _showWeight(ref);
    final weights = showWeight ? await w.list('weight') : <StoredDocument>[];
    final result = const CoachingService().checkIn(
        profile == null
            ? const SafetyProfile()
            : SafetyProfile.fromJson(profile.data),
        days,
        window: window,
        entries: entries,
        plannedSlots: plannedSlots,
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
    return result;
  }
}

class _DetailsBody extends StatelessWidget {
  const _DetailsBody({required this.result, required this.showWeight});
  final CheckInResult result;
  final bool showWeight;

  @override
  Widget build(BuildContext context) {
    final unavailableChecks = showWeight
        ? result.unavailableChecks
        : [
            for (final check in result.unavailableChecks)
              if (check.id != 'weight-trend' &&
                  check.id != 'possible-progress-plateau')
                check
          ];
    final findings = showWeight
        ? result.findings
        : [
            for (final finding in result.findings)
              if (finding.ruleId != 'weight-readings') finding
          ];
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (final finding in findings)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_coachingFindingMessage(context, finding)),
                  const SizedBox(height: 4),
                  Text(
                      tr(
                          context,
                          'Evidence: ${finding.window.start?.toIso() ?? '–'} to ${finding.window.end?.toIso() ?? '–'}; ${finding.evaluatedDates.length} evaluated date(s); ${finding.inputRevisions.length} input revision(s). Rule ${finding.ruleIdentity}.',
                          'Evidência: ${finding.window.start?.toIso() ?? '–'} a ${finding.window.end?.toIso() ?? '–'}; ${finding.evaluatedDates.length} data(s) avaliada(s); ${finding.inputRevisions.length} revisão(ões) de entrada. Regra ${finding.ruleIdentity}.'),
                      style: Theme.of(context).textTheme.bodySmall),
                  if (finding.caveats.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                            tr(context, 'Caveats', 'Ressalvas'),
                            style: Theme.of(context).textTheme.labelSmall)),
                  for (final caveat in finding.caveats)
                    Text('• ${_coachingCaveat(context, caveat)}',
                        style: Theme.of(context).textTheme.bodySmall)
                ])),
      const SizedBox(height: 16),
      Text(
          '${result.window!.start.toIso()} — ${result.window!.end.toIso()}'),
      Text(tr(
          context,
          '${result.quality.completeDays} days declared complete; ${result.quality.confirmedNoIntakeDays} declared no intake; ${result.quality.partialDays + result.quality.unknownDays + result.quality.missingDates.length} incomplete or not declared.',
          '${result.quality.completeDays} dias declarados completos; ${result.quality.confirmedNoIntakeDays} declarados sem ingestão; ${result.quality.partialDays + result.quality.unknownDays + result.quality.missingDates.length} incompletos ou não declarados.')),
      if (result.quality.missingDates.isNotEmpty)
        Text(tr(
            context,
            'Dates without a day declaration: ${result.quality.missingDates.join(', ')}. Their intake remains unknown.',
            'Datas sem declaração do dia: ${result.quality.missingDates.join(', ')}. O consumo dessas datas permanece desconhecido.')),
      if (result.planInputRevisions.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(tr(
            context,
            'Plan evidence: ${result.planInputRevisions.length} scheduled slot(s) come from stored plan revision(s) ${(result.planInputRevisions.values.toSet().toList()..sort()).join(', ')}. A plan is never treated as intake, and matching is by diary date only.',
            'Evidência do plano: ${result.planInputRevisions.length} espaço(s) planeado(s) vêm da(s) revisão(ões) guardada(s) do plano ${(result.planInputRevisions.values.toSet().toList()..sort()).join(', ')}. Um plano nunca é tratado como consumo, e a correspondência é apenas por data do diário.')),
      ],
      if (result.fibreCoverage case final coverage?) ...[
        const SizedBox(height: 16),
        Text(tr(
            context,
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
                  context,
                  'The first and last recorded weights in this window are equal.',
                  'O primeiro e o último peso registados neste período são iguais.')
              : result.weightObservation!.changeKg.positive
                  ? tr(
                      context,
                      'The last recorded weight in this window is higher than the first.',
                      'O último peso registado neste período é superior ao primeiro.')
                  : tr(
                      context,
                      'The last recorded weight in this window is lower than the first.',
                      'O último peso registado neste período é inferior ao primeiro.')),
        ),
      if (showWeight && result.weightObservation != null)
        Text(tr(
            context,
            'Scale readings can fluctuate; this comparison does not measure fat change or establish its cause.',
            'O peso pode variar; esta comparação não mede alterações de gordura nem estabelece a sua causa.')),
      if (showWeight &&
          result.weightObservation == null &&
          result.weightInputRevisions.isNotEmpty)
        Text(tr(
            context,
            'There are not enough distinct, ordered weight readings to compare in this period.',
            'Não há registos de peso suficientes, distintos e ordenados, para comparar neste período.')),
      if (unavailableChecks.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
            tr(context, 'Not computed in this release',
                'Não calculado nesta versão'),
            style: Theme.of(context).textTheme.titleSmall),
        for (final check in unavailableChecks)
          Text('• ${_coachingUnavailable(context, check)}',
              style: Theme.of(context).textTheme.bodySmall),
      ],
    ]);
  }
}

/// Opens the expandable check-in evidence dialog used by Diary and Progress.
Future<void> showCheckInDetails(
    BuildContext context, WidgetRef ref, DiaryDate date) async {
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(tr(context, 'Weekly check-in', 'Balanço semanal')),
      content: SizedBox(
        width: 560,
        height: 480,
        child: CheckinDetails(date: date),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr(context, 'Close', 'Fechar'))),
      ],
    ),
  );
}
