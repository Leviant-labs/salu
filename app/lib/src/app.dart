import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'router.dart';
import 'ui_support.dart';

class SaluApp extends ConsumerWidget {
  const SaluApp({super.key});
  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp.router(
        title: 'Salu',
        debugShowCheckedModeBanner: false,
        locale: Locale(settings['language'] == 'pt' ? 'pt' : 'en',
            settings['language'] == 'pt' ? 'PT' : null),
        supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
            colorSchemeSeed: const Color(0xFF3E7B4F), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF3E7B4F),
            brightness: Brightness.dark,
            useMaterial3: true),
        routerConfig: appRouter,
        builder: (context, child) =>
            settings['onboarded'] == true ? child! : const _Onboarding());
  }
}

class _Onboarding extends ConsumerWidget {
  const _Onboarding();
  @override
  Widget build(BuildContext c, WidgetRef ref) => Scaffold(
          body: SafeArea(
              child: ListView(padding: const EdgeInsets.all(24), children: [
        const SizedBox(height: 32),
        const Icon(Icons.eco_outlined, size: 64),
        Text('Salu', style: Theme.of(c).textTheme.displayMedium),
        const SizedBox(height: 24),
        Text(
            tr(c, 'Your records, on your device',
                'Os teus registos, no teu dispositivo'),
            style: Theme.of(c).textTheme.headlineSmall),
        const SizedBox(height: 16),
        Text(tr(
            c,
            'Record foods, organize meals and review your week offline. There is no app account. Connected services remain off.',
            'Regista alimentos, organiza refeições e revê a semana sem ligação à Internet. Não há conta na aplicação. Os serviços ligados permanecem desligados.')),
        const SizedBox(height: 16),
        Text(tr(
            c,
            'Nutrition values describe records, not diagnoses. Automatic targets and adaptive calorie changes are blocked pending the required reviews.',
            'Os valores nutricionais descrevem registos, não diagnósticos. As metas automáticas e as alterações adaptativas de calorias estão bloqueadas até às revisões exigidas.')),
        const SizedBox(height: 16),
        Text(tr(
            c,
            'You can use supportive mode to hide calorie budgets, weight and fasting prompts.',
            'Podes usar o modo de apoio para ocultar calorias, peso e lembretes de jejum.')),
        SwitchListTile(
            title: Text(tr(c, 'Supportive mode', 'Modo de apoio')),
            value: ref.watch(settingsProvider)['support'] == true,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).change('support', v)),
        DropdownButton<String>(
            value: ref.watch(settingsProvider)['language'] as String? ?? 'en',
            items: const [
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'pt', child: Text('Português (Portugal)'))
            ],
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).change('language', v)),
        const SizedBox(height: 24),
        FilledButton(
            onPressed: () =>
                ref.read(settingsProvider.notifier).change('onboarded', true),
            child:
                Text(tr(c, 'Start local recording', 'Começar o registo local')))
      ])));
}
