import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Vidéo de fond personnalisée du Vibe Creator (Section 4.3) — remplace
/// entièrement FluidBackground pour `VibePreset.custom` quand une vidéo est
/// définie : jouée en boucle, muette (fond visuel seulement, jamais un second
/// flux audio superposé à la lecture en cours), sans contrôles.
class VibeVideoBackground extends StatefulWidget {
  const VibeVideoBackground({
    super.key,
    required this.videoPath,
    required this.child,
    this.backgroundColor = Colors.black,
  });

  final String videoPath;
  final Widget child;

  /// Couleur posée sous la vidéo (visible avant la première image seulement).
  /// `Colors.transparent` pour la Vibe "Aucune couleur" : le fond par défaut
  /// de l'app transparaît au lieu d'un aplat noir.
  final Color backgroundColor;

  @override
  State<VibeVideoBackground> createState() => _VibeVideoBackgroundState();
}

/// La vidéo est censée tourner en boucle sans fin : si la plateforme signale
/// pourtant la fin de lecture (`isCompleted`, lecteur arrêté à la dernière
/// image), il faut la relancer depuis le début plutôt que de laisser l'image
/// figée (coupure / écran noir à la fin de la vidéo).
@visibleForTesting
bool videoNeedsLoopRestart(VideoPlayerValue value) => value.isInitialized && value.isCompleted && !value.isPlaying;

class _VibeVideoBackgroundState extends State<VibeVideoBackground> {
  VideoPlayerController? _controller;

  /// Chargement le plus récent : un chargement dépassé (changement de
  /// playlist pendant l'initialisation) ou terminé après la sortie de
  /// l'écran libère sa vidéo au lieu de l'abandonner (Lot 1.1 : chaque
  /// contrôleur oublié gardait un décodeur vidéo natif tournant en boucle,
  /// jusqu'au crash après quelques playlists à fond vidéo).
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _load(widget.videoPath);
  }

  @override
  void didUpdateWidget(covariant VibeVideoBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) _load(widget.videoPath);
  }

  Future<void> _load(String path) async {
    final int token = ++_loadToken;
    final VideoPlayerController? previous = _controller;
    _controller = null;
    await previous?.dispose();

    // `mixWithOthers` : sans lui, ExoPlayer réclame le focus audio Android
    // (même muet) et le lecteur de musique (just_audio) le lui reprend à
    // chaque changement de piste ou reprise — la vidéo se mettait alors en
    // pause (image figée / noir) et inversement. Le fond ne doit jamais
    // interagir avec le focus audio de la musique.
    final VideoPlayerController controller = VideoPlayerController.file(
      File(path),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await controller.initialize();
      controller.addListener(() => _restartIfCompleted(controller));
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
    } catch (_) {
      // Fichier absent/illisible (supprimé manuellement du stockage, format
      // non supporté par la plateforme...) — dégradation silencieuse : le
      // fond reste noir plutôt qu'un crash, comme FluidBackground le fait déjà
      // pour ses propres assets optionnels.
    }
    if (!mounted || token != _loadToken) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
  }

  /// Relance en cours : l'écouteur est rappelé à chaque mise à jour de
  /// position, une seule relance doit partir à la fois.
  bool _restarting = false;

  void _restartIfCompleted(VideoPlayerController controller) {
    if (_restarting || !videoNeedsLoopRestart(controller.value)) return;
    _restarting = true;
    controller
        .seekTo(Duration.zero)
        .then((_) => controller.play())
        .catchError((Object _) {}) // contrôleur libéré entre-temps
        .whenComplete(() => _restarting = false);
  }

  @override
  void dispose() {
    _loadToken++;
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: widget.backgroundColor),
        if (controller != null && controller.value.isInitialized)
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.size.width,
              height: controller.value.size.height,
              child: VideoPlayer(controller),
            ),
          ),
        widget.child,
      ],
    );
  }
}
