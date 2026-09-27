import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared strict liquid design language for the whole app.
const List<Color> liquidSpectrum = [
  Color(0xFF64E9FF),
  Color(0xFF4F7CFF),
  Color(0xFF8A6CFF),
  Color(0xFFD86CF8),
  Color(0xFF64E9FF),
];

const Color bgColor = Color(0xFF06070D);
const Color surfaceColor = Color(0xFF10111C);
const Color surfaceSoft = Color(0xFF171827);
const Color strokeColor = Color(0x1AFFFFFF);
const Color mutedText = Color(0x99FFFFFF);

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
        color: Colors.black.withValues(alpha: 0.32),
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
        const Positioned.fill(child: ColoredBox(color: bgColor)),
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
              color: enabled ? null : Colors.white.withValues(alpha: .07),
              border: Border.all(
                color: Colors.white.withValues(alpha: enabled ? .12 : .06),
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
              color: Colors.white.withValues(alpha: enabled ? .95 : .45),
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
        color: Colors.white.withValues(alpha: .06),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(
              icon,
              color: Colors.white.withValues(alpha: .82),
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
  Color color = Colors.white,
  double? letterSpacing,
  double? height,
}) {
  return TextStyle(
    fontFamily: 'sans-serif',
    fontSize: fontSize,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    height: height,
    color: color,
  );
}
