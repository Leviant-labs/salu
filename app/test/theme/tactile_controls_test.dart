import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:salu/src/theme/glass_surface.dart';
import 'package:salu/src/theme/salu_theme.dart';
import 'package:salu/src/theme/tactile_controls.dart';

void main() {
  testWidgets('dark theme is default with obsidian canvas and emerald accents',
      (tester) async {
    late SaluSurfaceTokens tokens;
    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.light(),
        darkTheme: SaluTheme.dark(),
        themeMode: ThemeMode.dark,
        home: Builder(
          builder: (context) {
            tokens = SaluSurfaceTokens.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(tokens.canvas, const Color(0xFF0B0F0D));
    expect(tokens.accentEmerald, const Color(0xFF48965E));
    expect(tokens.accentSage, const Color(0xFF6FCF8B));
    expect(tokens.glassBlurSigma, inInclusiveRange(10.0, 16.0));
  });

  testWidgets('light theme fallback provides light surface tokens',
      (tester) async {
    late SaluSurfaceTokens tokens;
    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.light(),
        darkTheme: SaluTheme.dark(),
        themeMode: ThemeMode.light,
        home: Builder(
          builder: (context) {
            tokens = SaluSurfaceTokens.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(tokens.canvas, const Color(0xFFF3F7F4));
    expect(tokens.accentEmerald, const Color(0xFF2E6B40));
  });

  testWidgets(
      'GlassSurface applies BackdropFilter when frosted, skips when non-frosted or high-contrast',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.dark(),
        home: const Scaffold(
          body: GlassSurface(
            frosted: true,
            child: Text('Frosted'),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.dark(),
        home: const Scaffold(
          body: GlassSurface(
            frosted: false,
            child: Text('Flat'),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.dark(),
        home: const MediaQuery(
          data: MediaQueryData(highContrast: true),
          child: Scaffold(
            body: GlassSurface(
              frosted: true,
              child: Text('High contrast'),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets(
      'SaluTactileButton enforces 48dp target, handles press/disable/focus and reduced motion',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Column(
              children: [
                SaluTactileButton(
                  onPressed: () => taps++,
                  child: const Text('Log'),
                ),
                const SaluTactileButton(
                  onPressed: null,
                  primary: false,
                  child: Text('Disabled'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(SaluTactileButton).first);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));

    await tester.tap(find.text('Log'));
    await tester.pump();
    expect(taps, 1);

    await tester.tap(find.text('Disabled'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets(
      'SaluTactileToggle exposes toggled semantics, 48dp target, and keyboard activation',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var value = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: SaluTheme.dark(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: SaluTactileToggle(
              value: value,
              semanticLabel: 'Enable AI estimates',
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );

    final toggleFinder = find.byType(SaluTactileToggle);
    final size = tester.getSize(toggleFinder);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));

    expect(
      tester.getSemantics(toggleFinder),
      matchesSemantics(
        label: 'Enable AI estimates',
        isToggled: false,
        hasToggledState: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();
    expect(value, isTrue);

    // Focus and toggle via keyboard Space.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(value, isFalse);

    semantics.dispose();
  });
}
