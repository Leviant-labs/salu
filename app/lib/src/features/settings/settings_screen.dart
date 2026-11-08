import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import '../../providers.dart';
import '../../ui_support.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(tr(c, 'Preferences', 'Preferências'),
          style: Theme.of(c).textTheme.titleLarge),
      DropdownButton<String>(
          value: settings['language'] as String? ?? 'en',
          isExpanded: true,
          items: const [
            DropdownMenuItem(value: 'en', child: Text('English')),
            DropdownMenuItem(value: 'pt', child: Text('Português (Portugal)'))
          ],
          onChanged: (v) =>
              ref.read(settingsProvider.notifier).change('language', v)),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr(c, 'Supportive mode', 'Modo de apoio')),
          subtitle: Text(tr(
              c,
              'Hide calorie-budget pressure, weight and fasting prompts.',
              'Ocultar pressão por calorias, peso e lembretes de jejum.')),
          value: settings['support'] == true,
          onChanged: (v) =>
              ref.read(settingsProvider.notifier).change('support', v)),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.health_and_safety_outlined),
          title: Text(tr(c, 'Safety declarations', 'Declarações de segurança')),
          subtitle: Text(tr(
              c,
              'Editable declarations; not a medical assessment.',
              'Declarações editáveis; não são uma avaliação médica.')),
          onTap: () => Navigator.push<void>(
              c, MaterialPageRoute(builder: (_) => const _SafetyScreen()))),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.flag_outlined),
          title: Text(tr(c, 'Declared target', 'Meta declarada')),
          subtitle: Text(tr(
              c,
              'Your target or a clinician-provided target. Automatic generation is blocked.',
              'A tua meta ou uma meta fornecida por profissional de saúde. A geração automática está bloqueada.')),
          onTap: () => _target(c, ref)),
      const Divider(),
      Text(tr(c, 'Your data', 'Os teus dados'),
          style: Theme.of(c).textTheme.titleLarge),
      Text(tr(
          c,
          'Records stay on this device. Exported files leave the app under your control. Encryption needs your passphrase; there is no recovery if you lose it.',
          'Os registos ficam neste dispositivo. Os ficheiros exportados saem da aplicação sob o teu controlo. A cifragem exige a tua frase-passe; não é possível recuperá-la se a perderes.')),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.lock_outline),
          title: Text(tr(c, 'Export encrypted backup',
              'Exportar cópia de segurança cifrada')),
          onTap: () => _export(c, ref, true)),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.table_view_outlined),
          title: Text(tr(c, 'Export diary CSV', 'Exportar diário CSV')),
          subtitle: Text(tr(c, 'Unencrypted, contains personal records.',
              'Sem cifragem, contém registos pessoais.')),
          onTap: () => _export(c, ref, false)),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.restore),
          title: Text(tr(c, 'Restore encrypted backup',
              'Restaurar cópia de segurança cifrada')),
          subtitle: Text(tr(
              c,
              'Replaces current local records after validation.',
              'Substitui os registos locais após validação.')),
          onTap: () => _restore(c, ref)),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.delete_outline),
          title: Text(tr(c, 'Delete local data', 'Eliminar dados locais')),
          subtitle: Text(tr(
              c,
              'External backups, Health records and provider records require separate actions.',
              'As cópias externas, os registos de Saúde e os dados nos fornecedores exigem ações separadas.')),
          onTap: () => _delete(c, ref)),
      const Divider(),
      Text(tr(c, 'Optional connections', 'Ligações opcionais'),
          style: Theme.of(c).textTheme.titleLarge),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.auto_awesome_outlined),
          title: Text(tr(c, 'ChatGPT, label OCR and meal photos',
              'ChatGPT, leitura de rótulos e fotografias de refeições')),
          subtitle: Text(tr(
              c,
              'Unavailable pending supported authorization, terms and distribution review. Use local search or manual entry. No photos are uploaded or queued.',
              'Indisponível até à revisão da autorização suportada, dos termos e da distribuição. Usa a pesquisa local ou a introdução manual. Não são enviadas nem colocadas em fila fotografias.'))),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.favorite_border),
          title: Text(tr(
              c, 'HealthKit / Health Connect', 'HealthKit / Health Connect')),
          subtitle: Text(tr(
              c,
              'Not connected. Native exchange and permission tests remain release gates.',
              'Sem ligação. A troca nativa e os testes de permissões continuam a ser requisitos de lançamento.'))),
      const SizedBox(height: 16),
      Text(
          tr(c, 'Development build • release gates remain open',
              'Versão de desenvolvimento • requisitos de lançamento em aberto'),
          textAlign: TextAlign.center),
    ]);
  }

  Future<void> _target(BuildContext c, WidgetRef ref) async {
    try {
      final w = LocalWorkspace(ref.read(databaseProvider));
      final old = await w.read('target', 'current');
      if (!c.mounted) return;
      final value = await askText(c,
          title: tr(c, 'Declared daily energy (kcal)',
              'Energia diária declarada (kcal)'),
          hint: tr(c, 'Enter your own target, or cancel',
              'Introduz a tua meta, ou cancela'));
      if (value == null) return;
      final amount = Exact.parse(value.replaceAll(',', '.'));
      final profile = await w.read('profile', 'safety');
      final safety = const EligibilityService().evaluate(profile == null
          ? const SafetyProfile()
          : SafetyProfile.fromJson(profile.data));
      final target = DeclaredTarget(
          id: 'current',
          revision: (old?.revision ?? 0) + 1,
          origin: TargetOrigin.userDeclared,
          effectiveDate: ref.read(todayDiaryDateProvider).toIso(),
          policyVersion: 'user-declared-v1',
          energyKcal: amount,
          active: safety.declaredTargetPlanning);
      if (!c.mounted) return;
      if (!await confirmAction(
          c,
          tr(c, 'Save your declared target?', 'Guardar a meta declarada?'),
          tr(
              c,
              'This is your declared plan, not an app-generated requirement. ${target.active ? '' : 'It will remain inactive for recommendations under your current safety declarations.'}',
              'Este é o teu plano declarado, não uma necessidade determinada pela aplicação. ${target.active ? '' : 'Permanecerá inativo para recomendações de acordo com as declarações de segurança atuais.'}'))) {
        return;
      }
      await w.put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'target',
          id: 'current',
          expectedRevision: old?.revision ?? 0,
          data: target.toJson());
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _export(BuildContext c, WidgetRef ref, bool encrypted) async {
    try {
      final service = ArchiveService(ref.read(databaseProvider));
      String content;
      if (encrypted) {
        final password = await askText(c,
            title: tr(c, 'Backup passphrase (12+ characters)',
                'Frase-passe (12+ caracteres)'),
            secret: true);
        if (password == null) return;
        content =
            await EncryptedArchive.seal(await service.exportJson(), password);
      } else {
        if (!await confirmAction(
            c,
            tr(c, 'Export unencrypted CSV?', 'Exportar CSV sem cifragem?'),
            tr(c, 'Anyone with the file can read it.',
                'Qualquer pessoa com o ficheiro pode lê-lo.'))) {
          return;
        }
        content = await service.exportCsv();
      }
      if (!c.mounted) return;
      await FilePicker.platform.saveFile(
        dialogTitle: tr(c, 'Save export', 'Guardar exportação'),
        fileName: encrypted ? 'salu-backup.salu' : 'salu-diary.csv',
        type: FileType.custom,
        allowedExtensions: [encrypted ? 'salu' : 'csv'],
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _restore(BuildContext c, WidgetRef ref) async {
    try {
      final file = await openFile(acceptedTypeGroups: [
        const XTypeGroup(
            label: 'Salu backup',
            extensions: ['salu'],
            uniformTypeIdentifiers: ['public.data'])
      ]);
      if (file == null || !c.mounted) return;
      final password = await askText(c,
          title: tr(c, 'Backup passphrase', 'Frase-passe da cópia'),
          secret: true);
      if (password == null) return;
      final content =
          await EncryptedArchive.open(await file.readAsString(), password);
      if (!c.mounted) return;
      if (!await confirmAction(
          c,
          tr(c, 'Replace local records?', 'Substituir os registos locais?'),
          tr(
              c,
              'Export a backup first if you want to retain current records. Connections are not restored.',
              'Exporta primeiro uma cópia se quiseres manter os registos atuais. As ligações não são restauradas.'))) {
        return;
      }
      await ArchiveService(ref.read(databaseProvider))
          .restoreJson(content, confirmed: true);
      await ref.read(settingsProvider.notifier).reload();
      ref.invalidate(todayEntriesProvider);
      ref.invalidate(foodSearchProvider);
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _delete(BuildContext c, WidgetRef ref) async {
    if (!await confirmAction(
        c,
        tr(c, 'Delete all local data?', 'Eliminar todos os dados locais?'),
        tr(
            c,
            'This removes the local diary, recipes, plans and preferences. It cannot delete copies you exported or records held by other services.',
            'Isto elimina o diário, receitas, planos e preferências locais. Não elimina cópias exportadas nem registos noutros serviços.'))) {
      return;
    }
    try {
      await ArchiveService(ref.read(databaseProvider))
          .deleteLocalData(confirmed: true);
      await const FlutterSecureStorage().deleteAll();
      ref.invalidate(todayEntriesProvider);
      ref.invalidate(foodSearchProvider);
      ref.read(settingsProvider.notifier).reset();
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }
}

class _SafetyScreen extends ConsumerStatefulWidget {
  const _SafetyScreen();
  @override
  ConsumerState<_SafetyScreen> createState() => _SafetyState();
}

class _SafetyState extends ConsumerState<_SafetyScreen> {
  Map<String, Object?> data = {};
  bool loaded = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final document = await LocalWorkspace(ref.read(databaseProvider))
        .read('profile', 'safety');
    if (mounted) {
      setState(() {
        data = {...?document?.data};
        loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(
          title:
              Text(tr(c, 'Safety declarations', 'Declarações de segurança'))),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(tr(
                  c,
                  'These editable declarations do not certify clinical suitability. Unknown answers do not establish eligibility.',
                  'Estas declarações editáveis não certificam adequação clínica. Respostas desconhecidas não estabelecem elegibilidade.')),
              for (final pair in [
                ['adult', tr(c, 'Adult', 'Pessoa adulta')],
                ['pregnant', tr(c, 'Pregnant', 'Grávida')],
                ['breastfeeding', tr(c, 'Breastfeeding', 'A amamentar')],
                [
                  'clinicalNeed',
                  tr(c, 'Medical nutrition needs',
                      'Necessidades de nutrição clínica')
                ],
                [
                  'eatingConcern',
                  tr(c, 'Eating-related concerns / request support',
                      'Preocupações alimentares / pedir apoio')
                ],
                [
                  'relevantMedication',
                  tr(c, 'Relevant medication needs review',
                      'Medicação relevante a rever')
                ]
              ])
                DropdownButtonFormField<bool?>(
                    initialValue: data[pair[0]] as bool?,
                    decoration: InputDecoration(labelText: pair[1]),
                    items: [
                      DropdownMenuItem(
                          value: null,
                          child: Text(tr(c, 'Unknown / prefer not to answer',
                              'Desconhecido / prefiro não responder'))),
                      DropdownMenuItem(
                          value: true, child: Text(tr(c, 'Yes', 'Sim'))),
                      DropdownMenuItem(
                          value: false, child: Text(tr(c, 'No', 'Não')))
                    ],
                    onChanged: (v) => setState(() => data[pair[0]] = v)),
              SwitchListTile(
                  title: Text(tr(
                      c,
                      'Symptoms or unexplained changes needing advice',
                      'Sintomas ou alterações inexplicadas que exigem aconselhamento')),
                  value: data['symptoms'] == true,
                  onChanged: (v) => setState(() => data['symptoms'] = v)),
              const SizedBox(height: 20),
              FilledButton(
                  onPressed: () async {
                    try {
                      final profile = SafetyProfile.fromJson(data);
                      final w = LocalWorkspace(ref.read(databaseProvider));
                      final old = await w.read('profile', 'safety');
                      await w.put(
                          requestId: ref.read(idGeneratorProvider).next(),
                          collection: 'profile',
                          id: 'safety',
                          expectedRevision: old?.revision ?? 0,
                          data: profile.toJson());
                      if (!const EligibilityService()
                          .evaluate(profile)
                          .declaredTargetPlanning) {
                        final target = await w.read('target', 'current');
                        if (target != null && target.data['active'] == true) {
                          await w.put(
                              requestId: ref.read(idGeneratorProvider).next(),
                              collection: 'target',
                              id: 'current',
                              expectedRevision: target.revision,
                              data: {
                                ...target.data,
                                'active': false,
                                'revision': target.revision + 1
                              });
                        }
                      }
                      if (profile.eatingConcern == true) {
                        await ref
                            .read(settingsProvider.notifier)
                            .change('support', true);
                      }
                      if (c.mounted) Navigator.pop(c);
                    } catch (e) {
                      if (c.mounted) showFailure(c, e);
                    }
                  },
                  child:
                      Text(tr(c, 'Save declarations', 'Guardar declarações')))
            ]));
}
