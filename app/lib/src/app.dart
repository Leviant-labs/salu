import 'package:flutter/material.dart';

import 'router.dart';

const _saluSeed = Color(0xFF3E7B4F);

/// Shared Material 3 theme used by both [SaluApp] and startup screens.
ThemeData saluTheme(Brightness brightness) {
  final scheme =
      ColorScheme.fromSeed(seedColor: _saluSeed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelTextStyle: WidgetStateProperty.all(
        const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

/// App shell: theme and routing. No business logic lives here.
class SaluApp extends StatelessWidget {
  /// Creates the app widget.
  const SaluApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Salu',
      debugShowCheckedModeBanner: false,
      theme: saluTheme(Brightness.light),
      darkTheme: saluTheme(Brightness.dark),
      routerConfig: appRouter,
    );
  }
}
