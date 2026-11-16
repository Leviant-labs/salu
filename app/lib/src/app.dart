import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:salu_data/salu_data.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'providers.dart';
import 'router.dart';
import 'ui_support.dart';

/// The persisted onboarding/access state that controls the app gate.
enum _AccessMode { admitted, setup }

class SaluApp extends ConsumerWidget {
  const SaluApp({super.key});

  @override
  Widget build(BuildContext c, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final access = ref.watch(_accessProvider);
    final admitted = switch (access) {
      AsyncData(:final value) => value == _AccessMode.admitted,
      _ => _versionOf(settings) != null || settings['onboarded'] == true,
    };
    return MaterialApp.router(
      title: 'Salu',
      debugShowCheckedModeBanner: false,
      locale: Locale(settings['language'] == 'pt' ? 'pt' : 'en',
          settings['language'] == 'pt' ? 'PT' : null),
      supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3E7B4F),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          margin: EdgeInsets.all(8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.all(16),
        ),
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3E7B4F),
        brightness: Brightness.dark,
        useMaterial3: true,
        cardTheme: const CardThemeData(
          margin: EdgeInsets.all(8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.all(16),
        ),
      ),
      routerConfig: appRouter,
      builder: (context, child) {
        final content = child!;
        return switch (access) {
          AsyncData(:final value) => value == _AccessMode.admitted
              ? content
              : _setup(existingUser: _versionOf(settings) == 1),
          AsyncError() => content,
          _ => admitted
              ? content
              : _setup(existingUser: settings['onboarded'] == true),
        };
      },
    );
  }
}

Widget _setup({required bool existingUser}) => Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => OnboardingScreen(existingUser: existingUser),
      ),
    );

int? _versionOf(Map<String, Object?> settings) {
  final version = settings['onboardingVersion'];
  if (version is int) return version;
  if (version is num) return version.toInt();
  return null;
}

/// Loads the persisted preference record, migrates the legacy marker once,
/// and decides admission from the versioned record rather than the mutable
/// in-memory settings snapshot alone. Existing workspace content also admits a
/// restored workspace whose old preference marker is absent.
final _accessProvider =
    FutureProvider<_AccessMode>((ref) async {
  ref.watch(settingsProvider);
  final db = ref.watch(databaseProvider);
  final workspace = LocalWorkspace(db);
  final preferences = await workspace.read('preferences', 'app');
  final data = preferences?.data ?? const <String, Object?>{};
  final version = _versionOf(data);
  if (version == 2 || version == 1) {
    return _AccessMode.admitted;
  }
  if (data['onboarded'] == true) {
    await _migrateLegacyOnboarding(ref, workspace, preferences, data);
    return _AccessMode.admitted;
  }
  if (await _hasExistingWorkspace(db, workspace)) {
    await _migrateLegacyOnboarding(ref, workspace, preferences, data);
    return _AccessMode.admitted;
  }
  return _AccessMode.setup;
});

Future<void> _migrateLegacyOnboarding(
  Ref ref,
  LocalWorkspace workspace,
  StoredDocument? preferences,
  Map<String, Object?> data,
) async {
  final next = <String, Object?>{...data}
    ..remove('onboarded')
    ..['onboardingVersion'] = 1;
  await workspace.put(
    requestId: ref.read(idGeneratorProvider).next(),
    collection: 'preferences',
    id: 'app',
    expectedRevision: preferences?.revision ?? 0,
    data: next,
  );
  await ref.read(settingsProvider.notifier).reload();
}

Future<bool> _hasExistingWorkspace(
    AppDatabase db, LocalWorkspace workspace) async {
  final plans = await workspace.list('plan');
  if (plans.isNotEmpty) return true;
  final entries =
      await (db.select(db.logEntries)..limit(1)).getSingleOrNull();
  return entries != null;
}
