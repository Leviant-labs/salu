import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';

/// One cosmetic that can be worn by the local companion.
///
/// [requiredKind] is an allowed reward event kind; null means the item uses
/// the total number of allowed reward events instead. No intake, weight or
/// fasting goal exists here, and a missed day never removes or downgrades an
/// earned item because reward rows are immutable and additive.
final class RewardCosmetic {
  const RewardCosmetic(this.id, this.icon,
      {this.requiredKind, this.requiredCount = 0});
  final String id;
  final IconData icon;
  final String? requiredKind;
  final int requiredCount;
}

const rewardCosmetics = <RewardCosmetic>[
  RewardCosmetic('everyday', Icons.pets),
  RewardCosmetic('engagement-bell', Icons.notifications_active_outlined,
      requiredKind: 'engagement', requiredCount: 1),
  RewardCosmetic('planning-apron', Icons.checkroom,
      requiredKind: 'planning', requiredCount: 1),
  RewardCosmetic('checkin-badge', Icons.verified_outlined,
      requiredKind: 'checkin', requiredCount: 1),
  RewardCosmetic('review-scarf', Icons.local_florist_outlined,
      requiredKind: 'day-review', requiredCount: 1),
  RewardCosmetic('learning-cap', Icons.school_outlined,
      requiredKind: 'learning', requiredCount: 1),
  RewardCosmetic('returning-star', Icons.auto_awesome,
      requiredKind: 'return', requiredCount: 1),
  RewardCosmetic('celebration', Icons.celebration_outlined,
      requiredCount: 5),
];

String _cosmeticName(BuildContext c, String id) => switch (id) {
      'engagement-bell' =>
        tr(c, 'Engagement bell', 'Sino de participação'),
      'planning-apron' => tr(c, 'Planning apron', 'Avental de planeamento'),
      'checkin-badge' => tr(c, 'Check-in badge', 'Distintivo de balanço'),
      'review-scarf' => tr(c, 'Review scarf', 'Lenço de revisão'),
      'learning-cap' => tr(c, 'Learning cap', 'Boné de aprendizagem'),
      'returning-star' =>
        tr(c, 'Returning star', 'Estrela de regresso'),
      'celebration' => tr(c, 'Celebration', 'Celebração'),
      _ => tr(c, 'Everyday companion', 'Companheiro de todos os dias'),
    };

String _requirement(BuildContext c, RewardCosmetic cosmetic) {
  if (cosmetic.requiredKind != null) {
    final label = switch (cosmetic.requiredKind) {
      'engagement' => tr(c, 'an engagement reward', 'uma recompensa de participação'),
      'planning' => tr(c, 'a planning reward', 'uma recompensa de planeamento'),
      'checkin' => tr(c, 'a check-in reward', 'uma recompensa de balanço'),
      'day-review' => tr(c, 'a daily-review reward', 'uma recompensa de revisão diária'),
      'learning' => tr(c, 'a learning reward', 'uma recompensa de aprendizagem'),
      'return' => tr(c, 'a returning-after-a-break reward',
          'uma recompensa de regresso após uma pausa'),
      _ => cosmetic.requiredKind!,
    };
    return tr(c, 'Earn by recording $label.',
        'Ganha ao registar $label.');
  }
  if (cosmetic.requiredCount > 0) {
    return tr(
        c,
        'Earn with any ${cosmetic.requiredCount} allowed engagement reward events.',
        'Ganha com quaisquer ${cosmetic.requiredCount} eventos de recompensa de participação permitidos.');
  }
  return tr(c, 'Available at any time.', 'Disponível a qualquer momento.');
}

/// Lists earned companion cosmetics and stores only the selected cosmetic in
/// the existing `preferences/app` document. Availability is derived solely
/// from immutable allowed reward events.
class RewardsScreen extends ConsumerStatefulWidget {
  const RewardsScreen({super.key});
  @override
  ConsumerState<RewardsScreen> createState() => _RewardsState();
}

class _RewardsState extends ConsumerState<RewardsScreen> {
  Map<String, int> counts = const {};
  String selectedId = 'everyday';
  bool loaded = false;

  LocalWorkspace get store => LocalWorkspace(ref.read(databaseProvider));

  static String? _allowedKind(String eventId) {
    final separator = eventId.indexOf(':');
    final kind = separator == -1 ? eventId : eventId.substring(0, separator);
    final subject = separator == -1 ? null : eventId.substring(separator + 1);
    if (!rewardEventKinds.contains(kind)) return null;
    if (subject != null &&
        (subject.isEmpty ||
            subject.trim() != subject ||
            subject.contains(':'))) {
      return null;
    }
    return kind;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rewards = await store.list('reward');
      final next = <String, int>{};
      for (final reward in rewards) {
        final kind = _allowedKind(reward.id);
        if (kind == null) continue;
        next[kind] = (next[kind] ?? 0) + 1;
      }
      final preferences = await store.read('preferences', 'app');
      final saved = preferences?.data['rewardCosmetic'];
      final selected = saved is String && _knownCosmetic(saved)
          ? saved
          : 'everyday';
      if (!mounted) return;
      setState(() {
        counts = next;
        selectedId = selected;
        loaded = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() => loaded = true);
        showFailure(context, e);
      }
    }
  }

  static bool _knownCosmetic(String id) =>
      rewardCosmetics.any((cosmetic) => cosmetic.id == id);

  RewardCosmetic _cosmetic(String id) =>
      rewardCosmetics.firstWhere((cosmetic) => cosmetic.id == id);

  int get _totalAllowed => counts.values.fold(0, (sum, value) => sum + value);

  bool _earned(RewardCosmetic cosmetic) {
    if (cosmetic.requiredKind == null) {
      return _totalAllowed >= cosmetic.requiredCount;
    }
    return (counts[cosmetic.requiredKind] ?? 0) >= cosmetic.requiredCount;
  }

  Future<void> _select(RewardCosmetic cosmetic) async {
    if (!_earned(cosmetic)) return;
    try {
      final previous = await store.read('preferences', 'app');
      await store.put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'preferences',
          id: 'app',
          expectedRevision: previous?.revision ?? 0,
          data: {...?previous?.data, 'rewardCosmetic': cosmetic.id});
      // Keep the shared settings snapshot in sync so later preference writes
      // cannot drop the cosmetic selection.
      await ref.read(settingsProvider.notifier).reload();
      if (!mounted) return;
      setState(() => selectedId = cosmetic.id);
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  Future<void> _award(String eventId) async {
    try {
      await store.reward(eventId);
      await _load();
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  bool _recorded(String kind) => (counts[kind] ?? 0) > 0;

  @override
  Widget build(BuildContext c) {
    if (!loaded) return const Center(child: CircularProgressIndicator());
    final selected = _cosmetic(selectedId);
    final active = _earned(selected) ? selected : _cosmetic('everyday');
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(tr(c, 'Rewards', 'Recompensas'),
          style: Theme.of(c).textTheme.headlineSmall),
      const SizedBox(height: 8),
      Semantics(
          container: true,
          label: tr(
              c,
              'Companion wearing ${_cosmeticName(c, active.id)}',
              'Companheiro com ${_cosmeticName(c, active.id)}'),
          child: Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    Icon(active.icon, size: 64),
                    const SizedBox(height: 8),
                    Text(_cosmeticName(c, active.id),
                        style: Theme.of(c).textTheme.titleMedium),
                    if (!_earned(selected))
                      Text(
                          tr(
                              c,
                              'Your saved cosmetic is not available from current reward records.',
                              'A tua decoração guardada não está disponível nos registos de recompensas atuais.'),
                          style: Theme.of(c).textTheme.bodySmall)
                  ])))),
      const SizedBox(height: 12),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr(c, 'How rewards work', 'Como funcionam as recompensas'),
                        style: Theme.of(c).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(tr(
                        c,
                        'Cosmetics come from engagement, planning, learning, returning after breaks, daily reviews and check-ins.',
                        'As decorações vêm da participação, do planeamento, da aprendizagem, do regresso após pausas, das revisões diárias e dos balanços.')),
                    const SizedBox(height: 4),
                    Text(tr(
                        c,
                        'No missed day, streak, intake, weight or fasting outcome removes or lowers a cosmetic. Rewards are additive and there are no penalties.',
                        'Nenhum dia em falta, sequência, consumo, peso ou jejum remove ou reduz uma decoração. As recompensas são aditivas e não há penalizações.'))
                  ]))),
      const SizedBox(height: 12),
      Text(tr(c, 'Earn more cosmetics', 'Ganha mais decorações'),
          style: Theme.of(c).textTheme.titleMedium),
      const SizedBox(height: 8),
      _actionCard(c,
          title: tr(c, 'Companion engagement', 'Participação com o companheiro'),
          body: tr(
              c,
              'Looking at your companion and choosing a cosmetic is optional engagement. No intake, weight or fasting record is needed or rewarded.',
              'Ver o teu companheiro e escolher uma decoração é participação opcional. Não é necessário nem é recompensado qualquer registo de consumo, peso ou jejum.'),
          button: tr(c, 'Acknowledge engagement', 'Assinalar participação'),
          eventId: 'engagement:companion-check-in'),
      _actionCard(c,
          title: tr(c, 'A short local note', 'Uma nota local breve'),
          body: tr(
              c,
              'A food record describes what you confirmed and the values available at that time. Missing or unknown values are not zero, and a record alone does not establish nutritional adequacy.',
              'Um registo alimentar descreve o que confirmaste e os valores disponíveis nesse momento. Valores em falta ou desconhecidos não são zero, e um registo por si só não estabelece adequação nutricional.'),
          button: tr(c, 'I have read this', 'Já li isto'),
          eventId: 'learning:record-reading-ack'),
      _actionCard(c,
          title: tr(c, 'Returning after a break',
              'Regressar após uma pausa'),
          body: tr(
              c,
              'You can return at any time. There is no minimum absence to meet, no streak to repair and no penalty. This acknowledgement is optional.',
              'Podes regressar a qualquer momento. Não há uma ausência mínima a cumprir, uma sequência a reparar ou uma penalização. Este reconhecimento é opcional.'),
          button: tr(c, 'I am returning after a break',
              'Estou a regressar após uma pausa'),
          eventId: 'return:voluntary-after-break'),
      const SizedBox(height: 12),
      Text(tr(c, 'Cosmetics', 'Decorações'),
          style: Theme.of(c).textTheme.titleMedium),
      const SizedBox(height: 8),
      for (final cosmetic in rewardCosmetics)
        _cosmeticTile(c, cosmetic, selectedId, _earned(cosmetic)),
      const SizedBox(height: 12),
      Text(
          tr(
              c,
              'Earned cosmetics stay available across missed days, retries and backup restoration. There are no intake, weight-loss or fasting targets here.',
              'As decorações ganhas permanecem disponíveis após dias em falta, tentativas e restauro de cópias. Não existem metas de consumo, perda de peso ou jejum.'),
          style: Theme.of(c).textTheme.bodySmall)
    ]);
  }

  Widget _actionCard(BuildContext c,
      {required String title,
      required String body,
      required String button,
      required String eventId}) {
    final kind = eventId.split(':').first;
    final recorded = _recorded(kind);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(body),
                  if (recorded) ...[
                    const SizedBox(height: 4),
                    Text(
                        tr(c, 'Recorded. Repeating this action is safe.',
                            'Registado. Repetir esta ação é seguro.'),
                        style: Theme.of(c).textTheme.bodySmall)
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton(
                      onPressed: () => _award(eventId), child: Text(button))
                ])));
  }

  Widget _cosmeticTile(BuildContext c, RewardCosmetic cosmetic,
      String selectedId, bool earned) {
    final isSelected = selectedId == cosmetic.id && earned;
    final name = _cosmeticName(c, cosmetic.id);
    return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(earned
            ? (isSelected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked)
            : Icons.lock_outline),
        title: Text(name),
        subtitle: Text(earned
            ? _requirement(c, cosmetic)
            : '${tr(c, 'Locked', 'Bloqueada')}: ${_requirement(c, cosmetic)}'),
        trailing: isSelected
            ? Text(tr(c, 'Selected', 'Selecionado'),
                style: Theme.of(c).textTheme.labelLarge)
            : null,
        enabled: earned,
        onTap: earned ? () => _select(cosmetic) : null);
  }
}
