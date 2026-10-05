import 'package:flutter/material.dart';

import 'pitch_accent.dart';

/// A compact, accessible diagram of a word-level Japanese pitch pattern.
/// It is a dictionary diagram, not an audio waveform.
class PitchAccentLine extends StatelessWidget {
  const PitchAccentLine({
    super.key,
    required this.pattern,
    this.color = const Color(0xFFFF6B61),
    this.textStyle,
  });

  final PitchAccentPattern pattern;
  final Color color;
  final TextStyle? textStyle;

  String get _semanticLabel {
    if (pattern.isUnaccented) {
      return '일본어 높낮이 0형, 낮게 시작해 높게 유지';
    }
    if (pattern.hasParticleOnlyDrop) {
      return '일본어 높낮이 ${pattern.accentPosition}형, 뒤 조사에서 낮아짐';
    }
    return '일본어 높낮이 ${pattern.accentPosition}형, '
        '${pattern.accentPosition}번째 박 뒤 낮아짐';
  }

  @override
  Widget build(BuildContext context) {
    const spacing = 28.0;
    final width = (pattern.morae.length - 1) * spacing + 16;
    return Semantics(
      label: _semanticLabel,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              key: const ValueKey('pitch-accent-line'),
              size: Size(width, 23),
              painter: _PitchAccentLinePainter(
                levels: pattern.levels,
                color: color,
                spacing: spacing,
              ),
            ),
            SizedBox(
              width: width,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final mora in pattern.morae)
                    Text(
                      mora,
                      style: textStyle ??
                          const TextStyle(
                            color: Color(0xFF6E6E73),
                            fontSize: 12,
                            height: 1.1,
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

class _PitchAccentLinePainter extends CustomPainter {
  const _PitchAccentLinePainter({
    required this.levels,
    required this.color,
    required this.spacing,
  });

  final List<PitchLevel> levels;
  final Color color;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset pointFor(int index) => Offset(
          8 + index * spacing,
          levels[index] == PitchLevel.high ? 6 : 17,
        );
    final path = Path()..moveTo(pointFor(0).dx, pointFor(0).dy);
    for (var index = 1; index < levels.length; index++) {
      final point = pointFor(index);
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
    final dotPaint = Paint()..color = color;
    for (var index = 0; index < levels.length; index++) {
      canvas.drawCircle(pointFor(index), 2.7, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PitchAccentLinePainter oldDelegate) =>
      oldDelegate.levels != levels ||
      oldDelegate.color != color ||
      oldDelegate.spacing != spacing;
}
