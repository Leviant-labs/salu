import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'router.dart';
import 'theme/salu_theme.dart';

/// Shared Material 3 theme used by both [SaluApp] and startup screens.
ThemeData saluTheme(Brightness brightness) =>
    brightness == Brightness.dark ? SaluTheme.dark() : SaluTheme.light();

/// App shell: dark-luxury default theme, localization, and routing.
class SaluApp extends StatelessWidget {
  /// Creates the app widget.
  const SaluApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Salu',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: SaluTheme.light(),
      darkTheme: SaluTheme.dark(),
      supportedLocales: const [Locale('en'), Locale('pt', 'PT')],
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      routerConfig: appRouter,
    );
  }
}
