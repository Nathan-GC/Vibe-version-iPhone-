import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Vidéo de fond personnalisée du Vibe Creator (Section 4.3) — remplace
/// entièrement FluidBackground pour `VibePreset.custom` quand une vidéo est
/// définie : jouée en boucle, muette (fond visuel seulement, jamais un second
/// flux audio superposé à la lecture en cours), sans contrôles.
class VibeVideoBackground extends StatefulWidget {
  const VibeVideoBackground({super.key, required this.videoPath, required this.child});

  final String videoPath;
  final Widget child;

  @override
  State<VibeVideoBackground> createState() => _VibeVideoBackgroundState();
}

class _VibeVideoBackgroundState extends State<VibeVideoBackground> {
  VideoPlayerController? _controller;

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
    await _controller?.dispose();

    final VideoPlayerController controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
    } catch (_) {
      // Fichier absent/illisible (supprimé manuellement du stockage, format
      // non supporté par la plateforme...) — dégradation silencieuse : le
      // fond reste noir plutôt qu'un crash, comme FluidBackground le fait déjà
      // pour ses propres assets optionnels.
    }
    if (!mounted) return;
    setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
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
