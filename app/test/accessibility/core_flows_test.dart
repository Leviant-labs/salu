import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/l10n/app_localizations.dart';
import 'package:salu/src/features/today/diary_summary.dart';
import 'package:salu/src/features/today/today_screen.dart';
import 'package:salu/src/providers.dart';
import 'package:salu/src/theme/salu_theme.dart';
import 'package:salu_core/salu_core.dart';

final class _EmptyEntries implements EntryRepository {
  @override
  Future<void> append(LoggedEntry entry) async {}

  @override
  Future<List<LoggedEntry>> entriesFor(DiaryDate date) async => const [];

  @override
  Future<LoggedEntry?> findByRequestId(String requestId) async => null;
}

void main() {
  testWidgets(
      'TodayScreen renders at 320x640 with 200% text scaling in dark mode without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final today = DiaryDate.assign(
      EventStamp(instant: DateTime.now(), offsetMinutes: 0),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todayDiaryDateProvider.overrideWithValue(today),
          todayMealsProvider.overrideWith((ref) => Stream.value(const [])),
          entryRepositoryProvider.overrideWithValue(_EmptyEntries()),
        ],
        child: MaterialApp(
          theme: SaluTheme.light(),
          darkTheme: SaluTheme.dark(),
          themeMode: ThemeMode.dark,
          supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2.0),
            ),
            child: child!,
          ),
          home: const Scaffold(body: TodayScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Log a meal'), findsOneWidget);
  });

  testWidgets('TodayScreen renders pt_PT localization in light fallback theme',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final today = DiaryDate.assign(
      EventStamp(instant: DateTime.now(), offsetMinutes: 0),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todayDiaryDateProvider.overrideWithValue(today),
          todayMealsProvider.overrideWith((ref) => Stream.value(const [])),
          entryRepositoryProvider.overrideWithValue(_EmptyEntries()),
        ],
        child: MaterialApp(
          locale: const Locale('pt', 'PT'),
          theme: SaluTheme.light(),
          darkTheme: SaluTheme.dark(),
          themeMode: ThemeMode.light,
          supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const Scaffold(body: TodayScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Registar refeição'), findsOneWidget);
    expect(find.text('Diário alimentar'), findsOneWidget);
  });

  testWidgets(
      'DiarySummary exposes semantic labels for estimated, partial, and unknown nutrients',
      (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.dark(),
        supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: DiarySummary(
            profiles: [
              NutrientProfile({
                NutrientKey.energyKcal: NutrientEstimated(250, basis: 'photo'),
              }),
              NutrientProfile({}),
            ],
            targets: const {NutrientKey.energyKcal: 2000},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Declared targets (reference only)'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'Energy: 250 kcal, estimated, partial')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Protein: unknown')),
      findsOneWidget,
    );

    semantics.dispose();
  });
}
