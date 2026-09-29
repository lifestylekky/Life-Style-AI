import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chat_screen.dart';
import 'ai_service.dart';
import 'liquid_ui.dart';
import 'models.dart';
import 'supabase_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final cloud = SupabaseService();
  ProductStore.instance.configure(cloud);
  unawaited(ProductStore.instance.load());
  unawaited(AiService.refreshPromptProfiles(cloud));
  runApp(const LifeStyleApp());
}

class LifeStyleApp extends StatelessWidget {
  const LifeStyleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Life Style AI',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: _appTheme(Brightness.light),
        darkTheme: _appTheme(Brightness.dark),
        home: const RootScreen(),
      ),
    );
  }

  ThemeData _appTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: dark
          ? const Color(0xFF06070D)
          : const Color(0xFFF7F8FC),
      useMaterial3: true,
      fontFamily: 'sans-serif',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF267CFF),
        brightness: brightness,
        surface: dark ? const Color(0xFF10111C) : Colors.white,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: dark ? const Color(0xFF10111C) : Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      appBarTheme: AppBarTheme(
        foregroundColor: dark ? Colors.white : const Color(0xFF172033),
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

enum _Phase { greeting, chat }

class _RootScreenState extends State<RootScreen> {
  _Phase _phase = _Phase.greeting;

  void _goToChat() {
    if (_phase != _Phase.chat) setState(() => _phase = _Phase.chat);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 900),
      switchInCurve: Curves.easeOutExpo,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutExpo,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: .92, end: 1).animate(curved),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, .035),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          ),
        );
      },
      child: _phase == _Phase.greeting
          ? GreetingScreen(key: const ValueKey('greeting'), onDone: _goToChat)
          : ChatScreen(key: const ValueKey('chat')),
    );
  }
}

class GreetingScreen extends StatefulWidget {
  const GreetingScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<GreetingScreen> createState() => _GreetingScreenState();
}

class _GreetingScreenState extends State<GreetingScreen>
    with TickerProviderStateMixin {
  static const Duration _hold = Duration(milliseconds: 720);

  late final AnimationController _flow = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  )..repeat();
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1850),
  );
  Timer? _finish;

  @override
  void initState() {
    super.initState();
    _intro.forward();
    _finish = Timer(const Duration(milliseconds: 2800) + _hold, () {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _finish?.cancel();
    _flow.dispose();
    _intro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: AnimatedBuilder(
        animation: Listenable.merge([_flow, _intro]),
        builder: (context, _) {
          final phase = _flow.value;
          final title = CurvedAnimation(
            parent: _intro,
            curve: const Interval(.18, .72, curve: Curves.easeOutExpo),
          );
          final sub = CurvedAnimation(
            parent: _intro,
            curve: const Interval(.48, .92, curve: Curves.easeOutCubic),
          );
          final ring = CurvedAnimation(
            parent: _intro,
            curve: const Interval(.0, 1, curve: Curves.easeOutCubic),
          );
          return LiquidScaffold(
            phase: phase,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _LiquidGridPainter(
                      phase: phase,
                      intensity: .22 + ring.value * .28,
                    ),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.scale(
                          scale: .78 + (.22 * ring.value),
                          child: Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: liquidGradient(opacity: .24),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .16),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFF64E9FF,
                                  ).withValues(alpha: .18 + .22 * ring.value),
                                  blurRadius: 44,
                                ),
                              ],
                            ),
                            child: const Center(child: SparkleIcon(size: 44)),
                          ),
                        ),
                        const SizedBox(height: 28),
                        FadeTransition(
                          opacity: title,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, .18),
                              end: Offset.zero,
                            ).animate(title),
                            child: ShaderMask(
                              shaderCallback: (b) => LinearGradient(
                                begin: Alignment(-1 + phase * 2, -1),
                                end: Alignment(1 + phase * 2, 1),
                                colors: liquidSpectrum,
                              ).createShader(b),
                              blendMode: BlendMode.srcIn,
                              child: Text(
                                'Life Style AI',
                                textAlign: TextAlign.center,
                                style: jost(
                                  fontSize: 50,
                                  weight: FontWeight.w800,
                                  letterSpacing: -1.4,
                                  height: .96,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        FadeTransition(
                          opacity: sub,
                          child: Text(
                            'Liquid product studio',
                            style: jost(
                              fontSize: 15,
                              weight: FontWeight.w300,
                              letterSpacing: 5.5,
                              color: Colors.white.withValues(alpha: .62),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LiquidGridPainter extends CustomPainter {
  const _LiquidGridPainter({required this.phase, required this.intensity});
  final double phase;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: .035 * intensity);
    for (var y = -40.0; y < size.height + 40; y += 34) {
      final path = Path();
      for (var x = 0.0; x <= size.width; x += 18) {
        final wave = math.sin((x / 80) + phase * math.pi * 2) * 5;
        if (x == 0) {
          path.moveTo(x, y + wave);
        } else {
          path.lineTo(x, y + wave);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_LiquidGridPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.intensity != intensity;
}
