import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/networking/metadata_api_client/online_track_result.dart';
import '../../../core/shared/widgets/add_to_playlist_sheet.dart';
import '../../../core/shared/widgets/online_track_card.dart';
import '../../../core/shared/widgets/skeleton_loader.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/theme/vibe_engine/active_vibe_provider.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../data/artist_providers.dart';
import '../domain/album_group.dart';
import '../domain/artist_filter.dart';
import '../domain/artist_metadata.dart';
import '../domain/artist_sort.dart';
import 'album_tracks_sheet.dart';
import 'online_track_actions.dart';

/// Tab 1 : profil d'un artiste — agrège tous les morceaux où il est crédité
/// (y compris en featuring), avec filtres/tri et shimmer de chargement.
class ArtistProfileScreen extends ConsumerStatefulWidget {
  const ArtistProfileScreen({super.key, required this.artistName});

  final String artistName;

  @override
  ConsumerState<ArtistProfileScreen> createState() => _ArtistProfileScreenState();
}

class _ArtistProfileScreenState extends ConsumerState<ArtistProfileScreen> {
  ArtistFilter _filter = ArtistFilter.all;
  ArtistSort _sort = ArtistSort.chronological;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<ArtistMetadata?> metadata = ref.watch(artistMetadataProvider(widget.artistName));
    final AsyncValue<List<Track>> tracks = ref.watch(
      artistTracksProvider((artistName: widget.artistName, filter: _filter, sort: _sort)),
    );
    // Section 5.3 : les extraits en ligne ne doivent suggérer que des titres
    // absents de la bibliothèque locale — comparaison sur tous les morceaux
    // locaux de l'artiste (`ArtistFilter.all`), indépendamment du filtre/tri
    // actuellement sélectionné dans les chips ci-dessous.
    final AsyncValue<List<Track>> allLocalTracks = ref.watch(
      artistTracksProvider((artistName: widget.artistName, filter: ArtistFilter.all, sort: ArtistSort.chronological)),
    );
    final Set<String> localTrackTitles = {
      for (final track in allLocalTracks.value ?? const <Track>[]) track.title.trim().toLowerCase(),
    };

    return Scaffold(
      appBar: AppBar(title: Text(widget.artistName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ArtistHeader(metadata: metadata),
          const SizedBox(height: 20),
          _TopTracksSection(artistName: widget.artistName, localTrackTitles: localTrackTitles),
          const SizedBox(height: 20),
          _DiscographySection(artistName: widget.artistName),
          const SizedBox(height: 20),
          Text('Dans ta bibliothèque', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          _FilterChips(selected: _filter, onChanged: (f) => setState(() => _filter = f)),
          const SizedBox(height: 12),
          _SortDropdown(selected: _sort, onChanged: (s) => setState(() => _sort = s)),
          const SizedBox(height: 16),
          tracks.when(
            data: (data) =>
                _filter == ArtistFilter.albums ? _AlbumSections(tracks: data) : _FlatTrackList(tracks: data),
            loading: () => Column(children: List.generate(6, (_) => const SkeletonLoader())),
            error: (error, _) => Text('Erreur de chargement : $error'),
          ),
        ],
      ),
    );
  }
}

class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({required this.metadata});

  final AsyncValue<ArtistMetadata?> metadata;

  @override
  Widget build(BuildContext context) {
    return metadata.when(
      data: (data) {
        if (data == null) return const SizedBox.shrink();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (data.artworkUrl != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  data.artworkUrl!,
                  semanticLabel: 'Illustration de ${data.name}',
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const SizedBox(width: 64, height: 64),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (data.genre != null) Chip(label: Text(data.genre!)),
                  if (data.label != null)
                    Text(
                      data.label!,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        );
      },
      loading: () => const SkeletonLoader(height: 64),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

/// "Morceaux populaires" — top titres iTunes de l'artiste (découverte, pas la
/// bibliothèque locale). Cartes réutilisant [OnlineTrackCard] telles quelles :
/// extrait 30s, badge explicite, bouton "+" (voir online_track_actions.dart).
/// Section 5.3 : ne montre que les titres absents de [localTrackTitles],
/// jamais un doublon d'un morceau déjà téléchargé.
class _TopTracksSection extends ConsumerWidget {
  const _TopTracksSection({required this.artistName, required this.localTrackTitles});

  final String artistName;
  final Set<String> localTrackTitles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<OnlineTrackResult>> topTracks = ref.watch(artistTopTracksProvider(artistName));
    final VibeVisual vibe = ref.watch(activeVibeProvider);

    return topTracks.when(
      data: (allData) {
        final List<OnlineTrackResult> data =
            allData.where((track) => !localTrackTitles.contains(track.title.trim().toLowerCase())).toList();
        if (data.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Morceaux populaires',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: vibe.accentColor)),
            const SizedBox(height: 8),
            ...data.map(
              (track) => OnlineTrackCard(track: track, onAdd: () => addOnlineTrackToPlaylist(context, ref, track)),
            ),
          ],
        );
      },
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(color: vibe.accentColor),
      ),
      // Discret : cette section est un bonus de découverte, pas une donnée
      // essentielle — inutile d'alarmer l'utilisateur si iTunes est indisponible.
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

/// "Discographie & Albums" — carrousel horizontal des albums officiels de
/// l'artiste (iTunes), au tap ouvre [AlbumTracksSheet].
class _DiscographySection extends ConsumerWidget {
  const _DiscographySection({required this.artistName});

  final String artistName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<AlbumGroup>> albums = ref.watch(artistDiscographyProvider(artistName));
    final VibeVisual vibe = ref.watch(activeVibeProvider);

    return albums.when(
      data: (data) {
        if (data.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Discographie', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: vibe.accentColor)),
            const SizedBox(height: 8),
            SizedBox(
              height: 190,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: data.length,
                separatorBuilder: (context, index) => const SizedBox(width: 12),
                itemBuilder: (context, index) => _AlbumTile(album: data[index]),
              ),
            ),
          ],
        );
      },
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(color: vibe.accentColor),
      ),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _AlbumTile extends StatelessWidget {
  const _AlbumTile({required this.album});

  final AlbumGroup album;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => AlbumTracksSheet.show(context, album),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 1,
                child: album.artworkUrl != null
                    ? Image.network(
                        album.artworkUrl!,
                        semanticLabel: 'Pochette de ${album.album}',
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.album_outlined),
                        ),
                      )
                    : Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.album_outlined),
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(album.album,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
            Text(
              [if (album.releaseYear > 0) '${album.releaseYear}', if (album.label != null) album.label!].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({required this.selected, required this.onChanged});

  final ArtistFilter selected;
  final ValueChanged<ArtistFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: ArtistFilter.values
          .map((filter) => ChoiceChip(
                label: Text(filter.label),
                selected: filter == selected,
                onSelected: (_) => onChanged(filter),
              ))
          .toList(),
    );
  }
}

class _SortDropdown extends StatelessWidget {
  const _SortDropdown({required this.selected, required this.onChanged});

  final ArtistSort selected;
  final ValueChanged<ArtistSort> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('Trier par : '),
        DropdownButton<ArtistSort>(
          value: selected,
          items: ArtistSort.values.map((sort) => DropdownMenuItem(value: sort, child: Text(sort.label))).toList(),
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
      ],
    );
  }
}

class _FlatTrackList extends StatelessWidget {
  const _FlatTrackList({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const Text('Aucun morceau.');
    return Column(children: tracks.map((track) => _TrackTile(track: track)).toList());
  }
}

class _AlbumSections extends StatelessWidget {
  const _AlbumSections({required this.tracks});

  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final List<AlbumGroup> groups = groupTracksByAlbum(tracks);
    if (groups.isEmpty) return const Text('Aucun album.');

    return Column(
      children: groups.map((group) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${group.album} (${group.releaseYear})', style: Theme.of(context).textTheme.titleMedium),
              ...group.tracks.map((track) => _TrackTile(track: track)),
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// Morceau de la bibliothèque locale de l'artiste — contrairement aux cartes
/// de découverte ([OnlineTrackCard], "Morceaux populaires"/discographie), ce
/// morceau est déjà possédé : le bouton "+" ajoute donc directement, sans
/// passer par la résolution de correspondance locale d'`addOnlineTrackToPlaylist`.
class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final bool isCollaboration = track.artists.length > 1;
    return ListTile(
      leading: track.trackNumber > 0
          ? SizedBox(
              width: 24,
              child: Text(
                '${track.trackNumber}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          : null,
      title: Text(track.title),
      subtitle: isCollaboration ? Text(track.artists.join(', ')) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCollaboration)
            const Padding(padding: EdgeInsets.only(right: 4), child: Icon(Icons.people_outline, size: 18)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Ajouter à une playlist',
            onPressed: () => AddToPlaylistSheet.show(context, track.id),
          ),
        ],
      ),
    );
  }
}
