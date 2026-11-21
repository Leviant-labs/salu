import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'salu_theme.dart';

/// Tactile button blending smoked-glass surfaces with dual-shadow neumorphism.
///
/// Raised at rest, transitions to a recessed trough with emerald rim glow on
/// press or keyboard focus, enforces a minimum 48×48dp tap target, and respects
/// [MediaQuery.disableAnimationsOf] and [MediaQuery.highContrastOf].
class SaluTactileButton extends StatefulWidget {
  /// Creates a tactile button.
  const SaluTactileButton({
    required this.onPressed,
    required this.child,
    this.icon,
    this.primary = true,
    this.semanticLabel,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    super.key,
  });

  /// Callback invoked when activated; `null` disables the button.
  final VoidCallback? onPressed;

  /// Button label widget.
  final Widget child;

  /// Optional leading icon.
  final Widget? icon;

  /// Primary emerald-accented variant when true; smoked-glass secondary when false.
  final bool primary;

  /// Optional semantic label override.
  final String? semanticLabel;

  /// Inner padding.
  final EdgeInsetsGeometry padding;

  @override
  State<SaluTactileButton> createState() => _SaluTactileButtonState();
}

class _SaluTactileButtonState extends State<SaluTactileButton> {
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final tokens = SaluSurfaceTokens.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 140);

    final radius = BorderRadius.circular(18);
    final isRaised = _enabled && !_pressed;

    final Color fgColor;
    if (!_enabled) {
      fgColor = tokens.textMuted.withValues(alpha: 0.55);
    } else if (widget.primary) {
      fgColor = const Color(0xFFF3FAF5);
    } else {
      fgColor = tokens.textPrimary;
    }

    final Color borderColor;
    if (highContrast) {
      borderColor = _enabled ? tokens.textPrimary : tokens.textMuted;
    } else if (_focused || (_pressed && _enabled)) {
      borderColor = tokens.accentSage;
    } else if (widget.primary && _enabled) {
      borderColor = tokens.glassAccentBorder;
    } else {
      borderColor = tokens.glassBorder;
    }

    final Gradient? bgGradient;
    if (highContrast) {
      bgGradient = null;
    } else if (_pressed && _enabled) {
      bgGradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: widget.primary
            ? [
                Color.lerp(tokens.accentEmerald, tokens.neuTroughTop, 0.45)!,
                tokens.accentEmerald,
              ]
            : [tokens.neuTroughTop, tokens.neuTroughBottom],
      );
    } else if (widget.primary && _enabled) {
      bgGradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(tokens.accentEmerald, tokens.accentSage, 0.2)!,
          tokens.accentEmerald,
        ],
      );
    } else {
      bgGradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [tokens.elevatedSurfaceHigh, tokens.elevatedSurface],
      );
    }

    final shadows = <BoxShadow>[
      if (!highContrast && isRaised) ...[
        tokens.neuHighlightShadow,
        tokens.neuDepthShadow,
        if (widget.primary)
          BoxShadow(
            color: tokens.accentGlow,
            blurRadius: 16,
            spreadRadius: 0,
          ),
      ],
      if (!highContrast && (_focused || (_pressed && _enabled)))
        BoxShadow(
          color: tokens.accentGlow,
          blurRadius: 10,
          spreadRadius: 1,
        ),
    ];

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
          onTap: widget.onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              padding: widget.padding,
              decoration: BoxDecoration(
                borderRadius: radius,
                color: highContrast
                    ? (widget.primary && _enabled
                        ? tokens.accentEmerald
                        : tokens.elevatedSurface)
                    : null,
                gradient: bgGradient,
                border: Border.all(
                  color: borderColor,
                  width: (_focused || highContrast) ? 2.0 : 1.0,
                ),
                boxShadow: shadows,
              ),
              child: IconTheme(
                data: IconThemeData(color: fgColor, size: 20),
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: fgColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.icon != null) ...[
                        widget.icon!,
                        const SizedBox(width: 8),
                      ],
                      Flexible(child: widget.child),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Recessed neumorphic toggle track with a frosted-glass emerald-illuminated
/// thumb, full toggle semantics, keyboard Space/Enter activation, and a 48×48dp
/// minimum touch target.
class SaluTactileToggle extends StatefulWidget {
  /// Creates a tactile toggle switch.
  const SaluTactileToggle({
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    super.key,
  });

  /// Current toggle state.
  final bool value;

  /// Callback when toggled; `null` disables the control.
  final ValueChanged<bool>? onChanged;

  /// Accessible label describing the setting.
  final String semanticLabel;

  @override
  State<SaluTactileToggle> createState() => _SaluTactileToggleState();
}

class _SaluTactileToggleState extends State<SaluTactileToggle> {
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() {
    if (!_enabled) return;
    widget.onChanged!(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = SaluSurfaceTokens.of(context);
    final highContrast = MediaQuery.highContrastOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration =
        reduceMotion ? Duration.zero : const Duration(milliseconds: 180);

    final trackBorder = highContrast
        ? tokens.textPrimary
        : (_focused
            ? tokens.accentSage
            : (widget.value ? tokens.glassAccentBorder : tokens.glassBorder));

    return Semantics(
      toggled: widget.value,
      enabled: _enabled,
      label: widget.semanticLabel,
      child: FocusableActionDetector(
        enabled: _enabled,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _enabled ? _toggle : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 56, minHeight: 48),
            child: Center(
              child: AnimatedContainer(
                duration: duration,
                width: 54,
                height: 30,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: highContrast
                      ? null
                      : LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: widget.value
                              ? [
                                  Color.lerp(
                                    tokens.neuTroughTop,
                                    tokens.accentEmerald,
                                    0.45,
                                  )!,
                                  Color.lerp(
                                    tokens.neuTroughBottom,
                                    tokens.accentEmerald,
                                    0.35,
                                  )!,
                                ]
                              : [tokens.neuTroughTop, tokens.neuTroughBottom],
                        ),
                  color: highContrast
                      ? (widget.value
                          ? tokens.accentEmerald
                          : tokens.recessedSurface)
                      : null,
                  border: Border.all(
                    color: trackBorder,
                    width: (_focused || highContrast) ? 2.0 : 1.0,
                  ),
                ),
                child: AnimatedAlign(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  alignment: widget.value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.value
                          ? tokens.accentSage
                          : tokens.elevatedSurfaceHigh,
                      border: Border.all(
                        color: widget.value
                            ? const Color(0xFFD8F7E0)
                            : tokens.glassBorder,
                        width: 1,
                      ),
                      boxShadow: highContrast
                          ? null
                          : [
                              if (widget.value)
                                BoxShadow(
                                  color: tokens.accentGlow,
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              tokens.neuDepthShadow,
                            ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
