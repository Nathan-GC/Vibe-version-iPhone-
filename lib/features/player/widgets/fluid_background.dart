import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../../core/animation/tempo_sync/tempo_sync_controller.dart';
import '../../../core/shared/widgets/local_cover_image.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import 'window_backdrop.dart';

/// Fond animé du Player (Étape 3) : la palette dominante de la pochette en
/// cours (`palette_generator`) remplace les couleurs de la Vibe active dès
/// qu'elle est disponible — repli sur `vibe.gradientColors` sans pochette ou
/// si l'extraction échoue (réseau HS, image illisible...). Les halos dérivent
/// en continu et pulsent au rythme du BPM (TempoSyncController, déjà utilisé
/// par l'ancien fond pulsé).
///
/// Superpose en plus, quand le preset de la Vibe a un style dédié (voir
/// `VibeParticleStyle`), une couche de particules audio-réactives rendue via
/// un shader GLSL (Vibe Engine — particules). Le chargement du shader est
/// asynchrone et peut échouer (device/plateforme sans support) : dans ce cas
/// le dégradé/halos existants restent affichés seuls, sans erreur visible.
///
/// Cas particulier `VibePreset.neon` ("Behind the window", structure
/// volontairement simple à 2 couches) : Couche 1 = l'image importée par
/// l'utilisateur (`VibeVisual.windowImagePath`, voir window_backdrop.dart),
/// aplat nocturne sans image ou tant qu'elle se décode ; Couche 2 = le shader
/// en semi-transparence par-dessus, qui ne gère que buée des bords, pluie qui
/// ruisselle et scintillement des zones colorées de l'image au rythme des
/// basses — jamais de dégradé/halos procéduraux ni de transition (pas de
/// flash) pour ce preset.
///
/// Effet "Fluide" du Vibe Creator (`VibePreset.custom` +
/// `VibeCustomEffect.fluid`) : turbulence bicolore plein écran rendue par
/// assets/shaders/fluid_turbulence.frag (voir [fluidTurbulenceColors]). Les
/// presets figés gardent les halos historiques (`_paintFluidBlobs`), qui
/// servent aussi de repli tant que ce shader n'est pas prêt ou s'il échoue.
class FluidBackground extends StatefulWidget {
  const FluidBackground({
    super.key,
    required this.tempoController,
    required this.vibe,
    required this.coverArtPath,
    required this.child,
    this.coverKey,
  });

  final TempoSyncController tempoController;
  final VibeVisual vibe;
  final String? coverArtPath;
  final Widget child;
  // Clé posée sur la pochette affichée par le Player (MasterPlayerScreen) :
  // la nébuleuse Space se centre sur SA position réelle à l'écran (suit le
  // swipe vers la Queue, le flottement du mode Focus...), pas sur le centre
  // du canvas. Absente ou pochette masquée : repli sur une position fixe.
  final GlobalKey? coverKey;

  @override
  State<FluidBackground> createState() => _FluidBackgroundState();
}

class _FluidBackgroundState extends State<FluidBackground> with SingleTickerProviderStateMixin {
  // Partagés par toutes les instances : les shaders ne dépendent pas d'un état
  // propre à une playlist, inutile de les recompiler à chaque ouverture du Player.
  static Future<ui.FragmentProgram>? _shaderProgramFuture;
  static Future<ui.FragmentProgram>? _nebulaProgramFuture;
  static Future<ui.FragmentProgram>? _turbulenceProgramFuture;
  static Future<ui.Image>? _dummySamplerImageFuture;
  // Cache à une seule entrée de l'image "Behind the window" (image écran,
  // miniature de buée, zones), partagé comme les shaders : rouvrir le Player
  // sur la même playlist ne redécode rien. Remplacé seulement quand le chemin
  // ou, nettement, la taille cible change (voir _syncWindowBackdrop).
  static WindowBackdrop? _windowBackdrop;
  // Zap rapide (même principe que _maybeExtractPalette) : seul le dernier
  // chargement demandé peut remplir le cache, un plus lent parti avant est
  // jeté. La clé évite de relancer le même chargement à chaque rebuild — y
  // compris après un échec, qu'il serait inutile de répéter à chaque frame.
  static int _windowRequestId = 0;
  static String? _windowPendingKey;

  late final AnimationController _driftController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

  List<Color>? _paletteColors;
  String? _paletteSourcePath;
  ui.FragmentShader? _shader;
  // Nébuleuse FBM du preset Space (assets/shaders/space_nebula.frag) —
  // chargée uniquement quand Space est affiché au moins une fois ; tant
  // qu'elle n'est pas prête (ou si elle échoue), `_paintNebula` retombe sur
  // un halo radial dessiné au Canvas, centré au même endroit.
  ui.FragmentShader? _nebulaShader;
  // Turbulence de custom + fluid (assets/shaders/fluid_turbulence.frag) —
  // même schéma que la nébuleuse : chargée seulement si cette Vibe est
  // affichée, halos historiques en attendant ou en cas d'échec.
  ui.FragmentShader? _turbulenceShader;
  // Clé du CustomPaint lui-même : référence de coordonnées pour convertir la
  // position de la pochette (voir _coverCenterInCanvas).
  final GlobalKey _paintKey = GlobalKey();
  ui.Image? _dummySamplerImage;
  // Temps du scintillement des zones, intégré frame par frame à la vitesse
  // du tempo (voir uNeonPhase dans vibe_particles.frag) : multiplier le temps
  // total par la vitesse ferait sauter la phase à chaque changement de BPM.
  double _neonPhase = 0;
  double? _neonClock;

  @override
  void initState() {
    super.initState();
    _maybeExtractPalette();
    _loadShader();
    // Sampler factice : nécessaire à TOUS les presets (`setImageSampler`
    // exige une image non nulle dès que le shader dessine quoi que ce soit,
    // y compris retro/organic/oled qui ne lisent jamais uBackdrop) — chargé
    // sans condition.
    _loadDummySamplerImage();
    if (widget.vibe.preset == VibePreset.oled) _loadNebulaShader();
    if (_isCustomFluid) _loadTurbulenceShader();
  }

  @override
  void didUpdateWidget(covariant FluidBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverArtPath != widget.coverArtPath) _maybeExtractPalette();
    if (widget.vibe.preset == VibePreset.oled && _nebulaShader == null) _loadNebulaShader();
    if (_isCustomFluid && _turbulenceShader == null) _loadTurbulenceShader();
    _syncWindowBackdrop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Premier affichage, puis changement de taille d'écran (rotation).
    _syncWindowBackdrop();
  }

  /// Lance le décodage de l'image "Behind the window" si le cache ne
  /// correspond pas déjà au chemin et à la taille de l'écran (pixels
  /// physiques, pour une image nette sans en décoder plus que l'écran).
  void _syncWindowBackdrop() {
    final String? path = widget.vibe.preset == VibePreset.neon ? widget.vibe.windowImagePath : null;
    if (path == null || path.isEmpty) return;
    final Size screen = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
    final WindowBackdrop? cached = _windowBackdrop;
    if (cached != null &&
        cached.path == path &&
        !windowDecodeSizeChanged(
          cached.decodeSize,
          windowDecodeSize(cached.sourceWidth, cached.sourceHeight, screen),
        )) {
      return;
    }
    final String key = '$path|${screen.width.round()}x${screen.height.round()}';
    if (key == _windowPendingKey) return;
    _windowPendingKey = key;
    _loadWindowBackdrop(path, screen, ++_windowRequestId);
  }

  Future<void> _loadWindowBackdrop(String path, Size screen, int requestId) async {
    final WindowBackdrop? loaded = await loadWindowBackdrop(path, screen);
    if (requestId != _windowRequestId) {
      loaded?.dispose();
      return;
    }
    // Échec (fichier absent, illisible, format non supporté) : l'aplat nuit
    // reste affiché, et la clé en attente empêche de réessayer en boucle.
    if (loaded == null) return;
    final WindowBackdrop? previous = _windowBackdrop;
    _windowBackdrop = loaded;
    if (mounted) setState(() {});
    // L'ancienne image n'est libérée qu'après la frame qui affiche déjà la
    // nouvelle : RawImage et le sampler du shader ne doivent jamais peindre
    // une ui.Image disposée.
    if (previous != null) {
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => previous.dispose())
        ..ensureVisualUpdate();
    }
  }

  /// Image du cache, seulement si c'est bien celle de la Vibe affichée.
  WindowBackdrop? get _currentWindowBackdrop {
    final WindowBackdrop? backdrop = _windowBackdrop;
    if (widget.vibe.preset != VibePreset.neon || backdrop == null) return null;
    return backdrop.path == widget.vibe.windowImagePath ? backdrop : null;
  }

  bool get _isCustomFluid => widget.vibe.preset == VibePreset.custom && widget.vibe.effect == VibeCustomEffect.fluid;

  Future<void> _loadTurbulenceShader() async {
    try {
      _turbulenceProgramFuture ??= ui.FragmentProgram.fromAsset('assets/shaders/fluid_turbulence.frag');
      final ui.FragmentProgram program = await _turbulenceProgramFuture!;
      if (!mounted || _turbulenceShader != null) return;
      setState(() => _turbulenceShader = program.fragmentShader());
    } catch (_) {
      // Dégradation silencieuse : halos historiques (voir _paintFluidBlobs).
    }
  }

  Future<void> _loadNebulaShader() async {
    try {
      _nebulaProgramFuture ??= ui.FragmentProgram.fromAsset('assets/shaders/space_nebula.frag');
      final ui.FragmentProgram program = await _nebulaProgramFuture!;
      if (!mounted || _nebulaShader != null) return;
      setState(() => _nebulaShader = program.fragmentShader());
    } catch (_) {
      // Dégradation silencieuse : halo radial Canvas (voir _paintNebula).
    }
  }

  /// Centre de la pochette dans le repère du CustomPaint, lu au moment du
  /// paint (layout déjà terminé pour la frame) : `null` si la pochette n'est
  /// pas affichée (masquée, page Queue hors écran...) — `_paintNebula`
  /// retombe alors sur une position fixe.
  Offset? _coverCenterInCanvas() {
    final RenderObject? cover = widget.coverKey?.currentContext?.findRenderObject();
    final RenderObject? canvasBox = _paintKey.currentContext?.findRenderObject();
    if (cover is! RenderBox || canvasBox is! RenderBox) return null;
    if (!cover.attached || !canvasBox.attached || !cover.hasSize || !canvasBox.hasSize) return null;
    final Offset global = cover.localToGlobal(cover.size.center(Offset.zero));
    return canvasBox.globalToLocal(global);
  }

  Future<void> _loadShader() async {
    try {
      _shaderProgramFuture ??= ui.FragmentProgram.fromAsset('assets/shaders/vibe_particles.frag');
      final ui.FragmentProgram program = await _shaderProgramFuture!;
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // Dégradation silencieuse — voir doc de classe.
    }
  }

  /// Sampler de repli 1x1 transparent : `setImageSampler` exige une image non
  /// nulle même quand l'image de l'utilisateur n'est pas encore chargée (ou
  /// absente) — le shader se base alors sur `uBackdropReady` (mis à 0) pour
  /// ne jamais lire ce pixel factice.
  Future<void> _loadDummySamplerImage() async {
    try {
      _dummySamplerImageFuture ??= _decodeDummySamplerImage();
      final ui.Image image = await _dummySamplerImageFuture!;
      if (!mounted) return;
      setState(() => _dummySamplerImage = image);
    } catch (_) {
      // Si même ça échoue, le shader "Behind the window" reste simplement désactivé (voir
      // paint()) — les autres presets ne dépendent pas de ce sampler.
    }
  }

  static Future<ui.Image> _decodeDummySamplerImage() {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint()..color = Colors.transparent);
    return recorder.endRecording().toImage(1, 1);
  }

  Future<void> _maybeExtractPalette() async {
    final String? path = widget.coverArtPath;
    if (path == null || path.isEmpty) {
      setState(() {
        _paletteColors = null;
        _paletteSourcePath = null;
      });
      return;
    }
    if (path == _paletteSourcePath) return;

    List<Color>? colors;
    // URL http non rapatriée : pas de réseau, donc pas de palette (repli).
    final ImageProvider? image = localCoverImage(path);
    if (image != null) {
      try {
        // Décodée en 112x112 (Lot 1.1, même taille que l'API Palette
        // d'Android) : en pleine résolution, chaque changement de piste
        // décodait la pochette (1000 à 3000 px, 4 à 36 Mo) puis analysait
        // chaque pixel sur le thread UI — mémoire et saccades qui
        // s'accumulaient au fil des playlists. Les proportions de couleurs,
        // seules utiles ici, sont identiques.
        final PaletteGenerator palette = await PaletteGenerator.fromImageProvider(
          ResizeImage(image, width: 112, height: 112),
          maximumColorCount: 12,
        );
        final List<Color> extracted = [
          if (palette.dominantColor != null) palette.dominantColor!.color,
          if (palette.vibrantColor != null) palette.vibrantColor!.color,
          if (palette.mutedColor != null) palette.mutedColor!.color,
        ];
        colors = extracted.length >= 2 ? extracted : null;
      } catch (_) {
        colors = null;
      }
    }

    // Zap rapide : une extraction plus lente partie avant ne doit pas écraser
    // la palette de la pochette désormais affichée.
    if (!mounted || widget.coverArtPath != path) return;
    setState(() {
      _paletteColors = colors;
      _paletteSourcePath = path;
    });
  }

  @override
  void dispose() {
    _driftController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isNeon = widget.vibe.preset == VibePreset.neon;
    // Section 3 : la pochette en cours ne doit plus teinter le fond de la
    // plupart des presets (voir VibeCoverPaletteUsage.ignoresCoverPalette) —
    // Space (`oled`) reste la seule exception, sa nébuleuse étant justement
    // construite à partir de cette palette (voir _paintNebula ci-dessous).
    final bool ignoresCoverPalette = widget.vibe.preset?.ignoresCoverPalette ?? false;
    final List<Color> colors =
        ignoresCoverPalette ? widget.vibe.gradientColors : (_paletteColors ?? widget.vibe.gradientColors);
    final int? particleStyle = widget.vibe.preset?.particleStyleIndex;
    final bool isSpaceNebula = widget.vibe.preset == VibePreset.oled;
    final WindowBackdrop? windowBackdrop = _currentWindowBackdrop;

    return AnimatedBuilder(
      animation: Listenable.merge([widget.tempoController, _driftController]),
      builder: (context, _) {
        final TempoSyncController tempo = widget.tempoController;
        // Pic d'intensité à mi-battement, retombe aux bords — même logique
        // que l'ancien fond pulsé, réutilisée ici pour la taille des halos.
        final double beatPhase = 1 - (tempo.pulse - 0.5).abs() * 2;
        if (isNeon) {
          // Pas de plus de 0,5 s ignoré (onglet masqué, reprise du ticker) :
          // la phase reprend là où elle était au lieu de bondir.
          final double now = tempo.elapsedSeconds;
          final double dt = now - (_neonClock ?? now);
          if (dt > 0 && dt < 0.5) _neonPhase += dt * windowNeonSpeed(tempo.bpm);
          _neonClock = now;
        }

        // Couche shader seule (zones/buée/pluie pour "Behind the
        // window", ou rendu inchangé — dégradé + particules — pour tout le
        // reste) : `paintGradientBlobs` retire le fond opaque/halos habituels
        // uniquement quand un fond va être dessiné juste en-dessous.
        final Widget shaderOverlay = CustomPaint(
          key: _paintKey,
          painter: _FluidPainter(
            nebulaShader: isSpaceNebula ? _nebulaShader : null,
            turbulenceShader: _isCustomFluid ? _turbulenceShader : null,
            coverCenterResolver: _coverCenterInCanvas,
            colors: colors,
            drift: _driftController.value,
            beatPhase: beatPhase,
            shader: (particleStyle == null) ? null : _shader,
            shaderTime: tempo.elapsedSeconds,
            shaderTempo: tempo.bpm,
            shaderAccentColor: widget.vibe.accentColor,
            shaderStyle: particleStyle ?? 0,
            paintGradientBlobs: !isNeon,
            // Effet propre à VibePreset.custom (Section 4.2) — VibeCustomEffect.fluid
            // (comportement historique) pour tous les autres presets.
            effect: widget.vibe.effect,
            isSpaceNebula: isSpaceNebula,
            hasCoverPalette: _paletteColors != null,
            coverHidden: !widget.vibe.showCoverImage,
            backdropImage: windowBackdrop?.image,
            blurImage: windowBackdrop?.blurImage,
            zoneUniforms: windowBackdrop?.zoneUniforms ?? kNoWindowZoneUniforms,
            neonPhase: isNeon ? _neonPhase : 0,
            neonDrive: isNeon ? windowNeonDrive(tempo.bassLevel, tempo.pulse) : 0,
            dummySamplerImage: _dummySamplerImage,
          ),
          child: widget.child,
        );

        if (!isNeon) return shaderOverlay;

        // Vibe "Behind the window" : Couche 1 = l'image importée (la même
        // ui.Image que le sampler du shader : un seul décodage), sur l'aplat
        // nocturne qui reste seul sans image, pendant le décodage ou après un
        // échec ; Couche 2 = shaderOverlay ci-dessus (buée/pluie/zones).
        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF050D1A)),
            if (windowBackdrop != null) RawImage(image: windowBackdrop.image, fit: BoxFit.cover),
            shaderOverlay,
          ],
        );
      },
    );
  }
}

/// Palette de repli de la nébuleuse Space sans pochette (charte : indigo
/// `#2B0054` -> violet `#1A0033`, vers le noir).
const List<Color> _kNebulaFallbackColors = [Color(0xFF2B0054), Color(0xFF1A0033)];

/// Gain de luminosité appliqué à cette palette de repli (retour QA v1.0.0) :
/// telle quelle, elle restait trop discrète sur OLED. Les teintes de la charte
/// sont conservées, seule leur intensité monte. Aucun effet sur le noir pur
/// des bords : le shader force `#000000` au-delà de l'ellipse quelle que soit
/// la couleur (voir space_nebula.frag).
const double _kNebulaFallbackGain = 1.4;

Color _brighten(Color color, double gain) => Color.from(
      alpha: color.a,
      red: (color.r * gain).clamp(0.0, 1.0),
      green: (color.g * gain).clamp(0.0, 1.0),
      blue: (color.b * gain).clamp(0.0, 1.0),
    );

/// Les 2 extrêmes de la turbulence custom + fluid : les deux premières
/// couleurs de la Vibe. Une seule couleur, ou deux identiques (cas usuel :
/// `normalizeVibeColors` duplique la dernière couleur pour l'interpolation),
/// donnerait un aplat uni — la seconde devient alors une teinte nettement
/// plus sombre de la première, pour que la turbulence reste lisible.
@visibleForTesting
(Color, Color) fluidTurbulenceColors(List<Color> colors) {
  final Color first = colors.isEmpty ? Colors.black : colors.first;
  if (colors.length >= 2 && colors[1] != first) return (first, colors[1]);
  final HSLColor hsl = HSLColor.fromColor(first);
  return (first, hsl.withLightness(hsl.lightness * 0.35).toColor());
}

class _FluidPainter extends CustomPainter {
  _FluidPainter({
    required this.nebulaShader,
    required this.turbulenceShader,
    required this.coverCenterResolver,
    required this.colors,
    required this.drift,
    required this.beatPhase,
    required this.shader,
    required this.shaderTime,
    required this.shaderTempo,
    required this.shaderAccentColor,
    required this.shaderStyle,
    required this.paintGradientBlobs,
    required this.effect,
    required this.isSpaceNebula,
    required this.hasCoverPalette,
    required this.coverHidden,
    required this.backdropImage,
    required this.blurImage,
    required this.zoneUniforms,
    required this.neonPhase,
    required this.neonDrive,
    required this.dummySamplerImage,
  });

  final List<Color> colors;
  final double drift;
  final double beatPhase;
  final ui.FragmentShader? shader;
  final double shaderTime;
  final double shaderTempo;
  final Color shaderAccentColor;
  final int shaderStyle;
  // false pour "Behind the window" (Couche 1 déjà dessinée juste en-dessous) : ce
  // painter ne doit alors tracer QUE le shader (zones/buée/pluie), jamais le
  // fond opaque + halos habituels.
  final bool paintGradientBlobs;
  // Choix de rendu quand [paintGradientBlobs] est vrai — voir [VibeCustomEffect].
  final VibeCustomEffect effect;
  // Space (`VibePreset.oled`, Section 3) : remplace le rendu habituel de
  // [effect] par [_paintNebula] — la nébuleuse EST le fond de ce preset,
  // jamais superposée à un [_paintFluidBlobs] par ailleurs invisible (noir
  // sur noir).
  final bool isSpaceNebula;
  // Space uniquement — `true` quand `colors` vient réellement de la palette
  // extraite de la pochette (voir FluidBackground._paletteColors), plutôt
  // que du repli `vibe.gradientColors` (noir uni, aucune pochette). Permet à
  // [_paintNebula] de distinguer "vraie palette de pochette" de "rien à
  // afficher" pour appliquer son propre repli indigo/violet dans ce dernier
  // cas plutôt qu'un noir plat sans lueur.
  final bool hasCoverPalette;
  // Retro (styleIndex 1) uniquement — voir uCoverHidden dans
  // vibe_particles.frag : pochette masquée (Section 3) = soleil repoussé
  // plus haut/réduit pour ne jamais chevaucher le bloc Titre/Artiste
  // remonté dans la Column du Player (retest QA, "Polish & Final UI Fixes").
  final bool coverHidden;
  // "Behind the window" (styleIndex 0) uniquement : image importée (uBackdrop, pour la
  // réfraction des gouttes et les zones) et sa miniature floue
  // (uBackdropBlur, pour la buée) — voir vibe_particles.frag.
  // `dummySamplerImage` remplace l'une comme l'autre tant qu'elles ne sont pas
  // prêtes, et pour tous les autres presets.
  final ui.Image? backdropImage;
  final ui.Image? blurImage;
  // 48 valeurs (voir windowZoneUniforms), toutes nulles hors Neon avec image.
  final List<double> zoneUniforms;
  // "Behind the window" uniquement (0 sinon) : temps intégré et intensité du
  // scintillement des zones (uNeonPhase, uNeonDrive).
  final double neonPhase;
  final double neonDrive;
  final ui.Image? dummySamplerImage;
  // Space uniquement — voir [_paintNebula].
  final ui.FragmentShader? nebulaShader;
  // Non nul uniquement pour custom + fluid une fois le shader prêt — voir
  // [_paintTurbulence] ; sinon (presets figés, chargement en cours ou
  // échoué) [VibeCustomEffect.fluid] reste rendu par [_paintFluidBlobs].
  final ui.FragmentShader? turbulenceShader;
  // Appelé pendant paint() (layout de la frame terminé) : centre réel de la
  // pochette dans ce canvas, ou `null` si elle n'est pas affichée.
  final Offset? Function() coverCenterResolver;

  @override
  void paint(Canvas canvas, Size size) {
    // "Aucune couleur" (Vibe Creator) : rien à peindre, le fond par défaut de
    // l'app (Scaffold) ou l'image de fond personnalisée doit rester visible.
    final bool noColor = colors.isNotEmpty && colors.every((color) => color.a == 0);
    if (paintGradientBlobs && !noColor) {
      if (isSpaceNebula) {
        _paintNebula(canvas, size);
      } else {
        switch (effect) {
          case VibeCustomEffect.fluid:
            final ui.FragmentShader? turbulence = turbulenceShader;
            if (turbulence != null) {
              _paintTurbulence(canvas, size, turbulence);
            } else {
              _paintFluidBlobs(canvas, size);
            }
          case VibeCustomEffect.animatedGradient:
            _paintAnimatedGradient(canvas, size);
          case VibeCustomEffect.radiation:
            _paintRadiation(canvas, size);
        }
      }
    }

    // `setImageSampler` exige une image non nulle même quand les textures
    // Neon ne sont pas prêtes : le sampler factice transparent tient lieu de
    // repli pour les deux, et `uBackdropReady` (float 10) indique au shader
    // s'il peut s'y fier — sans lui, on saute purement et simplement ce paint
    // plutôt que de dessiner sans sampler valide.
    final ui.Image? sampler = backdropImage ?? dummySamplerImage;
    final ui.Image? blurSampler = blurImage ?? dummySamplerImage;
    final ui.FragmentShader? activeShader = shader;
    if (activeShader != null && sampler != null && blurSampler != null && size.width > 0 && size.height > 0) {
      final ui.Image backdrop = backdropImage ?? sampler;
      activeShader
        ..setFloat(0, shaderTime)
        ..setFloat(1, size.width)
        ..setFloat(2, size.height)
        ..setFloat(3, shaderTempo)
        ..setFloat(4, shaderAccentColor.r)
        ..setFloat(5, shaderAccentColor.g)
        ..setFloat(6, shaderAccentColor.b)
        ..setFloat(7, shaderStyle.toDouble())
        ..setFloat(8, backdrop.width.toDouble())
        ..setFloat(9, backdrop.height.toDouble())
        ..setFloat(10, backdropImage != null ? 1.0 : 0.0)
        ..setFloat(11, coverHidden ? 1.0 : 0.0)
        ..setFloat(12, neonPhase)
        ..setFloat(13, neonDrive);
      // uZoneShape[6] puis uZoneColor[6] : 48 floats consécutifs (14..61).
      for (int i = 0; i < zoneUniforms.length; i++) {
        activeShader.setFloat(14 + i, zoneUniforms[i]);
      }
      // Bilinéaire pour l'image (agrandie quand la borne de 2048 px est plus
      // petite que l'écran) et surtout pour la miniature, dont les texels
      // deviendraient sinon des pavés de ~20 px. Le sampler factice garde le
      // filtrage par défaut : il n'est jamais lu.
      activeShader
        ..setImageSampler(0, sampler, filterQuality: backdropImage != null ? FilterQuality.low : FilterQuality.none)
        ..setImageSampler(1, blurSampler, filterQuality: blurImage != null ? FilterQuality.low : FilterQuality.none);
      canvas.drawRect(Offset.zero & size, Paint()..shader = activeShader);
    }
  }

  // Custom + fluid : turbulence bicolore opaque plein écran, à la place des
  // halos. Temps monotone (`shaderTime`) et non `drift`, qui reboucle à 1
  // toutes les 18 s et ferait sauter l'écoulement.
  void _paintTurbulence(Canvas canvas, Size size, ui.FragmentShader shader) {
    if (size.isEmpty) return;
    final (Color a, Color b) = fluidTurbulenceColors(colors);
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, shaderTime)
      ..setFloat(3, a.r)
      ..setFloat(4, a.g)
      ..setFloat(5, a.b)
      ..setFloat(6, b.r)
      ..setFloat(7, b.g)
      ..setFloat(8, b.b);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  // Rendu historique (Vibe Engine v2+, inchangé) des presets figés, et repli
  // de custom + fluid sans shader : aplat de la première couleur puis halos
  // flous qui dérivent en orbite, pulsant au beat.
  void _paintFluidBlobs(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.first);

    for (int i = 0; i < colors.length; i++) {
      final double angle = drift * 2 * math.pi + i * (2 * math.pi / colors.length);
      final double radiusScale = 0.5 + beatPhase * 0.15 + (i.isEven ? 0.05 : -0.05);
      final Offset center = Offset(
        size.width * (0.5 + 0.35 * math.cos(angle)),
        size.height * (0.4 + 0.3 * math.sin(angle * 1.3)),
      );

      canvas.drawCircle(
        center,
        size.longestSide * radiusScale,
        Paint()
          ..color = colors[i].withValues(alpha: 0.55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 80),
      );
    }
  }

  // Section 4.2 "Dégradé animé" : dégradé linéaire plein écran dont l'angle
  // tourne en continu (pas de halos flous, contrairement à [_paintFluidBlobs]).
  void _paintAnimatedGradient(Canvas canvas, Size size) {
    final List<Color> gradientColors = colors.length >= 2 ? colors : [...colors, ...colors];
    final double angle = drift * 2 * math.pi;
    final Offset center = size.center(Offset.zero);
    final double radius = size.longestSide * 0.75;
    final Offset from = center + Offset(math.cos(angle), math.sin(angle)) * radius;
    final Offset to = center - Offset(math.cos(angle), math.sin(angle)) * radius;

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(from, to, gradientColors)
        // Légère respiration d'opacité au beat plutôt qu'un dégradé figé.
        ..color = Colors.white.withValues(alpha: (0.85 + beatPhase * 0.15).clamp(0.0, 1.0)),
    );
  }

  // Space (Section 3) : nébuleuse sur fond TOUJOURS noir pur — seule la
  // lueur porte la couleur (palette de la pochette, ou repli indigo/violet
  // #2B0054/#1A0033 sans pochette).
  //
  // Retest QA (61b5cf1) :
  //  1. Centrage sur la POCHETTE réelle ([coverCenterResolver]), plus sur
  //     `size.center` — la pochette est plus haute que le centre du canvas.
  //  2. Forme/mouvement : bruit fractal FBM à domaine déformé (filaments
  //     nuageux) en rotation très lente (0.03 rad/s), rendu par
  //     assets/shaders/space_nebula.frag ; halo radial Canvas en repli.
  //  3. Luminescence : respiration sinusoïdale lente (une par mesure de 4
  //     temps) de ±8% max — remplace l'ancien `beatPhase` en dents de scie
  //     (±15% du rayon, remis à zéro à chaque battement = scintillement).
  //  4. OLED strict : ellipse dont chaque demi-axe est borné à 85% de la
  //     distance pochette -> bord sur son axe ; noir pur garanti au-delà (et
  //     l'estompe est déjà < 8% à 90% de l'ellipse).
  void _paintNebula(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    if (size.isEmpty) return;

    // Repli (pochette masquée ou hors écran) : là où la pochette se trouve
    // habituellement, dans le tiers haut-central du Player.
    final Offset center = coverCenterResolver() ?? Offset(size.width / 2, size.height * 0.42);
    // Ellipse : chaque demi-axe borné à 85% de la distance au bord le plus
    // proche SUR SON AXE. Un rayon circulaire unique (borné par la seule
    // largeur, la plus contraignante) dépassait à peine la demi-largeur de
    // la pochette (140dp) : la nébuleuse restait cachée derrière elle.
    final double radiusX = math.min(center.dx, size.width - center.dx) * 0.85;
    final double radiusY = math.min(center.dy, size.height - center.dy) * 0.85;
    if (radiusX <= 1 || radiusY <= 1) return;

    final double barsPerSecond = math.max(shaderTempo, 1) / 60 / 4;
    final double breath = 1 + 0.08 * math.sin(2 * math.pi * shaderTime * barsPerSecond);

    final List<Color> glowColors = (hasCoverPalette && colors.length >= 2)
        ? colors
        : [for (final Color color in _kNebulaFallbackColors) _brighten(color, _kNebulaFallbackGain)];

    final ui.FragmentShader? shader = nebulaShader;
    if (shader != null) {
      shader
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, center.dx)
        ..setFloat(3, center.dy)
        ..setFloat(4, shaderTime)
        ..setFloat(5, radiusX)
        ..setFloat(6, radiusY)
        ..setFloat(7, breath)
        ..setFloat(8, glowColors[0].r)
        ..setFloat(9, glowColors[0].g)
        ..setFloat(10, glowColors[0].b)
        ..setFloat(11, glowColors[1].r)
        ..setFloat(12, glowColors[1].g)
        ..setFloat(13, glowColors[1].b);
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
      return;
    }

    // Repli sans shader : halo radial au même centre, même respiration,
    // fondu jusqu'à transparence (donc noir) avant le plus petit demi-axe.
    final double radius = math.min(radiusX, radiusY);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          radius,
          [
            glowColors.first.withValues(alpha: (0.5 * breath).clamp(0.0, 1.0)),
            glowColors[1].withValues(alpha: (0.22 * breath).clamp(0.0, 1.0)),
            Colors.transparent,
            Colors.transparent,
          ],
          const [0.0, 0.45, 0.85, 1.0],
        ),
    );
  }

  // Section 4.2 "Radiation" : rayons flous qui partent du centre vers les
  // bords, tournant lentement et s'allongeant/rétrécissant au rythme du beat.
  void _paintRadiation(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.last);

    const int rayCount = 12;
    final double maxRadius = size.longestSide * 0.9;
    final double pulseRadius = maxRadius * (0.55 + beatPhase * 0.45);
    const double rayHalfWidth = math.pi / rayCount * 0.5;

    for (int i = 0; i < rayCount; i++) {
      final double baseAngle = (i / rayCount) * 2 * math.pi + drift * 2 * math.pi;
      final Color rayColor = colors[i % colors.length];
      final Path ray = Path()
        ..moveTo(center.dx, center.dy)
        ..lineTo(
          center.dx + pulseRadius * math.cos(baseAngle - rayHalfWidth),
          center.dy + pulseRadius * math.sin(baseAngle - rayHalfWidth),
        )
        ..lineTo(
          center.dx + pulseRadius * math.cos(baseAngle + rayHalfWidth),
          center.dy + pulseRadius * math.sin(baseAngle + rayHalfWidth),
        )
        ..close();

      canvas.drawPath(
        ray,
        Paint()
          ..color = rayColor.withValues(alpha: 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FluidPainter oldDelegate) {
    // Space : la pochette peut bouger (swipe, flottement Focus) sans que rien
    // d'autre ne change — toujours repeindre la nébuleuse.
    if (isSpaceNebula) return true;
    return oldDelegate.drift != drift ||
        oldDelegate.beatPhase != beatPhase ||
        oldDelegate.colors != colors ||
        oldDelegate.shader != shader ||
        oldDelegate.turbulenceShader != turbulenceShader ||
        oldDelegate.shaderTime != shaderTime ||
        oldDelegate.shaderStyle != shaderStyle ||
        oldDelegate.shaderAccentColor != shaderAccentColor ||
        oldDelegate.paintGradientBlobs != paintGradientBlobs ||
        oldDelegate.effect != effect ||
        oldDelegate.isSpaceNebula != isSpaceNebula ||
        oldDelegate.hasCoverPalette != hasCoverPalette ||
        oldDelegate.coverHidden != coverHidden ||
        oldDelegate.backdropImage != backdropImage ||
        oldDelegate.blurImage != blurImage ||
        oldDelegate.zoneUniforms != zoneUniforms ||
        oldDelegate.neonPhase != neonPhase ||
        oldDelegate.neonDrive != neonDrive ||
        oldDelegate.dummySamplerImage != dummySamplerImage;
  }
}
