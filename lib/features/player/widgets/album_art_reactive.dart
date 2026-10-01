import 'dart:io';

import 'package:flutter/material.dart';

/// Cover art : s'agrandit avec drop-shadow au Play, rétrécit de 5% au Pause.
/// `imagePath` est double-usage (voir Tracks.coverArtPath) : chemin fichier
/// local extrait des tags ID3, ou URL HD renvoyée par l'enrichissement iTunes.
///
/// Stabilité d'affichage (bug QA "pochette qui clignote") :
///  - l'[ImageProvider] est mis en cache dans le `State` et n'est recréé que
///    si le chemin change réellement — jamais sur un simple rebuild lié au
///    PlayerState (play/pause, position, boutons) ;
///  - `gaplessPlayback` garde l'image précédente affichée pendant le
///    décodage d'une nouvelle, au lieu d'un cadre vide intermédiaire ;
///  - l'image elle-même vit dans un `RepaintBoundary` : l'animation d'échelle
///    ou d'ombre au play/pause ne la repeint pas.
class AlbumArtReactive extends StatefulWidget {
  const AlbumArtReactive({super.key, required this.imagePath, this.isPlaying = false, this.semanticLabel});

  final String? imagePath;

  /// Lu par les lecteurs d'écran (TalkBack), ex. « Pochette de Halo ».
  final String? semanticLabel;
  final bool isPlaying;

  @override
  State<AlbumArtReactive> createState() => _AlbumArtReactiveState();
}

class _AlbumArtReactiveState extends State<AlbumArtReactive> {
  String? _cachedPath;
  ImageProvider? _cachedImage;

  ImageProvider? _imageFor(String? path) {
    if (path == _cachedPath) return _cachedImage;
    _cachedPath = path;
    _cachedImage = (path == null || path.isEmpty)
        ? null
        : (path.startsWith('http') ? NetworkImage(path) : FileImage(File(path))) as ImageProvider;
    return _cachedImage;
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider? image = _imageFor(widget.imagePath);
    final bool isPlaying = widget.isPlaying;
    final ColorScheme colors = Theme.of(context).colorScheme;
    // Pas de pochette, ou échec de chargement (hors-ligne, fichier absent) :
    // nommé pour TalkBack plutôt qu'un élément muet.
    final Widget placeholder = Icon(
      Icons.music_note,
      size: 96,
      color: colors.onSurfaceVariant,
      semanticLabel: 'Pochette indisponible',
    );

    return AnimatedScale(
      scale: isPlaying ? 1.0 : 0.95,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      child: DecoratedBox(
        decoration: BoxDecoration(
          boxShadow: isPlaying
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 24, offset: const Offset(0, 12))]
              : [],
          borderRadius: BorderRadius.circular(16),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Hero(
            tag: 'album-art',
            child: RepaintBoundary(
              child: Container(
                width: 280,
                height: 280,
                color: colors.surfaceContainerHighest,
                child: image == null
                    ? placeholder
                    : Image(
                        image: image,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        semanticLabel: widget.semanticLabel,
                        errorBuilder: (context, error, stackTrace) => placeholder,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
