import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared product-studio design language for the whole app.
const List<Color> liquidSpectrum = [
  Color(0xFF64E9FF),
  Color(0xFF4F7CFF),
  Color(0xFF8A6CFF),
  Color(0xFFD86CF8),
  Color(0xFF64E9FF),
];

final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.light);

bool get isDarkTheme => appThemeMode.value == ThemeMode.dark;

Color get bgColor =>
    isDarkTheme ? const Color(0xFF06070D) : const Color(0xFFF7F8FC);
Color get surfaceColor =>
    isDarkTheme ? const Color(0xFF10111C) : const Color(0xFFFFFFFF);
Color get surfaceSoft =>
    isDarkTheme ? const Color(0xFF171827) : const Color(0xFFF0F3F8);
Color get strokeColor =>
    isDarkTheme ? const Color(0x1AFFFFFF) : const Color(0x160E1726);
Color get mutedText =>
    isDarkTheme ? const Color(0x99FFFFFF) : const Color(0x991D2939);
Color get appTextColor =>
    isDarkTheme ? const Color(0xFFF8FAFF) : const Color(0xFF172033);

Color appForeground(BuildContext context, {double opacity = 1}) =>
    appTextColor.withValues(alpha: opacity);

void toggleAppTheme() {
  appThemeMode.value = appThemeMode.value == ThemeMode.dark
      ? ThemeMode.light
      : ThemeMode.dark;
}

LinearGradient liquidGradient({
  AlignmentGeometry begin = Alignment.topLeft,
  AlignmentGeometry end = Alignment.bottomRight,
  double opacity = 1,
}) {
  return LinearGradient(
    begin: begin,
    end: end,
    colors: liquidSpectrum.map((c) => c.withValues(alpha: opacity)).toList(),
  );
}

BoxDecoration glassDecoration({
  double radius = 24,
  bool glow = false,
  Gradient? gradient,
  Color? color,
}) {
  return BoxDecoration(
    color: color ?? surfaceColor.withValues(alpha: 0.78),
    gradient: gradient,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: strokeColor),
    boxShadow: [
      BoxShadow(
        color: (isDarkTheme ? Colors.black : const Color(0xFF203050))
            .withValues(alpha: isDarkTheme ? .32 : .08),
        blurRadius: 22,
        offset: const Offset(0, 10),
      ),
      if (glow)
        BoxShadow(
          color: const Color(0xFF4F7CFF).withValues(alpha: 0.18),
          blurRadius: 34,
          offset: const Offset(0, 10),
        ),
    ],
  );
}

class LiquidScaffold extends StatelessWidget {
  const LiquidScaffold({super.key, required this.child, this.phase = 0});
  final Widget child;
  final double phase;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: bgColor)),
        if (isDarkTheme) ...[
          AmbientBlob(
            phase: phase,
            size: 440,
            color: const Color(0xFF2F5BFF),
            dx: -120 + 80 * phase,
            dy: -110,
          ),
          AmbientBlob(
            phase: phase + .42,
            size: 360,
            color: const Color(0xFFB24BFF),
            dx: MediaQuery.sizeOf(context).width - 210,
            dy: 130,
          ),
          AmbientBlob(
            phase: phase + .74,
            size: 300,
            color: const Color(0xFF16C8D8),
            dx: -80,
            dy: MediaQuery.sizeOf(context).height - 250,
          ),
        ],
        child,
      ],
    );
  }
}

class LiquidCard extends StatelessWidget {
  const LiquidCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.glow = false,
    this.onTap,
  });
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final bool glow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      padding: padding,
      decoration: glassDecoration(radius: radius, glow: glow),
      child: child,
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: body,
      ),
    );
  }
}

class SparkleIcon extends StatelessWidget {
  const SparkleIcon({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (b) => liquidGradient().createShader(b),
      blendMode: BlendMode.srcIn,
      child: CustomPaint(size: Size.square(size), painter: _SparklePainter()),
    );
  }
}

class _SparklePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.48;
    final inner = size.width * 0.14;
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + inner, c.dy - inner, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + inner, c.dy + inner, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - inner, c.dy + inner, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - inner, c.dy - inner, c.dx, c.dy - r)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class AmbientBlob extends StatelessWidget {
  const AmbientBlob({
    super.key,
    required this.phase,
    required this.size,
    required this.color,
    required this.dx,
    required this.dy,
  });
  final double phase;
  final double size;
  final Color color;
  final double dx;
  final double dy;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: dx,
      top: dy,
      width: size,
      height: size,
      child: IgnorePointer(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 70, sigmaY: 70),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  color.withValues(alpha: 0.38),
                  color.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LiquidSendButton extends StatelessWidget {
  const LiquidSendButton({super.key, required this.onTap, this.enabled = true});
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Send message',
      child: AnimatedOpacity(
        opacity: enabled ? 1 : .38,
        duration: const Duration(milliseconds: 180),
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: enabled ? liquidGradient(opacity: .85) : null,
              color: enabled
                  ? null
                  : appTextColor.withValues(alpha: isDarkTheme ? .07 : .05),
              border: Border.all(
                color: appTextColor.withValues(
                  alpha: enabled ? (isDarkTheme ? .12 : .1) : .06,
                ),
              ),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: const Color(0xFF4F7CFF).withValues(alpha: .26),
                        blurRadius: 18,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              Icons.arrow_upward_rounded,
              color: enabled
                  ? Colors.white
                  : appTextColor.withValues(alpha: .45),
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class LiquidIconButton extends StatelessWidget {
  const LiquidIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: appTextColor.withValues(alpha: isDarkTheme ? .06 : .045),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              color: appTextColor.withValues(alpha: .82),
              size: 21,
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle jost({
  double fontSize = 15,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontFamily: 'sans-serif',
    fontSize: fontSize,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    height: height,
    color: color ?? appTextColor,
  );
}
