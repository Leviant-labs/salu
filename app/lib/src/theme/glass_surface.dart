import 'dart:ui';

import 'package:flutter/material.dart';

import 'salu_theme.dart';

/// Frosted smoked-glass container with a 1px top-lit specular hairline border.
///
/// Set [frosted] to `false` inside scrolling list items to avoid GPU overdraw.
/// When [MediaQuery.highContrastOf] is true, the fill automatically solidifies
/// and skips [BackdropFilter] for maximum legibility.
class GlassSurface extends StatelessWidget {
  /// Creates a glassmorphic surface.
  const GlassSurface({
    required this.child,
    this.padding,
    this.borderRadius,
    this.frosted = true,
    this.accentBorder = false,
    this.tint,
    super.key,
  });

  /// Content inside the surface.
  final Widget child;

  /// Optional inner padding.
  final EdgeInsetsGeometry? padding;

  /// Corner radius; defaults to `BorderRadius.circular(20)`.
  final BorderRadius? borderRadius;

  /// Whether to apply a [BackdropFilter] blur. Disable for scrolling list rows.
  final bool frosted;

  /// Whether to tint the 1px hairline border with the emerald accent.
  final bool accentBorder;

  /// Optional tint override for the container fill.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final tokens = SaluSurfaceTokens.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final radius = borderRadius ?? BorderRadius.circular(20);
    final useBlur = frosted && !highContrast;

    final borderColor = highContrast
        ? tokens.textPrimary
        : (accentBorder ? tokens.glassAccentBorder : tokens.glassBorder);
    final baseFill =
        tint ?? (useBlur ? tokens.glassFill : tokens.glassFillSolid);

    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: highContrast
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  baseFill,
                  Color.lerp(baseFill, tokens.recessedSurface, 0.35)!,
                ],
              ),
        color: highContrast ? tokens.glassFillSolid : null,
        border: Border.all(
          color: borderColor,
          width: highContrast ? 1.5 : 1.0,
        ),
      ),
      child: padding != null ? Padding(padding: padding!, child: child) : child,
    );

    if (!useBlur) {
      return ClipRRect(borderRadius: radius, child: decorated);
    }

    final sigma = tokens.glassBlurSigma.clamp(10.0, 16.0);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: decorated,
      ),
    );
  }
}
