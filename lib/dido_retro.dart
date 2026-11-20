import 'dart:math' as math;

import 'package:flutter/material.dart';

class DidoRetroEmoji {
  const DidoRetroEmoji(this.id, this.label);

  final String id;
  final String label;
  String get token => ':dido_$id:';
}

class DidoRetro {
  DidoRetro._();

  static const emojis = <DidoRetroEmoji>[
    DidoRetroEmoji('que_chido', '¡Qué chido!'),
    DidoRetroEmoji('va', '¡Va!'),
    DidoRetroEmoji('ya_voy', 'Ya voy'),
    DidoRetroEmoji('te_escucho', 'Te escucho'),
    DidoRetroEmoji('cambio', 'Cambio'),
    DidoRetroEmoji('no_te_oigo', 'No te oigo'),
    DidoRetroEmoji('jaja', 'JAJA'),
    DidoRetroEmoji('no_manches', '¡No manches!'),
    DidoRetroEmoji('que_paso', '¿Qué pasó?'),
    DidoRetroEmoji('todo_bien', 'Todo bien'),
    DidoRetroEmoji('buenas_noches', 'Buenas noches'),
    DidoRetroEmoji('abrazo', 'Abrazo'),
    DidoRetroEmoji('vamos', '¡Vamos!'),
    DidoRetroEmoji('te_mmaste', '¡Te mmste!'),
    DidoRetroEmoji('todo_cool', 'Todo cool'),
  ];

  static Widget image(
    DidoRetroEmoji emoji, {
    double size = 32,
    String? semanticLabel,
  }) => Semantics(
    image: true,
    label: semanticLabel ?? emoji.label,
    child: CustomPaint(
      size: Size.square(size),
      painter: _DidoRetroPainter(emoji.id),
    ),
  );

  static List<InlineSpan> messageSpans(
    String text, {
    required TextStyle style,
    double emojiSize = 29,
  }) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r':dido_[a-z0-9_]+:');
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      final id = token.substring(6, token.length - 1);
      DidoRetroEmoji? emoji;
      for (final item in emojis) {
        if (item.id == id) {
          emoji = item;
          break;
        }
      }
      if (emoji == null) {
        spans.add(TextSpan(text: token));
      } else {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: image(emoji, size: emojiSize),
            ),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    if (spans.isEmpty) spans.add(TextSpan(text: text, style: style));
    return [
      for (final span in spans)
        if (span is TextSpan) TextSpan(text: span.text, style: style) else span,
    ];
  }
}

class _DidoRetroPainter extends CustomPainter {
  const _DidoRetroPainter(this.id);

  final String id;

  static const _outline = Color(0xFF101820);
  static const _teal = Color(0xFF42E2D0);
  static const _cream = Color(0xFFFFE7B5);
  static const _pink = Color(0xFFFF8DB2);
  static const _blue = Color(0xFF73B9FF);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 40, size.height / 40);
    final bg = Paint()..color = const Color(0xFF202833);
    canvas.drawCircle(const Offset(20, 20), 19, bg);
    switch (id) {
      case 'que_chido':
        _tv(canvas);
      case 'va':
        _cassetteBot(canvas);
      case 'ya_voy':
        _car(canvas);
      case 'te_escucho':
        _earCreature(canvas);
      case 'cambio':
        _radio(canvas);
      case 'no_te_oigo':
        _bentAntennaBot(canvas);
      case 'jaja':
        _jelly(canvas);
      case 'no_manches':
        _axolotl(canvas);
      case 'que_paso':
        _ghost(canvas);
      case 'todo_bien':
        _frog(canvas);
      case 'buenas_noches':
        _moon(canvas);
      case 'abrazo':
        _hug(canvas);
      case 'vamos':
        _starRunner(canvas);
      case 'te_mmaste':
        _whistlePal(canvas);
      case 'todo_cool':
        _coolSprite(canvas);
    }
    canvas.restore();
  }

  void _line(Canvas c, Offset a, Offset b, Color color, [double width = 2]) {
    c.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  void _oval(Canvas c, Rect r, Color color, {Color? stroke, double width = 2}) {
    c.drawOval(
      r,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    if (stroke != null) {
      c.drawOval(
        r,
        Paint()
          ..color = stroke
          ..style = PaintingStyle.stroke
          ..strokeWidth = width,
      );
    }
  }

  void _round(Canvas c, Rect r, Color color, {double radius = 5}) {
    c.drawRRect(
      RRect.fromRectAndRadius(r, Radius.circular(radius)),
      Paint()..color = color,
    );
    c.drawRRect(
      RRect.fromRectAndRadius(r, Radius.circular(radius)),
      Paint()
        ..color = _outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _face(Canvas c, {double y = 20, Color ink = _outline}) {
    _oval(c, Rect.fromCircle(center: Offset(16, y), radius: 1.3), ink);
    _oval(c, Rect.fromCircle(center: Offset(24, y), radius: 1.3), ink);
    _line(c, Offset(16, y + 4), Offset(20, y + 6), ink, 1.8);
    _line(c, Offset(20, y + 6), Offset(24, y + 4), ink, 1.8);
  }

  void _tv(Canvas c) {
    _line(c, const Offset(16, 8), const Offset(12, 4), _cream);
    _line(c, const Offset(24, 8), const Offset(28, 4), _cream);
    _round(c, const Rect.fromLTWH(6, 8, 28, 24), const Color(0xFF58616D));
    _round(c, const Rect.fromLTWH(9, 11, 18, 17), _teal, radius: 3);
    _oval(c, const Rect.fromLTWH(29, 13, 3, 3), _cream);
    _oval(c, const Rect.fromLTWH(29, 20, 3, 3), _pink);
    _face(c, y: 18);
  }

  void _cassetteBot(Canvas c) {
    _round(c, const Rect.fromLTWH(8, 8, 24, 24), _blue, radius: 7);
    _round(c, const Rect.fromLTWH(12, 17, 16, 9), const Color(0xFF344453));
    _oval(c, const Rect.fromLTWH(14, 19, 4, 4), _cream);
    _oval(c, const Rect.fromLTWH(22, 19, 4, 4), _cream);
    _line(c, const Offset(8, 16), const Offset(4, 13), _pink, 3);
    _line(c, const Offset(32, 16), const Offset(36, 13), _pink, 3);
    _line(c, const Offset(14, 32), const Offset(12, 35), _cream, 2.5);
    _line(c, const Offset(26, 32), const Offset(28, 35), _cream, 2.5);
    _line(c, const Offset(17, 13), const Offset(23, 13), _outline, 1.5);
  }

  void _car(Canvas c) {
    _round(c, const Rect.fromLTWH(5, 17, 30, 12), const Color(0xFFFFA341));
    final top = Path()
      ..moveTo(11, 17)
      ..lineTo(15, 11)
      ..lineTo(25, 11)
      ..lineTo(30, 17)
      ..close();
    c.drawPath(top, Paint()..color = _teal);
    c.drawPath(
      top,
      Paint()
        ..color = _outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _oval(c, const Rect.fromLTWH(8, 25, 8, 8), _outline);
    _oval(c, const Rect.fromLTWH(25, 25, 8, 8), _outline);
    _oval(c, const Rect.fromLTWH(10, 27, 4, 4), _cream);
    _oval(c, const Rect.fromLTWH(27, 27, 4, 4), _cream);
    _round(c, const Rect.fromLTWH(6, 19, 4, 3), _cream, radius: 1);
  }

  void _earCreature(Canvas c) {
    _oval(c, const Rect.fromLTWH(5, 12, 12, 17), _pink, stroke: _outline);
    _oval(c, const Rect.fromLTWH(23, 12, 12, 17), _pink, stroke: _outline);
    _oval(c, const Rect.fromLTWH(9, 8, 22, 25), const Color(0xFFB88CFF),
        stroke: _outline);
    _face(c, y: 19);
    _oval(c, const Rect.fromLTWH(11, 24, 4, 2), _pink);
    _oval(c, const Rect.fromLTWH(25, 24, 4, 2), _pink);
  }

  void _radio(Canvas c) {
    _line(c, const Offset(12, 11), const Offset(8, 4), _cream);
    _round(c, const Rect.fromLTWH(7, 11, 26, 21), _teal, radius: 5);
    _round(c, const Rect.fromLTWH(10, 15, 13, 11), const Color(0xFF173B43),
        radius: 3);
    for (var i = 0; i < 5; i++) {
      final h = [4.0, 7.0, 10.0, 7.0, 4.0][i];
      _line(c, Offset(12 + i * 2.0, 22 - h / 2),
          Offset(12 + i * 2.0, 22 + h / 2), _cream, 1.3);
    }
    _oval(c, const Rect.fromLTWH(25, 16, 5, 5), _cream, stroke: _outline);
    _line(c, const Offset(25, 27), const Offset(30, 27), _outline, 1.5);
  }

  void _bentAntennaBot(Canvas c) {
    _line(c, const Offset(20, 9), const Offset(20, 4), _cream);
    _line(c, const Offset(20, 4), const Offset(27, 3), _cream);
    _line(c, const Offset(27, 3), const Offset(31, 7), _pink);
    _round(c, const Rect.fromLTWH(8, 11, 24, 21), const Color(0xFFA8B5C2),
        radius: 6);
    _oval(c, const Rect.fromLTWH(13, 17, 5, 5), _teal);
    _oval(c, const Rect.fromLTWH(23, 17, 5, 5), _pink);
    _line(c, const Offset(15, 27), const Offset(25, 27), _outline, 2);
  }

  void _jelly(Canvas c) {
    final p = Path()
      ..moveTo(8, 22)
      ..cubicTo(8, 8, 32, 8, 32, 22)
      ..lineTo(30, 30)
      ..lineTo(25, 27)
      ..lineTo(20, 31)
      ..lineTo(15, 27)
      ..lineTo(10, 30)
      ..close();
    c.drawPath(p, Paint()..color = const Color(0xFFFF78B6));
    c.drawPath(
      p,
      Paint()
        ..color = _outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _face(c, y: 19);
    _oval(c, const Rect.fromLTWH(12, 24, 4, 2), _cream);
    _oval(c, const Rect.fromLTWH(24, 24, 4, 2), _cream);
  }

  void _axolotl(Canvas c) {
    _oval(c, const Rect.fromLTWH(9, 12, 22, 21), _pink, stroke: _outline);
    for (final x in [7.0, 5.0, 8.0, 33.0, 35.0, 32.0]) {
      final left = x < 20;
      final side = left ? -1 : 1;
      final base = left ? 11.0 : 29.0;
      _line(c, Offset(base, 19 + (x % 3)), Offset(base + side * 4, 16 + (x % 5)),
          _pink, 2.6);
    }
    _face(c, y: 20);
    _oval(c, const Rect.fromLTWH(17, 25, 6, 3), _cream);
  }

  void _ghost(Canvas c) {
    final p = Path()
      ..moveTo(9, 30)
      ..lineTo(9, 18)
      ..cubicTo(9, 5, 31, 5, 31, 18)
      ..lineTo(31, 30)
      ..lineTo(26, 27)
      ..lineTo(21, 31)
      ..lineTo(15, 27)
      ..close();
    c.drawPath(p, Paint()..color = const Color(0xFFE2E9F7));
    c.drawPath(
      p,
      Paint()
        ..color = _outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _oval(c, const Rect.fromLTWH(14, 17, 3, 5), _outline);
    _oval(c, const Rect.fromLTWH(23, 17, 3, 5), _outline);
    _oval(c, const Rect.fromLTWH(18, 24, 4, 3), _pink);
  }

  void _frog(Canvas c) {
    _oval(c, const Rect.fromLTWH(7, 8, 12, 12), const Color(0xFF8EE26F),
        stroke: _outline);
    _oval(c, const Rect.fromLTWH(21, 8, 12, 12), const Color(0xFF8EE26F),
        stroke: _outline);
    _oval(c, const Rect.fromLTWH(8, 12, 24, 21), const Color(0xFF66C85A),
        stroke: _outline);
    _oval(c, const Rect.fromLTWH(11, 15, 8, 7), _cream, stroke: _outline);
    _oval(c, const Rect.fromLTWH(21, 15, 8, 7), _cream, stroke: _outline);
    _oval(c, const Rect.fromLTWH(14, 17, 2.5, 3.5), _outline);
    _oval(c, const Rect.fromLTWH(24, 17, 2.5, 3.5), _outline);
    _line(c, const Offset(15, 27), const Offset(25, 27), _outline, 1.8);
  }

  void _moon(Canvas c) {
    _oval(c, const Rect.fromLTWH(9, 7, 24, 26), const Color(0xFFFFD26E));
    _oval(c, const Rect.fromLTWH(17, 3, 21, 23), const Color(0xFF202833));
    _line(c, const Offset(14, 21), const Offset(18, 19), _outline, 1.7);
    _line(c, const Offset(23, 19), const Offset(27, 21), _outline, 1.7);
    _line(c, const Offset(17, 26), const Offset(23, 26), _pink, 1.5);
    _oval(c, const Rect.fromLTWH(7, 10, 2, 2), _cream);
    _oval(c, const Rect.fromLTWH(31, 29, 2, 2), _cream);
  }

  void _hug(Canvas c) {
    _oval(c, const Rect.fromLTWH(5, 12, 20, 21), _teal, stroke: _outline);
    _oval(c, const Rect.fromLTWH(16, 12, 20, 21), _pink, stroke: _outline);
    _oval(c, const Rect.fromLTWH(11, 20, 2.5, 2.5), _outline);
    _oval(c, const Rect.fromLTWH(18, 20, 2.5, 2.5), _outline);
    _oval(c, const Rect.fromLTWH(23, 20, 2.5, 2.5), _outline);
    _oval(c, const Rect.fromLTWH(30, 20, 2.5, 2.5), _outline);
    _line(c, const Offset(13, 27), const Offset(20, 30), _outline, 2);
    _line(c, const Offset(20, 30), const Offset(27, 27), _outline, 2);
    _line(c, const Offset(12, 31), const Offset(27, 31), _cream, 2.5);
  }

  void _starRunner(Canvas c) {
    _round(c, const Rect.fromLTWH(9, 12, 22, 21), const Color(0xFF43718C),
        radius: 8);
    _oval(c, const Rect.fromLTWH(11, 14, 18, 9), const Color(0xFFBDEAFF),
        stroke: _outline);
    _oval(c, const Rect.fromLTWH(14, 17, 3, 3), _outline);
    _oval(c, const Rect.fromLTWH(23, 17, 3, 3), _outline);
    final star = Path();
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? 5.0 : 2.3;
      final angle = -math.pi / 2 + i * math.pi / 5;
      final point = Offset(20 + math.cos(angle) * radius, 27 + math.sin(angle) * radius);
      if (i == 0) {
        star.moveTo(point.dx, point.dy);
      } else {
        star.lineTo(point.dx, point.dy);
      }
    }
    star.close();
    c.drawPath(star, Paint()..color = _cream);
    c.drawPath(
      star,
      Paint()
        ..color = _outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  void _whistlePal(Canvas c) {
    _oval(c, const Rect.fromLTWH(8, 8, 24, 25), const Color(0xFFFFB45C),
        stroke: _outline);
    _round(c, const Rect.fromLTWH(10, 7, 20, 7), _blue, radius: 3);
    _oval(c, const Rect.fromLTWH(13, 16, 4, 4), _outline);
    _oval(c, const Rect.fromLTWH(23, 16, 4, 4), _outline);
    _oval(c, const Rect.fromLTWH(16, 22, 8, 7), const Color(0xFF5A2634));
    _line(c, const Offset(29, 26), const Offset(35, 29), _cream, 2.5);
    _oval(c, const Rect.fromLTWH(32, 25, 5, 5), _teal, stroke: _outline);
  }

  void _coolSprite(Canvas c) {
    final p = Path()
      ..moveTo(9, 28)
      ..cubicTo(4, 22, 8, 12, 13, 12)
      ..cubicTo(17, 5, 28, 8, 29, 14)
      ..cubicTo(37, 17, 33, 29, 29, 31)
      ..close();
    c.drawPath(p, Paint()..color = _blue);
    c.drawPath(
      p,
      Paint()
        ..color = _outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _round(c, const Rect.fromLTWH(12, 8, 16, 6), _cream, radius: 3);
    _line(c, const Offset(13, 21), const Offset(18, 21), _outline, 2.2);
    _line(c, const Offset(22, 21), const Offset(27, 21), _outline, 2.2);
    _line(c, const Offset(18, 27), const Offset(22, 27), _pink, 2);
  }

  @override
  bool shouldRepaint(covariant _DidoRetroPainter oldDelegate) =>
      oldDelegate.id != id;
}
