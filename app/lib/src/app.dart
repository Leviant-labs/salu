import 'package:flutter/material.dart';

import 'router.dart';

/// App shell: theme and routing. No business logic lives here.
class SaluApp extends StatelessWidget {
  /// Creates the app widget.
  const SaluApp({super.key});

  static const _seed = Color(0xFF3E7B4F);

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Salu',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      routerConfig: appRouter,
    );
  }
}
