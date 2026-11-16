import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_core/salu_core.dart';
import 'package:salu_data/salu_data.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../catalogue/built_in_catalogue.dart';
import '../../catalogue/starter_meals.dart';
import '../../inference/chatgpt_auth.dart';
import '../onboarding/onboarding_screen.dart';
import '../catalogue/catalogue_preview_screen.dart';
import '../../providers.dart';
import '../../ui_support.dart';

/// The saved goal and condition declarations, if any.
final _healthDeclarationProvider = FutureProvider<StoredDocument?>((ref) =>
    LocalWorkspace(ref.watch(databaseProvider))
        .read('health-declaration', 'current'));

String _goalLabel(BuildContext c, AdultGoal goal) => switch (goal) {
      AdultGoal.notDeclared => tr(c, 'Not declared', 'Não declarada'),
      AdultGoal.loseWeight => tr(c, 'Lose weight', 'Perder peso'),
      AdultGoal.maintainWeight => tr(c, 'Maintain weight', 'Manter peso'),
      AdultGoal.gainWeight => tr(c, 'Gain weight', 'Ganhar peso'),
    };

String _conditionLabel(BuildContext c, DeclaredCondition condition) =>
    switch (condition) {
      DeclaredCondition.highTriglycerides =>
        tr(c, 'High triglycerides', 'Triglicéridos elevados'),
      DeclaredCondition.diabetes => tr(c, 'Diabetes', 'Diabetes'),
      DeclaredCondition.highCholesterol =>
        tr(c, 'High cholesterol', 'Colesterol elevado'),
      DeclaredCondition.lowBloodGlucoseHistoryOrRisk => tr(
          c,
          'History or risk of low blood glucose',
          'Histórico ou risco de glicemia baixa'),
      DeclaredCondition.highBloodPressure =>
        tr(c, 'High blood pressure', 'Tensão arterial elevada'),
      DeclaredCondition.chronicKidneyDisease =>
        tr(c, 'Chronic kidney disease', 'Doença renal crónica'),
      DeclaredCondition.eatingDisorderConcerns => tr(
          c,
          'Eating-disorder concerns',
          'Preocupações com perturbações alimentares'),
      DeclaredCondition.lactoseIntolerance =>
        tr(c, 'Lactose intolerance', 'Intolerância à lactose'),
      DeclaredCondition.gout => tr(c, 'Gout', 'Gota'),
      DeclaredCondition.irritableBowelSyndrome => tr(
          c,
          'Irritable bowel syndrome or digestive triggers',
          'Síndrome do intestino irritável ou gatilhos digestivos'),
      DeclaredCondition.foodAllergy =>
        tr(c, 'Food allergy', 'Alergia alimentar'),
      DeclaredCondition.coeliacDisease =>
        tr(c, 'Coeliac disease', 'Doença celíaca'),
    };

String _declarationSummary(BuildContext c, StoredDocument? document) {
  final declaration = document == null
      ? const AdultHealthDeclaration()
      : AdultHealthDeclaration.fromJson(document.data);
  final declared = [
    for (final condition in DeclaredCondition.values)
      if (declaration.conditionStatus(condition) == true)
        _conditionLabel(c, condition)
  ];
  final goal = declaration.goal == AdultGoal.notDeclared
      ? tr(c, 'goal not declared', 'meta não declarada')
      : tr(c, 'goal: ${_goalLabel(c, declaration.goal)}',
          'meta: ${_goalLabel(c, declaration.goal)}');
  final conditions = declared.isEmpty
      ? tr(c, 'no declared conditions', 'sem condições declaradas')
      : tr(c, 'declared: ${declared.join(', ')}',
          'declaradas: ${declared.join(', ')}');
  final unenforced = [
    DeclaredCondition.foodAllergy,
    DeclaredCondition.coeliacDisease,
  ].any((condition) => declaration.conditionStatus(condition) == true);
  final enforcement = unenforced
      ? tr(
          c,
          ' Food allergy/coeliac declarations do not enforce exclusions; set the strict exclusion in Safety declarations.',
          ' As declarações de alergia/celíaca não impõem exclusões; define a exclusão rígida nas declarações de segurança.')
      : '';
  return tr(
      c,
      '$goal · $conditions. Recorded declarations, not a diagnosis; experimental condition-aware suggestions apply only where data allow and are not clinically validated.$enforcement',
      '$goal · $conditions. Declarações registadas, não um diagnóstico; as sugestões experimentais por condição aplicam-se apenas quando os dados o permitem e não são clinicamente validadas.$enforcement');
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final declaration = ref.watch(_healthDeclarationProvider);
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
              'Hide calorie-budget pressure, weight and fasting prompts, regardless of individual nudge choices.',
              'Ocultar pressão por calorias, peso e lembretes de jejum, independentemente das escolhas individuais.')),
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
          leading: const Icon(Icons.checklist_rtl),
          title: Text(
              tr(c, 'Goal and health declarations', 'Meta e declarações de saúde')),
          subtitle: Text(declaration.hasValue
              ? _declarationSummary(c, declaration.asData?.value)
              : tr(
                  c,
                  'Your own declarations; not a diagnosis. An experimental, non-clinically-validated feature may use them only where data allow.',
                  'Declarações tuas; não é um diagnóstico. Uma funcionalidade experimental, não validada clinicamente, pode usá-las apenas quando os dados o permitem.')),
          onTap: () async {
            await Navigator.push<void>(c,
                MaterialPageRoute(builder: (_) => const _GoalConditionsScreen()));
            if (c.mounted) ref.invalidate(_healthDeclarationProvider);
          }),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.flag_outlined),
          title: Text(tr(c, 'Declared target', 'Meta declarada')),
          subtitle: Text(tr(
              c,
              'Your target or a clinician-provided target.',
              'A tua meta ou uma meta fornecida por profissional de saúde.')),
          onTap: () => _target(c, ref)),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.calculate_outlined),
          title: Text(tr(c, 'Recalculate starting estimate',
              'Recalcular estimativa inicial')),
          subtitle: Text(tr(c, 'Review an estimate from your saved inputs.',
              'Revê uma estimativa a partir dos dados guardados.')),
          onTap: () => _estimate(c, ref)),
      // `support` remains the master switch and overrides these choices
      // without rewriting them. A missing key means that nudge class stays
      // visible when supportive mode is off, preserving previous behavior.
      const Divider(),
      Text(tr(c, 'Nudge preferences', 'Preferências de lembretes'),
          style: Theme.of(c).textTheme.titleMedium),
      Text(tr(
          c,
          'Choose which nudge types to hide. Supportive mode hides all three regardless of these choices.',
          'Escolhe os tipos de lembrete a ocultar. O modo de apoio oculta os três, independentemente destas escolhas.')),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title:
              Text(tr(c, 'Hide calorie nudges', 'Ocultar lembretes de calorias')),
          subtitle: Text(tr(c, 'Calorie-budget prompts are hidden when on.',
              'Os avisos sobre o orçamento de calorias ficam ocultos quando esta opção está ativa.')),
          value: settings['hideCalorieNudges'] == true,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .change('hideCalorieNudges', v)),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr(c, 'Hide weight nudges', 'Ocultar lembretes de peso')),
          subtitle: Text(tr(c, 'Weight prompts are hidden when on.',
              'Os avisos sobre o peso ficam ocultos quando esta opção está ativa.')),
          value: settings['hideWeightNudges'] == true,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .change('hideWeightNudges', v)),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title:
              Text(tr(c, 'Hide fasting nudges', 'Ocultar lembretes de jejum')),
          subtitle: Text(tr(
              c,
              'No fasting notifications exist today. This preference applies if fasting prompts are added; it does not schedule or send notifications.',
              'Ainda não existem notificações de jejum. Esta preferência aplica-se se forem adicionados avisos de jejum; não agenda nem envia notificações.')),
          value: settings['hideFastingNudges'] == true,
          onChanged: (v) => ref
              .read(settingsProvider.notifier)
              .change('hideFastingNudges', v)),
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
          subtitle: Text(tr(
              c,
              'Unencrypted; contains personal records. Text that resembles a spreadsheet formula is prefixed for safety.',
              'Sem cifragem; contém registos pessoais. O texto semelhante a uma fórmula de folha de cálculo recebe um prefixo de segurança.')),
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
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text(tr(c, 'Preview catalogue pack',
              'Pré-visualizar pacote de catálogo')),
          subtitle: Text(tr(c, 'Inspect a local pack without installing it.',
              'Inspeciona um pacote local sem o instalar.')),
          onTap: () => Navigator.push<void>(
              c,
              MaterialPageRoute(
                  builder: (_) => const CataloguePreviewScreen()))),
      const Divider(),
      Text(tr(c, 'Optional connections', 'Ligações opcionais'),
          style: Theme.of(c).textTheme.titleLarge),
      _ChatGptSettings(),
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
    ]);
  }

  Future<void> _target(BuildContext c, WidgetRef ref) async {
    try {
      final w = LocalWorkspace(ref.read(databaseProvider));
      final old = await w.read('target', 'current');
      if (!c.mounted) return;
      final previous = old == null ? null : DeclaredTarget.fromJson(old.data);
      final input = await showDialog<_TargetInput>(
          context: c, builder: (_) => _TargetDialog(previous: previous));
      if (input == null) return;
      final profile = await w.read('profile', 'safety');
      final target = DeclaredTarget(
          id: 'current',
          revision: (old?.revision ?? 0) + 1,
          origin: input.origin,
          effectiveDate: ref.read(todayDiaryDateProvider).toIso(),
          policyVersion: input.origin == TargetOrigin.clinicianProvided
              ? 'clinician-provided-v1'
              : 'user-declared-v1',
          energyKcal: input.energy,
          proteinG: input.protein,
          fatG: input.fat,
          carbohydrateG: input.carbohydrate,
          active: true);
      if (!c.mounted) return;
      if (!await confirmAction(
          c,
          tr(c, 'Save your declared target?', 'Guardar a meta declarada?'),
          tr(
              c,
              'This is your declared plan, not an app-generated requirement.',
              'Este é o teu plano declarado, não uma necessidade determinada pela aplicação.'))) {
        return;
      }
      await w.db.transaction(() async {
        final currentProfile = await w.read('profile', 'safety');
        if ((currentProfile?.revision ?? 0) != (profile?.revision ?? 0)) {
          throw StateError('SAFETY_DECLARATIONS_CHANGED');
        }
        await w.put(
            requestId: ref.read(idGeneratorProvider).next(),
            collection: 'target',
            id: 'current',
            expectedRevision: old?.revision ?? 0,
            data: target.toJson());
      });
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    }
  }

  Future<void> _estimate(BuildContext c, WidgetRef ref) async {
    try {
      final workspace = LocalWorkspace(ref.read(databaseProvider));
      final stored = await NutritionProfileStore(workspace.db).read();
      final old = await workspace.read('target', 'current');
      if (!c.mounted) return;
      if (stored == null) {
        await _estimateInputsRequired(c, const []);
        return;
      }
      final profile = NutritionProfile.fromJson(stored.data);
      DeclaredTarget estimate;
      try {
        estimate = const TargetService().generateAutomaticTarget(
          profile: profile,
          id: 'current',
          revision: (old?.revision ?? 0) + 1,
          effectiveDate: ref.read(todayDiaryDateProvider).toIso(),
        );
      } on TargetEstimateException catch (error) {
        if (error.code != 'TARGET_INPUT_REQUIRED') rethrow;
        if (c.mounted) await _estimateInputsRequired(c, error.missingInputs);
        return;
      }
      if (!c.mounted) return;
      final accepted = await showDialog<bool>(
        context: c,
        builder: (dialogContext) => AlertDialog(
          title: Text(tr(dialogContext, 'Review starting estimate',
              'Rever estimativa inicial')),
          content: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(dialogContext, 'Starting estimate—not a measurement.',
                  'Estimativa inicial — não é uma medição.')),
              const SizedBox(height: 12),
              Text('${estimate.energyKcal.toDouble().round()} kcal · '
                  '${estimate.proteinG!.toDouble().round()} g ${tr(dialogContext, 'protein', 'proteína')} · '
                  '${estimate.fatG!.toDouble().round()} g ${tr(dialogContext, 'fat', 'gordura')} · '
                  '${estimate.carbohydrateG!.toDouble().round()} g ${tr(dialogContext, 'carbohydrate', 'hidratos')}'),
              const SizedBox(height: 12),
              Text(tr(dialogContext,
                  'Based on your saved goal, age, height, weight, equation choice and activity level. Includes a 50 kcal fibre allocation. Existing weekly plans keep their reviewed targets.',
                  'Baseada na meta, idade, altura, peso, equação e atividade guardados. Inclui 50 kcal para fibra. Os planos semanais existentes mantêm as metas revistas.')),
            ],
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(tr(dialogContext, 'Cancel', 'Cancelar'))),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(tr(dialogContext, 'Use estimate', 'Usar estimativa'))),
          ],
        ),
      );
      if (accepted != true) return;
      await workspace.db.transaction(() async {
        final liveProfile = await workspace.read('nutrition-profile-v1', 'current');
        if (liveProfile?.revision != stored.revision) {
          throw StateError('NUTRITION_PROFILE_CHANGED');
        }
        await workspace.put(
          requestId: ref.read(idGeneratorProvider).next(),
          collection: 'target',
          id: 'current',
          expectedRevision: old?.revision ?? 0,
          data: estimate.toJson(),
        );
      });
      invalidateGuidedWorkspace(ref);
    } catch (error) {
      if (c.mounted) showFailure(c, error);
    }
  }

  Future<void> _estimateInputsRequired(
      BuildContext c, List<String> missing) async {
    final setup = await showDialog<bool>(
      context: c,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr(dialogContext, 'Complete estimate inputs',
            'Completar dados da estimativa')),
        content: Text(missing.isEmpty
            ? tr(dialogContext, 'Set up your profile to calculate an estimate.',
                'Configura o teu perfil para calcular uma estimativa.')
            : tr(dialogContext, 'Missing inputs: ${missing.join(', ')}.',
                'Dados em falta: ${missing.join(', ')}.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(tr(dialogContext, 'Not now', 'Agora não'))),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(tr(dialogContext, 'Open setup', 'Abrir configuração'))),
        ],
      ),
    );
    if (setup == true && c.mounted) {
      await Navigator.push<void>(c, MaterialPageRoute(
          builder: (_) => const OnboardingScreen(existingUser: true)));
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
      // Stop in-flight transfers before staging, but retain the connection if
      // archive validation fails.
      await ref.read(chatGptPlanProvider).disconnect();
      await ref.read(chatGptAuthProvider).cancelPendingAttempt();
      await ArchiveService(ref.read(databaseProvider))
          .restoreJson(content, confirmed: true);
      await ref.read(chatGptAuthProvider).clearAllSecrets();
      ref.read(selectedChatGptModelProvider.notifier).state = null;
      _invalidateRecords(ref);
      await ref.read(settingsProvider.notifier).reload();
      if (c.mounted) _showRevocationNotice(c, ref);
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
    var deleted = false;
    try {
      await ref.read(chatGptPlanProvider).disconnect();
      await ref.read(chatGptAuthProvider).cancelPendingAttempt();
      await ArchiveService(ref.read(databaseProvider))
          .deleteLocalData(confirmed: true);
      deleted = true;
      _invalidateRecords(ref);
      await ref.read(chatGptAuthProvider).clearAllSecrets();
      ref.read(selectedChatGptModelProvider.notifier).state = null;
      if (c.mounted) _showRevocationNotice(c, ref);
      final db = ref.read(databaseProvider);
      try {
        await provisionBundledCatalogue(db);
        final provision = await provisionStarterMeals(db);
        ref.read(starterMealProvisioningProvider.notifier).state =
            StarterMealProvisioningOutcome.installed(provision);
      } catch (error) {
        ref.read(starterMealProvisioningProvider.notifier).state =
            StarterMealProvisioningOutcome.failed(error);
        rethrow;
      }
    } catch (e) {
      if (c.mounted) showFailure(c, e);
    } finally {
      if (deleted) {
        ref.read(settingsProvider.notifier).reset();
        _invalidateRecords(ref);
      }
    }
  }

  void _showRevocationNotice(BuildContext c, WidgetRef ref) {
    if (!ref.read(chatGptAuthProvider).revocationUnconfirmed) return;
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(
      content: Text(tr(c,
          'Remote revocation could not be confirmed. Manage access at chatgpt.com/settings/usage.',
          'Não foi possível confirmar a revogação remota. Gere o acesso em chatgpt.com/settings/usage.')),
      action: SnackBarAction(
        label: tr(c, 'Manage access', 'Gerir acesso'),
        onPressed: () => launchUrl(Uri.parse('https://chatgpt.com/settings/usage'),
            mode: LaunchMode.externalApplication),
      ),
    ));
  }

  void _invalidateRecords(WidgetRef ref) {
    ref.invalidate(todayEntriesProvider);
    ref.invalidate(foodSearchProvider);
    ref.invalidate(favoriteFoodsProvider);
    ref.invalidate(recentFoodsProvider);
    ref.invalidate(savedMealsProvider);
    ref.invalidate(installedCataloguesProvider);
    invalidateGuidedWorkspace(ref);
    ref.invalidate(chatGptModelsProvider);
    ref.invalidate(_healthDeclarationProvider);
  }
}

class _ChatGptSettings extends ConsumerWidget {
  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) showFailure(context, error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(chatGptAuthProvider);
    final state = auth.connectionState;
    final models = ref.watch(chatGptModelsProvider);
    final selected = ref.watch(selectedChatGptModelProvider);
    return ExpansionTile(
      leading: const Icon(Icons.auto_awesome_outlined),
      title: const Text('ChatGPT'),
      subtitle: Text(state.connected
          ? (state.planUsageGranted
              ? tr(context, 'Connected for plan assistance', 'Ligado para assistência ao plano')
              : tr(context, 'Enable AI to use plan assistance', 'Ativa a IA para assistência ao plano'))
          : tr(context, 'Optional AI connection', 'Ligação opcional à IA')),
      children: [
        if (!state.connected || !state.planUsageGranted)
          ListTile(
            title: Text(state.connected
                ? tr(context, 'Enable AI', 'Ativar IA')
                : tr(context, 'Continue with ChatGPT', 'Continuar com ChatGPT')),
            onTap: () => _run(context, () async {
              await auth.connect(registrationId: state.connected
                  ? state.activeRegistrationId : null);
              ref.invalidate(chatGptModelsProvider);
            }),
          ),
        if (state.status == ChatGptAuthStatus.connecting)
          ListTile(
            title: Text(tr(context, 'Cancel sign-in', 'Cancelar início de sessão')),
            onTap: () => _run(context, auth.cancelPendingAttempt),
          ),
        for (final account in state.accounts)
          ListTile(
            title: Text(account.displayLabel ?? tr(context, 'ChatGPT account', 'Conta ChatGPT')),
            trailing: account.registrationId == state.activeRegistrationId
                ? const Icon(Icons.check) : null,
            onTap: account.registrationId == state.activeRegistrationId ? null : () =>
                _run(context, () async {
                  await ref.read(chatGptPlanProvider).disconnect();
                  await auth.selectAccount(account.registrationId);
                  ref.read(selectedChatGptModelProvider.notifier).state = null;
                  ref.invalidate(chatGptModelsProvider);
                }),
          ),
        if (state.connected && state.planUsageGranted)
          models.when(
            loading: () => const ListTile(title: LinearProgressIndicator()),
            error: (error, _) => ListTile(
              title: Text(tr(context, 'Could not load models', 'Não foi possível carregar os modelos')),
              trailing: IconButton(
                tooltip: tr(context, 'Retry', 'Tentar novamente'),
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(chatGptModelsProvider)),
            ),
            data: (items) => items.isEmpty
                ? ListTile(title: Text(tr(context, 'Model access unavailable', 'Acesso aos modelos indisponível')))
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: DropdownButtonFormField<String>(
                      initialValue: items.any((item) => item.slug == selected)
                          ? selected : items.first.slug,
                      decoration: InputDecoration(labelText: tr(context, 'Model', 'Modelo')),
                      items: [for (final item in items)
                        DropdownMenuItem(value: item.slug, child: Text(item.displayName))],
                      onChanged: (value) => ref.read(selectedChatGptModelProvider.notifier).state = value,
                    ),
                  ),
          ),
        if (state.errorCode != null)
          ListTile(title: Text(tr(context, 'Connection error', 'Erro de ligação')),
              subtitle: Text(state.errorCode!)),
        if (state.connected)
          ListTile(
            title: Text(tr(context, 'Disconnect', 'Desligar')),
            onTap: () => _run(context, () async {
              await ref.read(chatGptPlanProvider).disconnect();
              await auth.disconnect();
              ref.read(selectedChatGptModelProvider.notifier).state = null;
              ref.invalidate(chatGptModelsProvider);
              if (context.mounted && auth.revocationUnconfirmed) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(tr(context,
                      'Remote revocation could not be confirmed.',
                      'Não foi possível confirmar a revogação remota.')),
                  action: SnackBarAction(
                    label: tr(context, 'Manage access', 'Gerir acesso'),
                    onPressed: () => launchUrl(
                        Uri.parse('https://chatgpt.com/settings/usage'),
                        mode: LaunchMode.externalApplication),
                  ),
                ));
              }
            }),
          ),
      ],
    );
  }
}

class _TargetInput {
  const _TargetInput(
      this.energy, this.protein, this.fat, this.carbohydrate, this.origin);
  final Exact energy;
  final Exact? protein, fat, carbohydrate;
  final TargetOrigin origin;
}

class _TargetDialog extends StatefulWidget {
  const _TargetDialog({this.previous});
  final DeclaredTarget? previous;

  @override
  State<_TargetDialog> createState() => _TargetDialogState();
}

class _TargetDialogState extends State<_TargetDialog> {
  late final List<TextEditingController> fields;
  late final List<String> initial;
  late TargetOrigin origin;
  String? error;

  @override
  void initState() {
    super.initState();
    final target = widget.previous;
    initial = [
      target?.energyKcal,
      target?.proteinG,
      target?.fatG,
      target?.carbohydrateG
    ].map((v) => v?.toString() ?? '').toList();
    fields = initial.map((s) => TextEditingController(text: s)).toList();
    origin = target?.origin == TargetOrigin.clinicianProvided
        ? TargetOrigin.clinicianProvided
        : TargetOrigin.userDeclared;
  }

  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }

  void submit() {
    try {
      final previous = widget.previous;
      final old = [
        previous?.energyKcal,
        previous?.proteinG,
        previous?.fatG,
        previous?.carbohydrateG
      ];
      Exact? parse(int i) {
        final text = fields[i].text.trim();
        if (text.isEmpty) return null;
        if (text == initial[i] && old[i] != null) return old[i];
        return Exact.parse(text.replaceAll(',', '.'));
      }

      final energy = parse(0);
      if (energy == null || !energy.positive) throw const FormatException();
      final protein = parse(1), fat = parse(2), carbohydrate = parse(3);
      if ([protein, fat, carbohydrate]
          .any((v) => v != null && v.compareTo(Exact.zero) < 0)) {
        throw const FormatException();
      }
      final total = (protein ?? Exact.zero) * Exact.parse('4') +
          (fat ?? Exact.zero) * Exact.parse('9') +
          (carbohydrate ?? Exact.zero) * Exact.parse('4');
      if (total.compareTo(energy) > 0) {
        setState(() => error = tr(
            context,
            'Macro energy exceeds the declared energy. Review the amounts.',
            'A energia dos macronutrientes excede a energia declarada. Revê as quantidades.'));
        return;
      }
      Navigator.pop(
          context, _TargetInput(energy, protein, fat, carbohydrate, origin));
    } catch (_) {
      setState(() => error = tr(
          context,
          'Enter a positive energy value and non-negative macro values.',
          'Introduz uma energia positiva e quantidades de macronutrientes não negativas.'));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(tr(context, 'Declared target', 'Meta declarada')),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr(
                context,
                'Enter your own target or one provided by a clinician. Optional macro values may be left blank.',
                'Introduz a tua meta ou uma fornecida por um profissional de saúde. Os macronutrientes são opcionais.')),
            for (final entry in [
              (
                0,
                tr(context, 'Declared daily energy (kcal)',
                    'Energia diária declarada (kcal)')
              ),
              (1, tr(context, 'Protein (g)', 'Proteína (g)')),
              (2, tr(context, 'Fat (g)', 'Gordura (g)')),
              (3, tr(context, 'Carbohydrate (g)', 'Hidratos de carbono (g)'))
            ])
              TextField(
                  controller: fields[entry.$1],
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: entry.$2)),
            DropdownButtonFormField<TargetOrigin>(
                initialValue: origin,
                decoration: InputDecoration(
                    labelText: tr(context, 'Target source', 'Origem da meta')),
                items: [
                  DropdownMenuItem(
                      value: TargetOrigin.userDeclared,
                      child: Text(tr(context, 'My target', 'A minha meta'))),
                  DropdownMenuItem(
                      value: TargetOrigin.clinicianProvided,
                      child: Text(tr(context, 'Clinician-provided',
                          'Fornecida por profissional de saúde')))
                ],
                onChanged: (v) {
                  if (v != null) setState(() => origin = v);
                }),
            if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr(context, 'Cancel', 'Cancelar'))),
            FilledButton(
                onPressed: submit,
                child: Text(tr(context, 'Continue', 'Continuar')))
          ]);
}

class _SafetyScreen extends ConsumerStatefulWidget {
  const _SafetyScreen();
  @override
  ConsumerState<_SafetyScreen> createState() => _SafetyState();
}

class _SafetyState extends ConsumerState<_SafetyScreen> {
  Map<String, Object?> data = {};
  bool loaded = false;
  int loadedRevision = 0;
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
        loadedRevision = document?.revision ?? 0;
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
                  'Optional information to keep with your preferences.',
                  'Informação opcional para guardar com as suas preferências.')),
              const SizedBox(height: 20),
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: DropdownButtonFormField<bool?>(
                    isExpanded: true,
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
                    onChanged: (v) => setState(() => data[pair[0]] = v))),
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
                      await w.db.transaction(() async {
                        final old = await w.read('profile', 'safety');
                        if ((old?.revision ?? 0) != loadedRevision) {
                          throw StateError('SAFETY_DECLARATIONS_CHANGED');
                        }
                        await w.put(
                            requestId: ref.read(idGeneratorProvider).next(),
                            collection: 'profile',
                            id: 'safety',
                            expectedRevision: old?.revision ?? 0,
                            data: profile.toJson());
                      });
                      invalidateGuidedWorkspace(ref);
                      if (c.mounted) Navigator.pop(c);
                    } catch (e) {
                      if (c.mounted) showFailure(c, e);
                    }
                  },
                  child:
                      Text(tr(c, 'Save declarations', 'Guardar declarações')))
            ]));
}

bool _isFutureGoal(Object? value) =>
    value != null &&
    (value is! String || AdultGoal.byNameOrNull(value) == null);

bool _isFutureCondition(Object? value) => value != null && value is! bool;

class _GoalConditionsScreen extends ConsumerStatefulWidget {
  const _GoalConditionsScreen();
  @override
  ConsumerState<_GoalConditionsScreen> createState() =>
      _GoalConditionsState();
}

class _GoalConditionsState extends ConsumerState<_GoalConditionsScreen> {
  Map<String, Object?> data = {};
  AdultGoal goal = AdultGoal.notDeclared;
  Map<DeclaredCondition, bool?> conditions = {
    for (final condition in DeclaredCondition.values) condition: null
  };
  final Set<String> touched = {};
  bool loaded = false;
  int loadedRevision = 0;
  StoredDocument? storedProfile;
  NutritionProfile? loadedProfile;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final document = await LocalWorkspace(ref.read(databaseProvider))
        .read('health-declaration', 'current');
    final profileDocument =
        await NutritionProfileStore(ref.read(databaseProvider)).read();
    if (!mounted) return;
    final raw = <String, Object?>{...?document?.data};
    final declaration = AdultHealthDeclaration.fromJson(raw);
    setState(() {
      data = raw;
      goal = declaration.goal;
      conditions = {
        for (final condition in DeclaredCondition.values)
          condition: declaration.conditionStatus(condition)
      };
      loadedRevision = document?.revision ?? 0;
      storedProfile = profileDocument;
      loadedProfile = profileDocument == null
          ? null
          : NutritionProfile.fromJson(profileDocument.data);
      loaded = true;
    });
  }

  Future<void> _save() async {
    try {
      final storedConditions = data['conditions'];
      final rawConditions = storedConditions is Map<Object?, Object?>
          ? Map<String, Object?>.from(storedConditions)
          : <String, Object?>{};
      final next = <String, Object?>{...data};
      // Values this build does not understand are kept until the user changes
      // that declaration, so a newer build's data survives unrelated edits.
      if (!_isFutureGoal(data['goal']) || touched.contains('goal')) {
        next['goal'] = goal.name;
      }
      final nextConditions = <String, Object?>{...rawConditions};
      for (final condition in DeclaredCondition.values) {
        if (!_isFutureCondition(rawConditions[condition.name]) ||
            touched.contains(condition.name)) {
          nextConditions[condition.name] = conditions[condition];
        }
      }
      next['conditions'] = nextConditions;
      next['schemaVersion'] = data['schemaVersion'] ?? 1;
      next['guidancePolicy'] = AdultHealthDeclaration.guidancePolicy;
      final workspace = LocalWorkspace(ref.read(databaseProvider));
      final profileStore = NutritionProfileStore(ref.read(databaseProvider));
      // An explicit goal edit updates the known guided profile in the same
      // transaction once a guided profile exists; without one only the
      // declaration document is written.
      final profileRevision = storedProfile?.revision ?? 0;
      final profile = loadedProfile?.copyWith(goal: goal);
      await workspace.db.transaction(() async {
        final old = await workspace.read('health-declaration', 'current');
        if ((old?.revision ?? 0) != loadedRevision) {
          throw StateError('GOAL_DECLARATIONS_CHANGED');
        }
        await workspace.put(
            requestId: ref.read(idGeneratorProvider).next(),
            collection: 'health-declaration',
            id: 'current',
            expectedRevision: old?.revision ?? 0,
            data: next);
        if (profile != null && touched.contains('goal')) {
          final live = await workspace.read('nutrition-profile-v1', 'current');
          if ((live?.revision ?? 0) != profileRevision) {
            throw StateError('NUTRITION_PROFILE_CHANGED');
          }
          await profileStore.save(
              requestId: ref.read(idGeneratorProvider).next(),
              expectedRevision: profileRevision,
              profile: profile);
        }
      });
      invalidateGuidedWorkspace(ref);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }


  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(
          title: Text(tr(
              c, 'Goal and health declarations', 'Meta e declarações de saúde'))),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text(tr(
                  c,
                  'These are your own declarations. They are not a diagnosis or clinical assessment, and "not declared" does not mean a condition is absent.',
                  'Estas são as tuas declarações. Não são um diagnóstico nem uma avaliação clínica, e «não declarada» não significa que a condição esteja ausente.')),
              const SizedBox(height: 16),
              Text(tr(c, 'Goal', 'Meta'),
                  style: Theme.of(c).textTheme.titleMedium),
              Text(tr(
                  c,
                  'Choosing a goal records a preference. It does not create or change an energy or nutrient target.',
                  'Escolher uma meta regista uma preferência. Não cria nem altera uma meta de energia ou nutrientes.')),
              DropdownButtonFormField<AdultGoal>(
                  initialValue: goal,
                  decoration: InputDecoration(
                      labelText: tr(c, 'Your goal', 'A tua meta')),
                  items: [
                    for (final option in AdultGoal.values)
                      DropdownMenuItem(
                          value: option, child: Text(_goalLabel(c, option)))
                  ],
                  onChanged: (value) => setState(() {
                        goal = value ?? AdultGoal.notDeclared;
                        touched.add('goal');
                      })),
              const SizedBox(height: 24),
              Text(tr(c, 'Conditions (optional)', 'Condições (opcional)'),
                  style: Theme.of(c).textTheme.titleMedium),
              Text(tr(
                  c,
                  'Declaring a condition records it. Choosing No records that it does not apply; leaving Not declared keeps it unknown. These declarations never diagnose, assess subtype or severity, change your safety declarations, or activate a target.',
                  'Declarar uma condição regista-a. Escolher Não regista que não se aplica; deixar Não declarada mantém o estado desconhecido. Estas declarações nunca diagnosticam, não avaliam o subtipo ou a gravidade, não alteram as tuas declarações de segurança nem ativam uma meta.')),
              const SizedBox(height: 8),
              Text(tr(
                  c,
                  'An experimental local feature may use these declarations, together with known nutrient data, to tailor meal suggestions and show their basis. It is not clinically validated and is not medical advice. It does not promise that a declared condition has a suitable rule: when data are missing, a condition needs individual limits, or rules conflict, the result must say so instead of presenting a generic suggestion as tailored.',
                  'Uma funcionalidade experimental local pode usar estas declarações, em conjunto com dados nutricionais conhecidos, para adaptar sugestões de refeições e mostrar a sua base. Não é clinicamente validado nem constitui aconselhamento médico. Não promete que uma condição declarada tenha uma regra adequada: quando faltam dados, a condição exige limites individuais ou as regras entram em conflito, o resultado deve dizê-lo em vez de apresentar uma sugestão genérica como adaptada.')),
              const SizedBox(height: 8),
              Text(tr(
                  c,
                  'Food allergy and coeliac disease are declaration flags only. Selecting either does not identify an allergen, exclude gluten or any ingredient, or make a meal safe. Strict exclusions are the only hard allergy constraint; declare the specific exclusion in Safety declarations. Unknown allergen or gluten status is never treated as safe, and labels and cross-contact must still be checked.',
                  'Alergia alimentar e doença celíaca são apenas registos. Selecionar uma delas não identifica um alergénio, não exclui glúten nem qualquer ingrediente e não torna uma refeição segura. As exclusões rígidas são a única restrição alimentar obrigatória para alergias; declara a exclusão específica nas declarações de segurança. O estado desconhecido de alergénios ou glúten nunca é tratado como seguro, e os rótulos e o contacto cruzado têm de ser verificados.')),
              Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                      onPressed: () => Navigator.push<void>(
                          c,
                          MaterialPageRoute(
                              builder: (_) => const _SafetyScreen())),
                      icon: const Icon(Icons.health_and_safety_outlined),
                      label: Text(tr(c, 'Open safety declarations',
                          'Abrir declarações de segurança')))),
              Text(tr(
                  c,
                  'Chronic kidney disease, gout, irritable bowel syndrome and lactose intolerance have no universal limits or trigger list; the app does not infer one from a declaration. For eating-disorder concerns, this declaration does not enable supportive mode or hide calorie, weight or fasting prompts; you can turn it on in Preferences. Pregnancy and breastfeeding are recorded in Safety declarations, not in this list.',
                  'Doença renal crónica, gota, síndrome do intestino irritável e intolerância à lactose não têm limites ou listas de gatilhos universais; a aplicação não os infere a partir de uma declaração. Para preocupações com perturbações alimentares, esta declaração não ativa o modo de apoio nem oculta avisos de calorias, peso ou jejum; podes ativá-lo nas preferências. Gravidez e amamentação são registadas nas declarações de segurança, não nesta lista.')),
              if (conditions[DeclaredCondition.foodAllergy] == true ||
                  conditions[DeclaredCondition.coeliacDisease] == true) ...[
                const SizedBox(height: 8),
                Text(tr(
                    c,
                    'You declared food allergy or coeliac disease. This record alone excludes nothing; declare the specific strict exclusion in Safety declarations before relying on a plan.',
                    'Declaraste alergia alimentar ou doença celíaca. Este registo, por si só, não exclui nada; declara a exclusão rígida específica nas declarações de segurança antes de confiares num plano.'),
                    style:
                        TextStyle(color: Theme.of(c).colorScheme.error)),
              ],
              const SizedBox(height: 8),
              for (final condition in DeclaredCondition.values)
                DropdownButtonFormField<bool?>(
                    isExpanded: true,
                    initialValue: conditions[condition],
                    decoration: InputDecoration(
                        labelText: _conditionLabel(c, condition)),
                    items: [
                      DropdownMenuItem(
                          value: null,
                          child:
                              Text(tr(c, 'Not declared', 'Não declarada'))),
                      DropdownMenuItem(
                          value: true,
                          child: Text(
                              tr(c, 'Yes, I declare this', 'Sim, declaro'))),
                      DropdownMenuItem(
                          value: false, child: Text(tr(c, 'No', 'Não')))
                    ],
                    onChanged: (value) => setState(() {
                          conditions[condition] = value;
                          touched.add(condition.name);
                        })),
              if (conditions[DeclaredCondition.foodAllergy] == true ||
                  conditions[DeclaredCondition.coeliacDisease] == true) ...[
                const SizedBox(height: 8),
                Text(tr(
                    c,
                    'You declared food allergy or coeliac disease. This record alone excludes nothing; declare the specific strict exclusion in Safety declarations before relying on a plan.',
                    'Declaraste alergia alimentar ou doença celíaca. Este registo, por si só, não exclui nada; declara a exclusão rígida específica nas declarações de segurança antes de confiares num plano.'),
                    style:
                        TextStyle(color: Theme.of(c).colorScheme.error)),
              ],
              const SizedBox(height: 20),
              Text(tr(
                  c,
                  'No subtype or severity is recorded. These declarations never change your safety declarations or activate a target.',
                  'Não é registado qualquer subtipo ou gravidade. Estas declarações nunca alteram as declarações de segurança nem ativam uma meta.')),
              const SizedBox(height: 20),
              FilledButton(
                  onPressed: _save,
                  child:
                      Text(tr(c, 'Save declarations', 'Guardar declarações')))
            ]));
}
