import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';
import 'weight_visibility.dart';

/// Reads one stored weight document without repairing or guessing fields.
CoachingWeight _readingFrom(StoredDocument document) {
  final data = document.data;
  final time = data['time'];
  final offset = data['offsetMinutes'];
  final value = data['value'];
  if (time is! String ||
      offset is! int ||
      value is! Map ||
      data['unit'] != 'kg') {
    throw const FormatException('Unreadable weight reading');
  }
  final kilograms =
      Exact.fromJson(Map<String, Object?>.from(value));
  return CoachingWeight(
      id: document.id,
      revision: document.revision,
      stamp: EventStamp(
          instant: DateTime.parse(time), offsetMinutes: offset),
      kilograms: kilograms);
}

final class _WeightSnapshot {
  const _WeightSnapshot(this.log, this.unreadable);
  final WeightReadingLog log;

  /// Stored rows that could not be read. They are never repaired or guessed.
  final int unreadable;
}

/// Local civil time at the recording offset, including that offset because two
/// readings can share a wall clock yet come from different zones.
String _stampLabel(EventStamp stamp) {
  final wall = stamp.localWallTime;
  final hour = wall.hour.toString().padLeft(2, '0');
  final minute = wall.minute.toString().padLeft(2, '0');
  final sign = stamp.offsetMinutes < 0 ? '-' : '+';
  final absolute = stamp.offsetMinutes.abs();
  final offset =
      'UTC$sign${(absolute ~/ 60).toString().padLeft(2, '0')}:${(absolute % 60).toString().padLeft(2, '0')}';
  return '${DiaryDate.assign(stamp).toIso()} $hour:$minute ($offset)';
}

/// Weight-only evidence flow.
///
/// Shows recorded scale readings and, when the recorded times are distinct and
/// unambiguous, the endpoint difference. It never smooths, extrapolates, or
/// proposes a calorie/target change and makes no clinical claim. Read access is
/// local only: nothing is imported from or written to a platform health store.
class WeightLogScreen extends ConsumerStatefulWidget {
  const WeightLogScreen({super.key});
  @override
  ConsumerState<WeightLogScreen> createState() => _WeightLogScreenState();
}

class _WeightLogScreenState extends ConsumerState<WeightLogScreen> {
  final _input = TextEditingController();
  late Future<_WeightSnapshot> _snapshot;
  bool _saving = false;
  String? _inputError;

  @override
  void initState() {
    super.initState();
    _snapshot = _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<_WeightSnapshot> _load() async {
    final documents =
        await LocalWorkspace(ref.read(databaseProvider)).list('weight');
    final readings = <CoachingWeight>[];
    var unreadable = 0;
    for (final document in documents) {
      try {
        readings.add(_readingFrom(document));
      } catch (_) {
        unreadable++;
      }
    }
    return _WeightSnapshot(WeightReadingLog(readings), unreadable);
  }

  Future<void> _record() async {
    if (_saving) return;
    late final Exact kilograms;
    try {
      kilograms =
          Exact.parse(_input.text.trim().replaceAll(',', '.'));
      if (!kilograms.positive) {
        throw const FormatException('Weight must be positive');
      }
    } catch (_) {
      setState(() => _inputError = tr(
          context,
          'Enter a positive weight in kilograms, for example 72.4.',
          'Introduz um peso positivo em quilogramas, por exemplo 72,4.'));
      return;
    }
    setState(() {
      _saving = true;
      _inputError = null;
    });
    try {
      final id = ref.read(idGeneratorProvider).next();
      await LocalWorkspace(ref.read(databaseProvider)).put(
          requestId: id,
          collection: 'weight',
          id: id,
          expectedRevision: 0,
          data: {
            'value': kilograms.toJson(),
            'unit': 'kg',
            'time': ref.read(clockProvider).nowUtc().toIso8601String(),
            'offsetMinutes': currentOffsetMinutes(),
          });
      if (!mounted) return;
      _input.clear();
      final next = await _load();
      if (!mounted) return;
      setState(() => _snapshot = Future<_WeightSnapshot>.value(next));
    } catch (error) {
      if (!mounted) return;
      setState(() => _inputError = tr(
          context,
          'Could not record the reading: $error',
          'Não foi possível registar a leitura: $error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final hidden = hidesWeight(settings);
    return Scaffold(
        appBar: AppBar(
            title: Text(tr(context, 'Weight readings', 'Registos de peso'))),
        body: hidden
            ? Center(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(tr(
                        context,
                        'Weight is hidden while supportive mode or the weight-nudge preference is on.',
                        'O peso está oculto enquanto o modo de apoio ou a preferência de lembretes de peso estiver ativa.'))))
            : FutureBuilder<_WeightSnapshot>(
                future: _snapshot,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                        child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(tr(
                                      context,
                                      'Could not read recorded weight readings.',
                                      'Não foi possível ler os registos de peso.')),
                                  const SizedBox(height: 8),
                                  OutlinedButton(
                                      onPressed: () => setState(
                                          () => _snapshot = _load()),
                                      child: Text(tr(
                                          context, 'Try again', 'Tentar de novo')))
                                ])));
                  }
                  final data = snapshot.data;
                  if (data == null) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  return _body(context, data);
                }));
  }

  Widget _body(BuildContext context, _WeightSnapshot snapshot) {
    final log = snapshot.log;
    final observation = log.observation;
    final theme = Theme.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(context, 'What this list is', 'O que é esta lista'),
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(tr(
                        context,
                        'Recorded scale readings only. They are spot observations, not a trend, rate, plateau, fat-loss estimate, or cause. Recording a weight never changes calorie targets, proposes an intake change, or assesses a health condition.',
                        'Apenas leituras da balança. São observações pontuais, não uma tendência, ritmo, plateau, estimativa de perda de gordura ou causa. Registar um peso nunca altera metas calóricas, propõe alterações ao consumo ou avalia uma condição de saúde.')),
                  ]))),
      const SizedBox(height: 16),
      Text(tr(context, 'Record a reading', 'Registar uma leitura'),
          style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      TextField(
          controller: _input,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: tr(context, 'Weight (kg)', 'Peso (kg)'),
              errorText: _inputError,
              helperMaxLines: 3,
              helperText: tr(
                  context,
                  'Saved with the current time and UTC offset. Readings are append-only in this release; the app does not check whether a reading is plausible.',
                  'Guardado com a hora e o desvio UTC atuais. Os registos são apenas adicionados nesta versão; a aplicação não verifica se a leitura é plausível.'))),
      const SizedBox(height: 8),
      Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
              onPressed: _saving ? null : _record,
              child: Text(_saving
                  ? tr(context, 'Saving…', 'A guardar…')
                  : tr(context, 'Record reading', 'Registar leitura')))),
      const SizedBox(height: 24),
      if (log.isEmpty)
        Text(snapshot.unreadable > 0
            ? tr(
                context,
                'No readable weight readings are available on this device. Add one above when you weigh yourself.',
                'Não há registos de peso legíveis neste dispositivo. Adiciona um acima quando te pesares.')
            : tr(
                context,
                'No weight readings are recorded on this device. Add one above when you weigh yourself.',
                'Não há registos de peso neste dispositivo. Adiciona um acima quando te pesares.'))
      else if (observation != null) ...[
        Text(tr(context, 'Endpoint comparison', 'Comparação de extremos'),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(tr(
            context,
            '${observation.count} recorded reading(s). Earliest: ${observation.first.kilograms} kg on ${_stampLabel(observation.first.stamp)}. Latest: ${observation.last.kilograms} kg on ${_stampLabel(observation.last.stamp)}. Endpoint difference: ${observation.changeKg} kg. This compares only those two recorded endpoints across the locally stored readings; it is not a trend, rate, plateau, or fat-loss estimate.',
            '${observation.count} registo(s) de peso. Mais antigo: ${observation.first.kilograms} kg em ${_stampLabel(observation.first.stamp)}. Mais recente: ${observation.last.kilograms} kg em ${_stampLabel(observation.last.stamp)}. Diferença entre extremos: ${observation.changeKg} kg. Isto compara apenas esses dois extremos em todos os registos guardados localmente; não é uma tendência, ritmo, plateau ou estimativa de perda de gordura.')),
      ] else if (log.readings.length > 1)
        Text(log.ambiguousEndpoints
            ? tr(
                context,
                'More than one reading shares the earliest or latest recorded time. The app does not choose an order, so no endpoint comparison is calculated.',
                'Mais do que uma leitura partilha a hora mais antiga ou mais recente. A aplicação não escolhe uma ordem, por isso não é calculada qualquer comparação de extremos.')
            : tr(
                context,
                'The recorded readings do not have two distinct, unambiguous times, so no endpoint comparison is calculated.',
                'Os registos não têm duas horas distintas e inequívocas, por isso não é calculada qualquer comparação de extremos.'))
      else
        Text(tr(
            context,
            'One reading is recorded. A comparison requires at least two readings at different times.',
            'Há um registo. Uma comparação exige pelo menos dois registos em horas diferentes.')),
      if (snapshot.unreadable > 0) ...[
        const SizedBox(height: 8),
        Text(tr(
            context,
            '${snapshot.unreadable} stored reading(s) could not be read and are not shown.',
            '${snapshot.unreadable} registo(s) guardado(s) não puderam ser lidos e não são mostrados.'),
            style: theme.textTheme.bodySmall),
      ],
      if (!log.isEmpty) ...[
        const SizedBox(height: 24),
        Text(tr(context, 'Recorded readings (newest first)',
                'Registos (mais recentes primeiro)'),
            style: theme.textTheme.titleSmall),
      ],
      for (final reading in log.readings.reversed)
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.monitor_weight_outlined),
            title: Text('${reading.kilograms} kg'),
            subtitle: Text(_stampLabel(reading.stamp))),
      const SizedBox(height: 16),
      Text(tr(
          context,
          'Only readings stored on this device are shown. No platform health data is read, imported, or written from this screen.',
          'Apenas são mostrados os registos guardados neste dispositivo. Nenhum dado de saúde da plataforma é lido, importado ou escrito a partir deste ecrã.'),
          style: theme.textTheme.bodySmall),
    ]);
  }
}
