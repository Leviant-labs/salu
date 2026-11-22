import 'dart:ui';

import 'package:flutter/material.dart';

/// Salu's botanical emerald seed color.
const saluSeedColor = Color(0xFF3E7B4F);

/// Surface, glassmorphism, and neumorphism design tokens for Salu.
@immutable
class SaluSurfaceTokens extends ThemeExtension<SaluSurfaceTokens> {
  /// Creates a set of surface tokens.
  const SaluSurfaceTokens({
    required this.canvas,
    required this.recessedSurface,
    required this.elevatedSurface,
    required this.elevatedSurfaceHigh,
    required this.accentEmerald,
    required this.accentSage,
    required this.accentGlow,
    required this.textPrimary,
    required this.textMuted,
    required this.glassFill,
    required this.glassFillSolid,
    required this.glassBorder,
    required this.glassAccentBorder,
    required this.glassBlurSigma,
    required this.neuHighlightShadow,
    required this.neuDepthShadow,
    required this.neuTroughTop,
    required this.neuTroughBottom,
  });

  /// Obsidian/charcoal canvas background.
  final Color canvas;

  /// Recessed surface for troughs, tracks, and sunken controls.
  final Color recessedSurface;

  /// Elevated smoked-charcoal container surface.
  final Color elevatedSurface;

  /// Higher-elevation smoked-charcoal surface.
  final Color elevatedSurfaceHigh;

  /// Botanical emerald primary accent anchored to `#3E7B4F`.
  final Color accentEmerald;

  /// Luminous sage active highlight.
  final Color accentSage;

  /// Soft emerald glow tint for active rims and shadows.
  final Color accentGlow;

  /// Crisp off-white / dark-ink primary text.
  final Color textPrimary;

  /// Muted sage secondary text.
  final Color textMuted;

  /// Frosted translucent glass fill.
  final Color glassFill;

  /// Opaque fallback fill for high-contrast mode and non-blurring list cards.
  final Color glassFillSolid;

  /// 1px top-lit specular hairline border.
  final Color glassBorder;

  /// Emerald-tinted specular hairline border.
  final Color glassAccentBorder;

  /// Restrained BackdropFilter blur sigma (`10–16`, default `12.0`).
  final double glassBlurSigma;

  /// Neumorphic top-left bevel highlight shadow.
  final BoxShadow neuHighlightShadow;

  /// Neumorphic bottom-right depth shadow.
  final BoxShadow neuDepthShadow;

  /// Recessed trough gradient top stop.
  final Color neuTroughTop;

  /// Recessed trough gradient bottom stop.
  final Color neuTroughBottom;

  /// Dark luxury defaults (Salu's default theme).
  static const dark = SaluSurfaceTokens(
    canvas: Color(0xFF0B0F0D),
    recessedSurface: Color(0xFF101613),
    elevatedSurface: Color(0xFF151D19),
    elevatedSurfaceHigh: Color(0xFF1C2621),
    accentEmerald: Color(0xFF48965E),
    accentSage: Color(0xFF6FCF8B),
    accentGlow: Color(0x3D48965E), // rgba(72, 150, 94, 0.24)
    textPrimary: Color(0xFFECF2EE),
    textMuted: Color(0xFF98A89E),
    glassFill: Color(0xB8151D19),
    glassFillSolid: Color(0xFF151D19),
    glassBorder: Color(0x17FFFFFF), // rgba(255, 255, 255, 0.09)
    glassAccentBorder: Color(0x476FCF8B), // rgba(111, 207, 139, 0.28)
    glassBlurSigma: 12.0,
    neuHighlightShadow: BoxShadow(
      color: Color(0x1A6FCF8B),
      offset: Offset(-3, -3),
      blurRadius: 8,
    ),
    neuDepthShadow: BoxShadow(
      color: Color(0x99000000),
      offset: Offset(4, 4),
      blurRadius: 12,
    ),
    neuTroughTop: Color(0xFF0A0E0C),
    neuTroughBottom: Color(0xFF141C18),
  );

  /// Accessible light-mode fallback tokens.
  static const light = SaluSurfaceTokens(
    canvas: Color(0xFFF3F7F4),
    recessedSurface: Color(0xFFE5ECE7),
    elevatedSurface: Color(0xFFFFFFFF),
    elevatedSurfaceHigh: Color(0xFFF8FBF9),
    accentEmerald: Color(0xFF2E6B40),
    accentSage: Color(0xFF3E7B4F),
    accentGlow: Color(0x2E3E7B4F),
    textPrimary: Color(0xFF121C16),
    textMuted: Color(0xFF4B5E52),
    glassFill: Color(0xCCFFFFFF),
    glassFillSolid: Color(0xFFFFFFFF),
    glassBorder: Color(0x1F121C16),
    glassAccentBorder: Color(0x523E7B4F),
    glassBlurSigma: 12.0,
    neuHighlightShadow: BoxShadow(
      color: Color(0xCCFFFFFF),
      offset: Offset(-3, -3),
      blurRadius: 8,
    ),
    neuDepthShadow: BoxShadow(
      color: Color(0x24121C16),
      offset: Offset(4, 4),
      blurRadius: 12,
    ),
    neuTroughTop: Color(0xFFDCE5DF),
    neuTroughBottom: Color(0xFFEEF4F0),
  );

  /// Resolves [SaluSurfaceTokens] from the ambient [Theme], falling back to
  /// [dark] or [light] by brightness.
  static SaluSurfaceTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SaluSurfaceTokens>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  SaluSurfaceTokens copyWith({
    Color? canvas,
    Color? recessedSurface,
    Color? elevatedSurface,
    Color? elevatedSurfaceHigh,
    Color? accentEmerald,
    Color? accentSage,
    Color? accentGlow,
    Color? textPrimary,
    Color? textMuted,
    Color? glassFill,
    Color? glassFillSolid,
    Color? glassBorder,
    Color? glassAccentBorder,
    double? glassBlurSigma,
    BoxShadow? neuHighlightShadow,
    BoxShadow? neuDepthShadow,
    Color? neuTroughTop,
    Color? neuTroughBottom,
  }) {
    return SaluSurfaceTokens(
      canvas: canvas ?? this.canvas,
      recessedSurface: recessedSurface ?? this.recessedSurface,
      elevatedSurface: elevatedSurface ?? this.elevatedSurface,
      elevatedSurfaceHigh: elevatedSurfaceHigh ?? this.elevatedSurfaceHigh,
      accentEmerald: accentEmerald ?? this.accentEmerald,
      accentSage: accentSage ?? this.accentSage,
      accentGlow: accentGlow ?? this.accentGlow,
      textPrimary: textPrimary ?? this.textPrimary,
      textMuted: textMuted ?? this.textMuted,
      glassFill: glassFill ?? this.glassFill,
      glassFillSolid: glassFillSolid ?? this.glassFillSolid,
      glassBorder: glassBorder ?? this.glassBorder,
      glassAccentBorder: glassAccentBorder ?? this.glassAccentBorder,
      glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
      neuHighlightShadow: neuHighlightShadow ?? this.neuHighlightShadow,
      neuDepthShadow: neuDepthShadow ?? this.neuDepthShadow,
      neuTroughTop: neuTroughTop ?? this.neuTroughTop,
      neuTroughBottom: neuTroughBottom ?? this.neuTroughBottom,
    );
  }

  @override
  SaluSurfaceTokens lerp(ThemeExtension<SaluSurfaceTokens>? other, double t) {
    if (other is! SaluSurfaceTokens) return this;
    return SaluSurfaceTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      recessedSurface: Color.lerp(recessedSurface, other.recessedSurface, t)!,
      elevatedSurface: Color.lerp(elevatedSurface, other.elevatedSurface, t)!,
      elevatedSurfaceHigh:
          Color.lerp(elevatedSurfaceHigh, other.elevatedSurfaceHigh, t)!,
      accentEmerald: Color.lerp(accentEmerald, other.accentEmerald, t)!,
      accentSage: Color.lerp(accentSage, other.accentSage, t)!,
      accentGlow: Color.lerp(accentGlow, other.accentGlow, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassFillSolid: Color.lerp(glassFillSolid, other.glassFillSolid, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      glassAccentBorder:
          Color.lerp(glassAccentBorder, other.glassAccentBorder, t)!,
      glassBlurSigma: lerpDouble(glassBlurSigma, other.glassBlurSigma, t)!,
      neuHighlightShadow:
          BoxShadow.lerp(neuHighlightShadow, other.neuHighlightShadow, t)!,
      neuDepthShadow: BoxShadow.lerp(neuDepthShadow, other.neuDepthShadow, t)!,
      neuTroughTop: Color.lerp(neuTroughTop, other.neuTroughTop, t)!,
      neuTroughBottom: Color.lerp(neuTroughBottom, other.neuTroughBottom, t)!,
    );
  }
}

/// Material 3 themes for Salu.
abstract final class SaluTheme {
  /// Default dark-luxury theme with obsidian canvas and emerald accents.
  static ThemeData dark() {
    const tokens = SaluSurfaceTokens.dark;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: saluSeedColor,
      brightness: Brightness.dark,
    );
    final scheme = baseScheme.copyWith(
      primary: tokens.accentEmerald,
      onPrimary: const Color(0xFF07130B),
      primaryContainer: const Color(0xFF1D3A27),
      onPrimaryContainer: tokens.textPrimary,
      secondary: tokens.accentSage,
      onSecondary: const Color(0xFF07130B),
      secondaryContainer: const Color(0xFF1B2B22),
      onSecondaryContainer: tokens.accentSage,
      surface: tokens.canvas,
      onSurface: tokens.textPrimary,
      onSurfaceVariant: tokens.textMuted,
      surfaceContainerLowest: tokens.canvas,
      surfaceContainerLow: tokens.recessedSurface,
      surfaceContainer: tokens.elevatedSurface,
      surfaceContainerHigh: tokens.elevatedSurfaceHigh,
      surfaceContainerHighest: const Color(0xFF23302A),
      outline: const Color(0xFF2E3D35),
      outlineVariant: const Color(0xFF1F2B25),
    );
    return _build(scheme, tokens);
  }

  /// Accessible light-mode fallback theme.
  static ThemeData light() {
    const tokens = SaluSurfaceTokens.light;
    final baseScheme = ColorScheme.fromSeed(
      seedColor: saluSeedColor,
      brightness: Brightness.light,
    );
    final scheme = baseScheme.copyWith(
      primary: tokens.accentEmerald,
      onPrimary: Colors.white,
      secondary: tokens.accentSage,
      surface: tokens.canvas,
      onSurface: tokens.textPrimary,
      onSurfaceVariant: tokens.textMuted,
      surfaceContainerLow: tokens.elevatedSurface,
      surfaceContainer: tokens.recessedSurface,
    );
    return _build(scheme, tokens);
  }

  static ThemeData _build(ColorScheme scheme, SaluSurfaceTokens tokens) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: tokens.canvas,
      extensions: [tokens],
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.canvas,
        foregroundColor: tokens.textPrimary,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: tokens.textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: tokens.elevatedSurface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: tokens.glassBorder),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.recessedSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: tokens.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: tokens.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: tokens.accentSage, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: tokens.accentGlow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: tokens.accentSage);
          }
          return IconThemeData(color: tokens.textMuted);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? tokens.textPrimary : tokens.textMuted,
          );
        }),
      ),
    );
  }
}
