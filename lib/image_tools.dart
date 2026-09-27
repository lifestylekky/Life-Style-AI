import 'dart:typed_data';

import 'package:image/image.dart' as img;

Uint8List buildReferenceBoard(List<Uint8List> sources) {
  final decoded = sources
      .map(img.decodeImage)
      .whereType<img.Image>()
      .toList(growable: false);
  if (decoded.isEmpty) {
    throw const FormatException('No valid reference images were available.');
  }
  if (decoded.length == 1) {
    return Uint8List.fromList(img.encodeJpg(decoded.first, quality: 92));
  }

  final columns = decoded.length <= 4 ? 2 : 3;
  const tileSize = 512;
  const gap = 18;
  final rows = (decoded.length / columns).ceil();
  final board = img.Image(
    width: columns * tileSize + (columns + 1) * gap,
    height: rows * tileSize + (rows + 1) * gap,
  );
  img.fill(board, color: img.ColorRgb8(245, 245, 242));

  for (var index = 0; index < decoded.length; index++) {
    final source = decoded[index];
    final scale =
        tileSize /
        (source.width > source.height ? source.width : source.height);
    final resized = img.copyResize(
      source,
      width: (source.width * scale).round(),
      height: (source.height * scale).round(),
      interpolation: img.Interpolation.cubic,
    );
    final column = index % columns;
    final row = index ~/ columns;
    final x = gap + column * (tileSize + gap) + (tileSize - resized.width) ~/ 2;
    final y = gap + row * (tileSize + gap) + (tileSize - resized.height) ~/ 2;
    img.compositeImage(board, resized, dstX: x, dstY: y);
  }

  return Uint8List.fromList(img.encodeJpg(board, quality: 88));
}
