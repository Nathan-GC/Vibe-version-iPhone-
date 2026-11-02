import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

/// Zone colorée dominante d'une image, en coordonnées normalisées (0..1).
/// Sert au shader de la Vibe "Behind the window" : le centre de chaque zone
/// scintille doucement et ses contours diffusent la couleur, comme un néon
/// dans le brouillard.
class WindowColorZone {
  const WindowColorZone({
    required this.x,
    required this.y,
    required this.radius,
    required this.color,
    required this.weight,
  });

  /// Centre : 0 = gauche, 1 = droite.
  final double x;

  /// Centre : 0 = haut, 1 = bas.
  final double y;

  /// Rayon normalisé : fraction de la plus petite dimension de l'image.
  final double radius;

  /// Couleur moyenne de la zone (opaque).
  final Color color;

  /// Importance relative 0..1 (la zone la plus forte vaut 1).
  final double weight;
}

// 12 tranches de 30° : assez fines pour séparer un néon rose d'un néon cyan,
// assez larges pour qu'un dégradé de teinte reste dans une seule zone.
const int _hueSlices = 12;
const int _grid = 8;

// Seuils "lumineux et coloré" : un ciel gris, un mur sombre ou une photo noir
// et blanc ne doivent rien faire scintiller.
const double _minValue = 0.35;
const double _minSaturation = 0.25;

// Une tranche de teinte n'est retenue que si elle pèse au moins 0,6 % du nombre
// de pixels (~25 px pleins sur 64×64), sinon quelques pixels isolés (bruit)
// créeraient des zones fantômes. Pas plus : une enseigne néon est souvent
// petite sur une photo de nuit, c'est justement elle qui doit scintiller.
const double _minSliceShare = 0.006;

// Un second pic dans une tranche doit atteindre 35 % du plus fort : on évite
// de scintiller sur la simple épaule d'une zone déjà prise.
const double _minPeakShare = 0.35;
const int _peaksPerSlice = 2;

const double _minRadius = 0.06;
const double _maxRadius = 0.35;

/// Extrait au plus [maxZones] zones colorées dominantes de [rgba] (octets RGBA
/// bruts, longueur `width * height * 4`).
///
/// Pure et déterministe, sans I/O : appelée une seule fois par image (version
/// réduite à ~64×64, dans un isolate via `compute`), jamais par frame. Toute
/// entrée incohérente donne une liste vide plutôt qu'une exception : le
/// décodage peut échouer silencieusement en amont, l'effet se désactive alors
/// simplement.
List<WindowColorZone> analyzeWindowColorZones(
  Uint8List rgba,
  int width,
  int height, {
  int maxZones = 6,
}) {
  if (maxZones <= 0 || width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    return const [];
  }
  final pixelCount = width * height;

  // Passe 1 : tranche de teinte (-1 = pixel ignoré) et poids saturation × valeur
  // de chaque pixel, cumulés par tranche et par cellule de la grille 8×8.
  final slice = Int8List(pixelCount);
  final weight = Float64List(pixelCount);
  final sliceWeight = Float64List(_hueSlices);
  final cells = Float64List(_hueSlices * _grid * _grid);
  for (var i = 0; i < pixelCount; i++) {
    slice[i] = -1;
    final r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
    final maxC = math.max(r, math.max(g, b));
    final delta = maxC - math.min(r, math.min(g, b));
    if (maxC == 0) continue;
    final value = maxC / 255;
    final saturation = delta / maxC;
    if (value < _minValue || saturation < _minSaturation) continue;

    // Teinte HSV en sixièmes de cercle ([0, 6[), puis en tranches de 30°.
    final double sextant;
    if (maxC == r) {
      sextant = ((g - b) / delta) % 6;
    } else if (maxC == g) {
      sextant = (b - r) / delta + 2;
    } else {
      sextant = (r - g) / delta + 4;
    }
    final s = math.min((sextant * 2).floor(), _hueSlices - 1);
    final w = saturation * value;
    slice[i] = s;
    weight[i] = w;
    sliceWeight[s] += w;
    final x = i % width, y = i ~/ width;
    cells[(s * _grid + y * _grid ~/ height) * _grid + x * _grid ~/ width] += w;
  }

  // Passe 2 : jusqu'à deux pics par tranche retenue.
  final minSliceWeight = _minSliceShare * pixelCount;
  final candidates = <_RawZone>[];
  for (var s = 0; s < _hueSlices; s++) {
    if (sliceWeight[s] < minSliceWeight) continue;
    for (final peak in _findPeaks(cells, s)) {
      final zone = _measureZone(rgba, slice, weight, width, height, s, peak % _grid, peak ~/ _grid);
      if (zone != null) candidates.add(zone);
    }
  }
  if (candidates.isEmpty) return const [];

  // Poids décroissant ; départage par position pour un ordre indépendant de
  // l'implémentation de `sort` (déterminisme).
  candidates.sort((a, b) {
    final byWeight = b.weight.compareTo(a.weight);
    if (byWeight != 0) return byWeight;
    final byY = a.y.compareTo(b.y);
    return byY != 0 ? byY : a.x.compareTo(b.x);
  });
  final top = candidates.take(maxZones).toList();
  final strongest = top.first.weight;
  return [
    for (final z in top)
      WindowColorZone(
        x: z.x,
        y: z.y,
        radius: z.radius,
        color: z.color,
        weight: z.weight / strongest,
      ),
  ];
}

/// Indices (`cy * 8 + cx`) des pics de la tranche [s] : maxima locaux de la
/// grille, au-dessus du seuil relatif, non adjacents entre eux (un disque qui
/// chevauche plusieurs cellules ne doit donner qu'un pic).
List<int> _findPeaks(Float64List cells, int s) {
  final base = s * _grid * _grid;
  double at(int cx, int cy) =>
      cx < 0 || cy < 0 || cx >= _grid || cy >= _grid ? 0 : cells[base + cy * _grid + cx];

  var strongest = 0.0;
  for (var c = 0; c < _grid * _grid; c++) {
    strongest = math.max(strongest, cells[base + c]);
  }
  final threshold = strongest * _minPeakShare;

  final order = [for (var c = 0; c < _grid * _grid; c++) c]
    ..sort((a, b) {
      final byWeight = cells[base + b].compareTo(cells[base + a]);
      return byWeight != 0 ? byWeight : a.compareTo(b);
    });

  final peaks = <int>[];
  for (final c in order) {
    if (peaks.length == _peaksPerSlice) break;
    final cx = c % _grid, cy = c ~/ _grid;
    final w = cells[base + c];
    if (w <= 0 || w < threshold) break; // trié : les suivants sont plus faibles
    var isLocalMax = true;
    for (var dy = -1; dy <= 1 && isLocalMax; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if ((dx != 0 || dy != 0) && at(cx + dx, cy + dy) > w) {
          isLocalMax = false;
          break;
        }
      }
    }
    if (!isLocalMax) continue;
    final adjacent = peaks.any((p) => (p % _grid - cx).abs() <= 1 && (p ~/ _grid - cy).abs() <= 1);
    if (!adjacent) peaks.add(c);
  }
  return peaks;
}

/// Mesure la zone autour de la cellule pic ([cx], [cy]) : barycentre, étalement
/// et couleur moyenne des pixels de la tranche [s] dans le voisinage 3×3.
_RawZone? _measureZone(
  Uint8List rgba,
  Int8List slice,
  Float64List weight,
  int width,
  int height,
  int s,
  int cx,
  int cy,
) {
  final x0 = math.max(cx - 1, 0) * width ~/ _grid;
  final x1 = math.min(cx + 2, _grid) * width ~/ _grid;
  final y0 = math.max(cy - 1, 0) * height ~/ _grid;
  final y1 = math.min(cy + 2, _grid) * height ~/ _grid;

  var sumW = 0.0, sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0;
  var sumR = 0.0, sumG = 0.0, sumB = 0.0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = y * width + x;
      if (slice[i] != s) continue;
      final w = weight[i];
      final px = x + 0.5, py = y + 0.5; // centre du pixel, en pixels
      sumW += w;
      sumX += w * px;
      sumY += w * py;
      sumXX += w * px * px;
      sumYY += w * py * py;
      sumR += w * rgba[i * 4];
      sumG += w * rgba[i * 4 + 1];
      sumB += w * rgba[i * 4 + 2];
    }
  }
  if (sumW <= 0) return null;

  final meanX = sumX / sumW, meanY = sumY / sumW;
  // Variance radiale pondérée (clampée : l'arrondi flottant peut la rendre
  // légèrement négative). Pour un disque plein de rayon R elle vaut R²/2, d'où
  // le ×2 : le rayon rendu est celui du disque, pas son écart-type.
  final variance = math.max(0.0, sumXX / sumW - meanX * meanX) + math.max(0.0, sumYY / sumW - meanY * meanY);
  final radius = (math.sqrt(2 * variance) / math.min(width, height)).clamp(_minRadius, _maxRadius);

  return _RawZone(
    x: meanX / width,
    y: meanY / height,
    radius: radius,
    color: Color.fromARGB(255, (sumR / sumW).round(), (sumG / sumW).round(), (sumB / sumW).round()),
    weight: sumW,
  );
}

/// Zone avant normalisation : `weight` est encore le poids cumulé brut.
class _RawZone {
  const _RawZone({
    required this.x,
    required this.y,
    required this.radius,
    required this.color,
    required this.weight,
  });

  final double x;
  final double y;
  final double radius;
  final Color color;
  final double weight;
}
