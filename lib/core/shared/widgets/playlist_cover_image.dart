import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/playlists/data/playlist_providers.dart';
import '../../../features/playlists/domain/playlist_editor_entry.dart';
import '../../storage/database/app_database.dart';
import '../../theme/design_system/vibe_design_system.dart';
import '../../theme/vibe_engine/playlist_vibe_resolver.dart';
import '../../theme/vibe_engine/vibe_engine.dart';
import 'local_cover_image.dart';

/// Visuel de couverture d'une playlist (Design System — PlaylistCard) :
/// pochette personnalisée si définie (`playlist.coverImagePath`), sinon un
/// composite 2x2 de 4 pochettes locales distinctes (1 à 3 : la première en pleine carte), sinon un repli
/// générique stylisé selon la Vibe de la playlist (aucun morceau avec
/// pochette, ou playlist vide). Toujours carrée — enrober dans un
/// `AspectRatio(aspectRatio: 1)` si le parent n'impose pas déjà ce ratio.
///
/// Images décodées à taille de vignette (Lot 1.1) : en pleine résolution,
/// chaque carte de Mon espace gardait jusqu'à 4 pochettes HD décodées en
/// mémoire (~4 à 36 Mo chacune) — la mémoire grimpait avec le nombre de
/// playlists.
class PlaylistCoverImage extends StatelessWidget {
  const PlaylistCoverImage({
    super.key,
    required this.playlist,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.card)),
  });

  final Playlist playlist;
  final BorderRadius borderRadius;

  /// Largeur de décodage (px) : PlaylistCard fait 152 dp de large, soit
  /// 456 px en densité 3x ; une case du composite 2x2, la moitié.
  static const int _coverDecodeWidth = 512;
  static const int _tileDecodeWidth = _coverDecodeWidth ~/ 2;

  @override
  Widget build(BuildContext context) {
    if (playlist.coverImagePath.isNotEmpty) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: Image.file(
          File(playlist.coverImagePath),
          cacheWidth: _coverDecodeWidth,
          semanticLabel: 'Pochette de la playlist ${playlist.title}',
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _CompositeFallback(playlist: playlist, borderRadius: borderRadius),
        ),
      );
    }
    return _CompositeFallback(playlist: playlist, borderRadius: borderRadius);
  }
}

class _CompositeFallback extends ConsumerWidget {
  const _CompositeFallback({required this.playlist, required this.borderRadius});

  final Playlist playlist;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<PlaylistEditorEntry>> entries = ref.watch(playlistEditorEntriesProvider(playlist.id));
    // On filtre AVANT de limiter : des titres sans pochette en tête ne doivent
    // pas empêcher la mosaïque. Doublons écartés (même album répété), et seules
    // les pochettes locales comptent (une URL http n'est jamais chargée).
    final List<String> covers = (entries.value ?? const [])
        .map((entry) => entry.track?.coverArtPath ?? '')
        .where((path) => path.isNotEmpty && !isRemoteCoverPath(path))
        .toSet()
        .take(4)
        .toList();

    final Widget child;
    if (covers.isEmpty) {
      child = _VibePlaceholder(vibe: playlist.resolvedVibe);
    } else if (covers.length < 4) {
      // 1 à 3 pochettes : la première en pleine carte plutôt qu'un quart d'image.
      child = _CoverTile(path: covers.first, decodeWidth: PlaylistCoverImage._coverDecodeWidth);
    } else {
      child = _CompositeGrid(coverPaths: covers);
    }
    return ClipRRect(borderRadius: borderRadius, child: child);
  }
}

/// Composite 2x2 (exactement 4 pochettes locales distinctes).
class _CompositeGrid extends StatelessWidget {
  const _CompositeGrid({required this.coverPaths});

  final List<String> coverPaths;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final String path in coverPaths) _CoverTile(path: path, decodeWidth: PlaylistCoverImage._tileDecodeWidth)
      ],
    );
  }
}

/// Une pochette locale décodée à taille de vignette ; tuile neutre si le
/// fichier est illisible.
class _CoverTile extends StatelessWidget {
  const _CoverTile({required this.path, required this.decodeWidth});

  final String path;
  final int decodeWidth;

  @override
  Widget build(BuildContext context) {
    final Widget neutral = ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest);
    final ImageProvider? image = localCoverImage(path);
    if (image == null) return neutral;
    return Image(
      image: ResizeImage.resizeIfNeeded(decodeWidth, null, image),
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => neutral,
    );
  }
}

class _VibePlaceholder extends StatelessWidget {
  const _VibePlaceholder({required this.vibe});

  final VibeVisual vibe;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: vibe.gradientColors, begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Center(child: Icon(Icons.queue_music, color: vibe.accentColor, size: 40)),
    );
  }
}
