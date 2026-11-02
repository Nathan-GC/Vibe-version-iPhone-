import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../core/theme/vibe_engine/window_color_zones.dart';

/// Plus grand côté décodé de l'image "Behind the window". Au-delà, on paie la
/// mémoire GPU (2048×1536 ≈ 12 Mo) sans gain visible derrière la pluie et la
/// buée.
const int kWindowMaxDecodeSide = 2048;

/// Largeur de la miniature floue de la buée. Valeur reprise telle quelle par
/// vibe_particles.frag (taille d'un texel de uBackdropBlur) : les deux doivent
/// changer ensemble.
const int kWindowBlurWidth = 48;

/// Côté de l'échantillon carré analysé pour les zones colorées : assez pour
/// trouver une enseigne, assez petit pour une analyse quasi instantanée.
const int kWindowZoneSampleSize = 64;

/// Nombre d'emplacements de zones du shader (uZoneShape[6] / uZoneColor[6]).
const int kWindowMaxZones = 6;

/// Taille de décodage (largeur, hauteur) de l'image de [imageWidth]×[imageHeight]
/// pour couvrir un écran de [screenPixels] pixels physiques, comme
/// `BoxFit.cover` : proportions gardées, plus grand côté borné à [maxSide].
///
/// Une photo de 12 Mpx décodée telle quelle pèse ~48 Mo : la décoder
/// directement à cette taille divise la mémoire par 4 à 10. Jamais
/// d'agrandissement : décoder plus grand que la source n'ajoute aucun détail.
/// Écran vide (premier layout, tests) : seule la borne s'applique.
(int, int) windowDecodeSize(int imageWidth, int imageHeight, ui.Size screenPixels, {int maxSide = kWindowMaxDecodeSide}) {
  if (imageWidth <= 0 || imageHeight <= 0) return (1, 1);
  double scale = screenPixels.isEmpty
      ? 1
      : math.max(screenPixels.width / imageWidth, screenPixels.height / imageHeight);
  scale = math.min(scale, 1);
  scale = math.min(scale, maxSide / math.max(imageWidth, imageHeight));
  return (math.max(1, (imageWidth * scale).round()), math.max(1, (imageHeight * scale).round()));
}

/// Vrai quand la taille cible [target] s'écarte nettement (plus de 20 % sur le
/// plus grand côté) de la taille [current] déjà décodée. Une rotation d'écran
/// donne souvent la même taille (borne à 2048) ou presque : on garde alors
/// l'image plutôt que de tout redécoder pour quelques pixels.
bool windowDecodeSizeChanged((int, int) current, (int, int) target) {
  final int currentSide = math.max(current.$1, current.$2);
  final int targetSide = math.max(target.$1, target.$2);
  return (targetSide - currentSide).abs() > currentSide * 0.2;
}

/// Valeurs d'uniforms des zones, dans l'ordre déclaré par vibe_particles.frag :
/// 6 × (x, y, rayon, poids) pour uZoneShape, puis 6 × (r, g, b, 0) pour
/// uZoneColor. Toujours 48 valeurs : les emplacements sans zone restent à 0, et
/// un poids nul suffit au shader pour les sauter.
List<double> windowZoneUniforms(List<WindowColorZone> zones) {
  final List<double> values = List<double>.filled(kWindowMaxZones * 8, 0);
  for (int i = 0; i < math.min(zones.length, kWindowMaxZones); i++) {
    final WindowColorZone zone = zones[i];
    values
      ..[i * 4] = zone.x
      ..[i * 4 + 1] = zone.y
      ..[i * 4 + 2] = zone.radius
      ..[i * 4 + 3] = zone.weight
      ..[(kWindowMaxZones + i) * 4] = zone.color.r
      ..[(kWindowMaxZones + i) * 4 + 1] = zone.color.g
      ..[(kWindowMaxZones + i) * 4 + 2] = zone.color.b;
  }
  return values;
}

/// Uniforms des zones quand il n'y en a aucune (pas d'image, autres presets).
final List<double> kNoWindowZoneUniforms = windowZoneUniforms(const []);

/// Intensité 0..1 du scintillement des zones : le niveau des basses quand son
/// enveloppe est prête, sinon la pulsation du tempo. `pulse` est une dent de
/// scie (retour brutal à 0 à chaque battement) : la cloche `0,5 − 0,5·cos`
/// culmine à mi-battement et vaut la même chose aux deux bords, sans saut.
double windowNeonDrive(double? bassLevel, double pulse) {
  if (bassLevel != null) return bassLevel.clamp(0.0, 1.0);
  return 0.5 - 0.5 * math.cos(2 * math.pi * pulse);
}

/// Vitesse du scintillement : proportionnelle au tempo (1 à 120 BPM), bornée
/// pour qu'un morceau très lent reste vivant et qu'un très rapide ne tourne
/// pas au clignotement.
double windowNeonSpeed(double bpm) => (bpm / 120).clamp(0.6, 1.8);

/// Image "Behind the window" prête à peindre : image à la taille de l'écran
/// (Couche 1 et réfraction des gouttes), miniature floue (buée) et zones
/// colorées déjà converties en uniforms. Tout est calculé une fois par image,
/// jamais par frame.
class WindowBackdrop {
  WindowBackdrop._({
    required this.path,
    required this.image,
    required this.blurImage,
    required this.zoneUniforms,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final String path;
  final ui.Image image;
  final ui.Image blurImage;
  final List<double> zoneUniforms;
  // Taille native du fichier : permet de recalculer la taille cible après une
  // rotation sans relire ni redécoder le fichier.
  final int sourceWidth;
  final int sourceHeight;

  (int, int) get decodeSize => (image.width, image.height);

  void dispose() {
    image.dispose();
    blurImage.dispose();
  }
}

/// Lit et décode l'image de [path] pour un écran de [screenPixels] pixels
/// physiques. Renvoie `null` si le fichier est absent, illisible ou d'un format
/// non supporté : l'appelant garde alors l'aplat nuit, sans exception.
///
/// Un seul descripteur pour trois décodages réduits (écran, miniature de buée,
/// échantillon des zones) : le fichier n'est lu qu'une fois et l'image n'est
/// jamais décodée en pleine résolution.
Future<WindowBackdrop?> loadWindowBackdrop(String path, ui.Size screenPixels) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Image? image;
  ui.Image? blurImage;
  try {
    // Le chemin vient de la base : seule son existence est vérifiée, le
    // décodeur rejette de lui-même tout ce qui n'est pas une image.
    final File file = File(path);
    if (!await file.exists()) return null;
    buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final int sourceWidth = descriptor.width;
    final int sourceHeight = descriptor.height;
    final (int width, int height) = windowDecodeSize(sourceWidth, sourceHeight, screenPixels);
    image = await _decodeFrame(descriptor, width, height);
    // Hauteur omise : le décodeur garde les proportions, donc la même UV
    // `cover` que l'image écran tombe sur le même endroit de la photo.
    blurImage = await _decodeFrame(descriptor, kWindowBlurWidth, null);
    final List<double> zoneUniforms = windowZoneUniforms(await _analyzeZones(descriptor));
    final WindowBackdrop backdrop = WindowBackdrop._(
      path: path,
      image: image,
      blurImage: blurImage,
      zoneUniforms: zoneUniforms,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    // Les images appartiennent désormais au résultat : le catch ne doit plus
    // les libérer.
    image = null;
    blurImage = null;
    return backdrop;
  } catch (_) {
    image?.dispose();
    blurImage?.dispose();
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<ui.Image> _decodeFrame(ui.ImageDescriptor descriptor, int? width, int? height) async {
  final ui.Codec codec = await descriptor.instantiateCodec(targetWidth: width, targetHeight: height);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

/// Zones colorées sur un échantillon 64×64 (proportions écrasées : l'analyse
/// travaille en coordonnées normalisées, et le rayon reste une fraction du
/// plus petit côté). L'échantillon est libéré dès ses octets lus ; l'analyse
/// part dans un isolate pour ne jamais saccader le thread UI. Un échec ici
/// prive seulement l'image de ses zones, il ne doit pas la faire disparaître.
Future<List<WindowColorZone>> _analyzeZones(ui.ImageDescriptor descriptor) async {
  try {
    final ui.Image sample = await _decodeFrame(descriptor, kWindowZoneSampleSize, kWindowZoneSampleSize);
    final ByteData? data;
    try {
      data = await sample.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      sample.dispose();
    }
    if (data == null) return const [];
    return await compute(_analyzeZoneSample, data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  } catch (_) {
    return const [];
  }
}

List<WindowColorZone> _analyzeZoneSample(Uint8List rgba) =>
    analyzeWindowColorZones(rgba, kWindowZoneSampleSize, kWindowZoneSampleSize, maxZones: kWindowMaxZones);
