/// Builds `assets/icon/icon_ios.png` (full-bleed, fully opaque) from
/// `assets/icon/icon.png`. iOS launcher icons must be opaque squares — the
/// system applies its own squircle mask — so the source's transparent
/// rounded-rect corners are filled with the nearest *interior* background
/// color from the same column. The art has a thin gray outline along the
/// rounded edge, so fill colors are picked from pixels eroded 3px inward;
/// that keeps the fills on the background gradient instead of the outline.
/// Anti-aliased edge pixels are composited over the fill, then alpha is
/// forced opaque.
///
/// Run from the repo root: `dart run tool/make_ios_icon.dart`
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

void main() {
  const srcPath = 'assets/icon/icon.png';
  const outPath = 'assets/icon/icon_ios.png';
  final bytes = File(srcPath).readAsBytesSync();
  final src = img.decodeImage(bytes);
  if (src == null) {
    stderr.writeln('failed to decode $srcPath');
    exit(1);
  }
  final out = img.Image.from(src);
  final w = src.width;
  final h = src.height;

  final opaque = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (src.getPixel(x, y).a.toInt() == 255) opaque[y * w + x] = 1;
    }
  }

  // Pixels >=3px (Chebyshev) away from any transparency — i.e. past the
  // outline and its anti-aliasing band.
  bool isInterior(int x, int y) {
    for (var dy = -3; dy <= 3; dy++) {
      final yy = y + dy;
      if (yy < 0 || yy >= h) return false;
      for (var dx = -3; dx <= 3; dx++) {
        final xx = x + dx;
        if (xx < 0 || xx >= w || opaque[yy * w + xx] == 0) return false;
      }
    }
    return true;
  }

  for (var x = 0; x < w; x++) {
    final interiorCol = Uint8List(h);
    for (var y = 0; y < h; y++) {
      if (isInterior(x, y)) interiorCol[y] = 1;
    }

    // Nearest interior pixel above/below in this column, as (y, r, g, b).
    (int, int, int, int)? above;
    (int, int, int, int)? below;
    final tops = List<(int, int, int, int)?>.filled(h, null);
    for (var y = 0; y < h; y++) {
      if (interiorCol[y] == 1) {
        final p = src.getPixel(x, y);
        above = (y, p.r.toInt(), p.g.toInt(), p.b.toInt());
      }
      tops[y] = above;
    }
    final bottoms = List<(int, int, int, int)?>.filled(h, null);
    for (var y = h - 1; y >= 0; y--) {
      if (interiorCol[y] == 1) {
        final p = src.getPixel(x, y);
        below = (y, p.r.toInt(), p.g.toInt(), p.b.toInt());
      }
      bottoms[y] = below;
    }

    for (var y = 0; y < h; y++) {
      final p = src.getPixel(x, y);
      final alpha = p.a.toInt();
      if (alpha == 255) continue;
      final fromTop = tops[y];
      final fromBottom = bottoms[y];
      // Prefer the nearer interior pixel so the fill follows the gradient.
      (int, int, int, int)? fill;
      if (fromTop != null && fromBottom != null) {
        fill = (y - fromTop.$1 <= fromBottom.$1 - y) ? fromTop : fromBottom;
      } else {
        fill = fromTop ?? fromBottom;
      }
      if (fill == null) continue; // no interior in this column: leave as-is
      final (_, fr, fg, fb) = fill;
      final blended = alpha == 0
          ? (fr, fg, fb)
          : (
              (p.r.toInt() * alpha + fr * (255 - alpha)) ~/ 255,
              (p.g.toInt() * alpha + fg * (255 - alpha)) ~/ 255,
              (p.b.toInt() * alpha + fb * (255 - alpha)) ~/ 255,
            );
      out.setPixelRgba(x, y, blended.$1, blended.$2, blended.$3, 255);
    }
  }

  File(outPath).writeAsBytesSync(img.encodePng(out));
  stdout.writeln('wrote $outPath (${w}x$h, opaque)');
}
