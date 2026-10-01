import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/playlists/data/playlist_providers.dart';
import '../../../features/playlists/domain/playlist_editor_entry.dart';
import '../../storage/database/app_database.dart';
import '../../theme/design_system/vibe_design_system.dart';
import '../../theme/vibe_engine/playlist_vibe_resolver.dart';
import '../../theme/vibe_engine/vibe_engine.dart';

/// Visuel de couverture d'une playlist (Design System — PlaylistCard) :
/// pochette personnalisée si définie (`playlist.coverImagePath`), sinon un
/// composite 2x2 des pochettes des 4 premiers morceaux, sinon un repli
/// générique stylisé selon la Vibe de la playlist (aucun morceau avec
/// pochette, ou playlist vide). Toujours carrée — enrober dans un
/// `AspectRatio(aspectRatio: 1)` si le parent n'impose pas déjà ce ratio.
class PlaylistCoverImage extends StatelessWidget {
  const PlaylistCoverImage({
    super.key,
    required this.playlist,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppRadii.card)),
  });

  final Playlist playlist;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    if (playlist.coverImagePath.isNotEmpty) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: Image.file(
          File(playlist.coverImagePath),
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
    final List<String> covers = (entries.value ?? const [])
        .where((entry) => entry.track != null)
        .take(4)
        .map((entry) => entry.track!.coverArtPath)
        .where((path) => path.isNotEmpty)
        .toList();

    return ClipRRect(
      borderRadius: borderRadius,
      child: covers.isEmpty ? _VibePlaceholder(vibe: playlist.resolvedVibe) : _CompositeGrid(coverPaths: covers),
    );
  }
}

/// Composite 2x2 : cases sans pochette disponible comblées par une tuile
/// neutre plutôt que de casser la grille ou d'afficher un vide.
class _CompositeGrid extends StatelessWidget {
  const _CompositeGrid({required this.coverPaths});

  final List<String> coverPaths;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      physics: const NeverScrollableScrollPhysics(),
      children: List.generate(4, (index) {
        if (index >= coverPaths.length) {
          return ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest);
        }
        final String path = coverPaths[index];
        final ImageProvider image =
            path.startsWith('http') ? NetworkImage(path) : FileImage(File(path)) as ImageProvider;
        return Image(
          image: image,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest),
        );
      }),
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
