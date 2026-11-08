import 'package:flutter/material.dart';
import 'package:salu_core/salu_core.dart';
import 'ui_support.dart';

/// Explicit civil time, recorded offset and assigned diary day are independent.
final class IntakeMomentInput {
  IntakeMomentInput(this.initialStamp, DiaryDate day) {
    final wall = initialStamp.localWallTime;
    date.text = DiaryDate.ofLocal(wall).toIso();
    time.text =
        '${wall.hour.toString().padLeft(2, '0')}:${wall.minute.toString().padLeft(2, '0')}';
    offset.text = '${initialStamp.offsetMinutes}';
    diary.text = day.toIso();
    originalTime = time.text;
    originalDate = date.text;
  }
  final EventStamp initialStamp;
  final date = TextEditingController(),
      time = TextEditingController(),
      offset = TextEditingController(),
      diary = TextEditingController();
  late final String originalTime, originalDate;
  DiaryDate get diaryDate => DiaryDate.parse(diary.text.trim());
  EventStamp get stamp {
    final day = DiaryDate.parse(date.text.trim());
    final parts = time.text.trim().split(':');
    if (parts.length != 2) throw const FormatException('Use HH:mm');
    final hour = int.parse(parts[0]), minute = int.parse(parts[1]);
    final minutes = int.parse(offset.text.trim());
    if (hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59 ||
        minutes.abs() > 840) {
      throw const FormatException('Invalid time or UTC offset');
    }
    if (date.text == originalDate &&
        time.text == originalTime &&
        minutes == initialStamp.offsetMinutes) {
      return initialStamp;
    }
    return EventStamp(
        instant: DateTime.utc(day.year, day.month, day.day, hour, minute)
            .subtract(Duration(minutes: minutes)),
        offsetMinutes: minutes);
  }

  Widget fields(BuildContext c) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
            controller: date,
            decoration: InputDecoration(
                labelText: tr(c, 'Consumed date (YYYY-MM-DD)',
                    'Data de consumo (AAAA-MM-DD)'))),
        TextField(
            controller: time,
            decoration: InputDecoration(
                labelText: tr(c, 'Local time (HH:mm)', 'Hora local (HH:mm)'))),
        TextField(
            controller: offset,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: InputDecoration(
                labelText:
                    tr(c, 'UTC offset in minutes', 'Desvio UTC em minutos'),
                helperText: tr(
                    c,
                    'Keep the offset where you ate; +60 means UTC+1.',
                    'Mantém o desvio do local de consumo; +60 significa UTC+1.'))),
        TextField(
            controller: diary,
            decoration: InputDecoration(
                labelText: tr(c, 'Diary day (YYYY-MM-DD)',
                    'Dia do diário (AAAA-MM-DD)'))),
      ]);
  void dispose() {
    date.dispose();
    time.dispose();
    offset.dispose();
    diary.dispose();
  }
}

typedef ReviewedIntakeMoment = ({
  EventStamp stamp,
  DiaryDate day,
  Exact multiplier
});

class IntakeMomentDialog extends StatefulWidget {
  const IntakeMomentDialog(
      {super.key,
      required this.stamp,
      required this.day,
      required this.title,
      this.includeMultiplier = false});
  final EventStamp stamp;
  final DiaryDate day;
  final String title;
  final bool includeMultiplier;
  @override
  State<IntakeMomentDialog> createState() => _IntakeMomentDialogState();
}

class _IntakeMomentDialogState extends State<IntakeMomentDialog> {
  late final moment = IntakeMomentInput(widget.stamp, widget.day);
  final factor = TextEditingController(text: '1');
  String? error;
  @override
  void dispose() {
    moment.dispose();
    factor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => AlertDialog(
          title: Text(widget.title),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (widget.includeMultiplier)
              TextField(
                  controller: factor,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: tr(c, 'Quantity multiplier',
                          'Multiplicador da quantidade'))),
            moment.fields(c),
            if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(c).colorScheme.error)),
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: Text(tr(c, 'Cancel', 'Cancelar'))),
            FilledButton(
                onPressed: () {
                  try {
                    final multiplier =
                        Exact.parse(factor.text.replaceAll(',', '.'));
                    if (!multiplier.positive) {
                      throw ArgumentError('Quantity must be positive');
                    }
                    final result = (
                      stamp: moment.stamp,
                      day: moment.diaryDate,
                      multiplier: multiplier
                    );
                    Navigator.pop(c, result);
                  } catch (_) {
                    setState(() => error = tr(
                        c,
                        'Check the date, time, UTC offset and positive quantity.',
                        'Verifica a data, a hora, o desvio UTC e a quantidade positiva.'));
                  }
                },
                child: Text(widget.includeMultiplier
                    ? tr(c, 'Confirm intake', 'Confirmar consumo')
                    : tr(c, 'Save correction', 'Guardar correção')))
          ]);
}
