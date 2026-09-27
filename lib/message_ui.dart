import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'liquid_ui.dart';
import 'models.dart';

String formatChatTime(BuildContext context, DateTime timestamp) {
  return MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay.fromDateTime(timestamp));
}

Future<void> showImageViewer(
  BuildContext context, {
  required List<Uint8List> images,
  int initialIndex = 0,
  String title = 'Reference image',
}) {
  return Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 190),
      pageBuilder: (_, animation, secondaryAnimation) => _ImageViewerPage(
        images: images,
        initialIndex: initialIndex,
        title: title,
      ),
      transitionsBuilder: (_, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: child,
          ),
    ),
  );
}

class _ImageViewerPage extends StatefulWidget {
  const _ImageViewerPage({
    required this.images,
    required this.initialIndex,
    required this.title,
  });

  final List<Uint8List> images;
  final int initialIndex;
  final String title;

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF030407),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _page,
              itemCount: widget.images.length,
              onPageChanged: (value) => setState(() => _index = value),
              itemBuilder: (context, index) => Center(
                child: InteractiveViewer(
                  minScale: .8,
                  maxScale: 5,
                  boundaryMargin: const EdgeInsets.all(40),
                  child: Image.memory(
                    widget.images[index],
                    width: MediaQuery.sizeOf(context).width,
                    height: MediaQuery.sizeOf(context).height,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              top: 8,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.images.length > 1
                          ? '${widget.title}  ${_index + 1}/${widget.images.length}'
                          : widget.title,
                      style: jost(fontSize: 15, weight: FontWeight.w600),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .48),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      tooltip: 'Close image viewer',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GroupedMessageImages extends StatelessWidget {
  const GroupedMessageImages({
    super.key,
    required this.images,
    required this.onTap,
    this.singleWidth = 148,
    this.singleAspectRatio,
  });

  final List<Uint8List> images;
  final ValueChanged<int> onTap;
  final double singleWidth;
  final double? singleAspectRatio;

  @override
  Widget build(BuildContext context) {
    final visible = images.take(4).toList();
    if (visible.length == 1) {
      final height = singleAspectRatio == null
          ? singleWidth
          : math.min(320, singleWidth / singleAspectRatio!);
      return _imageTile(
        context,
        visible.first,
        0,
        singleWidth,
        height.toDouble(),
      );
    }
    return SizedBox(
      width: 148,
      height: 148,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 5,
          mainAxisSpacing: 5,
        ),
        itemCount: visible.length,
        itemBuilder: (context, index) => _imageTile(
          context,
          visible[index],
          index,
          71.5,
          71.5,
          overlayCount: index == 3 && images.length > 4 ? images.length - 4 : 0,
        ),
      ),
    );
  }

  Widget _imageTile(
    BuildContext context,
    Uint8List bytes,
    int index,
    double width,
    double height, {
    int overlayCount = 0,
  }) {
    return SizedBox(
      width: width,
      height: height,
      child: GestureDetector(
        onTap: () => onTap(index),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Image.memory(bytes, fit: BoxFit.cover),
            ),
            if (overlayCount > 0)
              Container(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(13),
                ),
                alignment: Alignment.center,
                child: Text('+$overlayCount', style: jost(fontSize: 18)),
              ),
          ],
        ),
      ),
    );
  }
}

class FormattedMessageText extends StatelessWidget {
  const FormattedMessageText({
    super.key,
    required this.text,
    required this.style,
  });

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < lines.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          _FormattedLine(line: lines[i], style: style),
        ],
      ],
    );
  }
}

class _FormattedLine extends StatelessWidget {
  const _FormattedLine({required this.line, required this.style});
  final String line;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final isBullet = line.trimLeft().startsWith('- ');
    final content = isBullet ? line.trimLeft().substring(2) : line;
    final spans = <TextSpan>[];
    final pattern = RegExp(r'\*\*(.*?)\*\*');
    var cursor = 0;
    for (final match in pattern.allMatches(content)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: content.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(1),
          style: style.copyWith(fontWeight: FontWeight.w800),
        ),
      );
      cursor = match.end;
    }
    if (cursor < content.length) {
      spans.add(TextSpan(text: content.substring(cursor)));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: content));

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isBullet) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Text(
              '•',
              style: style.copyWith(color: const Color(0xFF64E9FF)),
            ),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(style: style, children: spans),
            ),
          ),
        ] else
          Expanded(
            child: RichText(
              text: TextSpan(style: style, children: spans),
            ),
          ),
      ],
    );
  }
}

class AnimatedResponseText extends StatefulWidget {
  const AnimatedResponseText({
    super.key,
    required this.text,
    required this.style,
    this.animate = true,
    this.onStarted,
    this.onCompleted,
  });

  final String text;
  final TextStyle style;
  final bool animate;
  final VoidCallback? onStarted;
  final VoidCallback? onCompleted;

  @override
  State<AnimatedResponseText> createState() => _AnimatedResponseTextState();
}

class _AnimatedResponseTextState extends State<AnimatedResponseText> {
  Timer? _timer;
  int _visible = 0;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      widget.onStarted?.call();
      _start();
    } else {
      _visible = widget.text.length;
    }
  }

  @override
  void didUpdateWidget(covariant AnimatedResponseText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _start();
    if (oldWidget.animate != widget.animate) {
      if (widget.animate) {
        _start();
      } else {
        _timer?.cancel();
        setState(() => _visible = widget.text.length);
      }
    }
  }

  void _start() {
    _timer?.cancel();
    _visible = 0;
    if (widget.text.isEmpty) return;
    // Reveal the complete response in about 2.4 seconds, regardless of length.
    final step = math.max(1, (widget.text.length / 100).ceil());
    _timer = Timer.periodic(const Duration(milliseconds: 24), (timer) {
      if (!mounted) return timer.cancel();
      final next = (_visible + step).clamp(0, widget.text.length);
      setState(() => _visible = next);
      if (_visible >= widget.text.length) {
        timer.cancel();
        widget.onCompleted?.call();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) {
      return FormattedMessageText(text: widget.text, style: widget.style);
    }
    return FormattedMessageText(
      text: widget.text.substring(0, _visible),
      style: widget.style,
    );
  }
}

class StylingIndicator extends StatefulWidget {
  const StylingIndicator({
    super.key,
    this.kind = ChatMessageKind.styling,
    this.progress = 0,
    this.sizeLabel,
  });

  final ChatMessageKind kind;
  final int progress;
  final String? sizeLabel;

  @override
  State<StylingIndicator> createState() => _StylingIndicatorState();
}

class _StylingIndicatorState extends State<StylingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void initState() {
    super.initState();
    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final crafting = widget.kind == ChatMessageKind.crafting;
    final responding = widget.kind == ChatMessageKind.responding;
    final progress = widget.progress.clamp(0, 100);
    return SizedBox(
      width: 244,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RotationTransition(
                turns: _controller,
                child: Icon(
                  crafting
                      ? Icons.auto_awesome_rounded
                      : responding
                      ? Icons.chat_bubble_outline_rounded
                      : Icons.flare_rounded,
                  size: 18,
                  color: const Color(0xFF64E9FF),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  crafting
                      ? 'Crafting product image'
                      : responding
                      ? 'Thinking'
                      : 'Styling your product',
                  style: jost(fontSize: 14, weight: FontWeight.w600),
                ),
              ),
              if (crafting)
                Text(
                  '$progress%',
                  style: jost(
                    fontSize: 12,
                    weight: FontWeight.w700,
                    color: const Color(0xFF64E9FF),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            crafting
                ? '${widget.sizeLabel ?? 'Product frame'} · FLUX Kontext Pro'
                : responding
                ? 'Preparing a response'
                : 'Preparing the studio-ready FLUX prompt',
            style: jost(fontSize: 11.5, color: mutedText),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: crafting
                ? TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: progress / 100),
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    builder: (_, value, _) => LinearProgressIndicator(
                      value: value,
                      minHeight: 3,
                      backgroundColor: Colors.white.withValues(alpha: .08),
                      valueColor: const AlwaysStoppedAnimation(
                        Color(0xFF64E9FF),
                      ),
                    ),
                  )
                : LinearProgressIndicator(
                    minHeight: 3,
                    backgroundColor: Colors.white.withValues(alpha: .08),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF64E9FF)),
                  ),
          ),
        ],
      ),
    );
  }
}
