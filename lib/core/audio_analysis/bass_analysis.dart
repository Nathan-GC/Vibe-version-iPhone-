import 'dart:math' as math;
import 'dart:typed_data';

/// Niveau RMS d'une fenêtre sans signal : `-inf`, `nan` ou valeur illisible
/// dans la sortie de FFmpeg. -120 dB est sous le plancher de bruit 16 bits.
const double kSilenceDb = -120;

/// Cadence des niveaux issus de FFmpeg : une fenêtre RMS de 10 ms.
const int kAnalysisRateHz = 100;

/// Nombre de fenêtres de 10 ms regroupées en un octet de l'enveloppe (40 ms,
/// soit 25 Hz) : assez fin pour suivre un kick, assez court pour tenir en ~6 Ko.
const int kEnvelopeGroup = 4;

// Sous ce niveau linéaire (≈ -100 dB), le p95 du morceau n'est que du bruit :
// le normaliser gonflerait un silence en signal plein échelle.
const double _silenceLinearFloor = 1e-5;

final RegExp _rmsLevelPattern = RegExp(r'lavfi\.astats\.Overall\.RMS_level=(\S+)');

/// Extrait, dans l'ordre, chaque niveau RMS (dB) de la sortie de
/// `ametadata=mode=print` (lignes `frame:N pts:… pts_time:…` suivies de lignes
/// `clé=valeur`). Les valeurs non numériques deviennent [kSilenceDb] plutôt
/// que d'être sautées, pour que l'index d'un niveau reste son instant (10 ms).
List<double> parseRmsLevelsDb(String output) {
  return [
    for (final RegExpMatch match in _rmsLevelPattern.allMatches(output)) _parseDb(match.group(1)!),
  ];
}

double _parseDb(String raw) {
  final double? value = double.tryParse(raw);
  // `-inf` est parsé en -Infinity par Dart, `nan` en NaN : ni l'un ni l'autre
  // n'est exploitable (puissance 10^x, comparaisons).
  if (value == null || value.isNaN || value.isInfinite) return kSilenceDb;
  return math.max(value, kSilenceDb);
}

/// Enveloppe des basses : un octet (0..255) par pas de 40 ms.
///
/// Niveau linéaire `10^(dB/20)`, maximum par groupe de [kEnvelopeGroup]
/// fenêtres, puis normalisation par le 95e centile du morceau (et non le
/// maximum, qu'un seul pic suffit à écraser) : un morceau calme et un morceau
/// mastérisé fort donnent la même dynamique visuelle. Un morceau silencieux
/// donne des zéros.
Uint8List bassEnvelopeFromDb(List<double> levelsDb100Hz) {
  final int steps = (levelsDb100Hz.length + kEnvelopeGroup - 1) ~/ kEnvelopeGroup;
  final List<double> grouped = List<double>.filled(steps, 0);
  for (int i = 0; i < levelsDb100Hz.length; i++) {
    final double linear = math.pow(10, levelsDb100Hz[i] / 20).toDouble();
    final int step = i ~/ kEnvelopeGroup;
    if (linear > grouped[step]) grouped[step] = linear;
  }

  final Uint8List envelope = Uint8List(steps);
  if (steps == 0) return envelope;

  final List<double> sorted = List<double>.of(grouped)..sort();
  final double reference = sorted[(steps * 0.95).floor().clamp(0, steps - 1)];
  if (reference < _silenceLinearFloor) return envelope;

  for (int i = 0; i < steps; i++) {
    envelope[i] = (math.min(1.0, grouped[i] / reference) * 255).round();
  }
  return envelope;
}

// Plage de BPM sondée par l'autocorrélation et plage d'affichage retenue.
const int _searchMinBpm = 60;
const int _searchMaxBpm = 180;
const double _foldMinBpm = 70;
const double _foldMaxBpm = 160;

// Moins de 10 s : trop peu de battements pour distinguer une pulsation.
const int _minSamples = 10 * kAnalysisRateHz;

// Rapport pic / décalage nul en dessous duquel il n'y a pas de pulsation nette
// (du bruit blanc plafonne vers 0,05-0,09 selon la durée).
const double _minPeakRatio = 0.15;

/// BPM estimé d'après les niveaux RMS à 100 Hz, ou null s'il n'y a pas de
/// pulsation nette (silence, bruit, morceau de moins de 10 s).
///
/// Force d'attaque (`max(0, e[i] - e[i-1])` sur l'énergie linéaire, moyenne
/// retirée), autocorrélation sur 60–180 BPM, interpolation parabolique du pic
/// puis repli sur l'octave [70 ; 160].
int? estimateBpm(List<double> levelsDb100Hz) {
  final int n = levelsDb100Hz.length;
  if (n < _minSamples) return null;

  final List<double> energy = [for (final double db in levelsDb100Hz) math.pow(10, db / 10).toDouble()];
  final List<double> onset = List<double>.filled(n, 0);
  double mean = 0;
  for (int i = 1; i < n; i++) {
    onset[i] = math.max(0, energy[i] - energy[i - 1]);
    mean += onset[i];
  }
  mean /= n;
  for (int i = 0; i < n; i++) {
    onset[i] -= mean;
  }

  double autocorrelation(int lag) {
    double sum = 0;
    for (int i = lag; i < n; i++) {
      sum += onset[i] * onset[i - lag];
    }
    return sum;
  }

  final double zeroLag = autocorrelation(0);
  if (zeroLag <= 0) return null;

  // Décalage = 6000 / BPM (échantillons à 100 Hz) ; une marge d'un pas de
  // chaque côté permet d'interpoler un pic situé en bordure de plage.
  final int minLag = (60 * kAnalysisRateHz / _searchMaxBpm).floor();
  final int maxLag = (60 * kAnalysisRateHz / _searchMinBpm).ceil();
  final Map<int, double> scores = {
    for (int lag = minLag - 1; lag <= maxLag + 1; lag++) lag: autocorrelation(lag) / zeroLag,
  };

  int bestLag = minLag;
  for (int lag = minLag; lag <= maxLag; lag++) {
    if (scores[lag]! > scores[bestLag]!) bestLag = lag;
  }
  if (scores[bestLag]! < _minPeakRatio) return null;

  // Un train régulier corrèle aussi à 2×, 3×… la période, avec un score à peine
  // plus faible : sans cette vérification, un bruit léger suffit à faire élire
  // la période double (BPM divisé par deux). On préfère la demi-période si elle
  // porte presque autant de corrélation.
  final int halfLag = (bestLag / 2).round();
  if (halfLag >= minLag) {
    int halfBest = halfLag;
    for (int lag = halfLag - 1; lag <= halfLag + 1; lag++) {
      if (lag >= minLag && scores[lag]! > scores[halfBest]!) halfBest = lag;
    }
    if (scores[halfBest]! >= 0.8 * scores[bestLag]!) bestLag = halfBest;
  }

  // Interpolation parabolique : la période réelle (ex. 46,875 échantillons à
  // 128 BPM) tombe entre deux décalages entiers.
  double refinedLag = bestLag.toDouble();
  final double? before = scores[bestLag - 1];
  final double? after = scores[bestLag + 1];
  if (before != null && after != null) {
    final double denominator = before - 2 * scores[bestLag]! + after;
    if (denominator < 0) refinedLag += 0.5 * (before - after) / denominator;
  }

  double bpm = 60 * kAnalysisRateHz / refinedLag;
  while (bpm < _foldMinBpm) {
    bpm *= 2;
  }
  while (bpm > _foldMaxBpm) {
    bpm /= 2;
  }
  return bpm.round();
}

/// BPM utilisé par les animations : `tracks.bpm` vaut 120 par défaut, ce qui est
/// indiscernable d'un tag réellement absent — l'estimation hors ligne ne le
/// remplace donc que dans ce cas.
///
/// shortcut: un vrai tag à 120 est remplacé par l'estimation, à revoir si la colonne bpm devient nullable
double effectiveBpm(int tagBpm, int? estimatedBpm) {
  if (estimatedBpm != null && estimatedBpm != 0 && tagBpm == 120) return estimatedBpm.toDouble();
  return tagBpm.toDouble();
}
