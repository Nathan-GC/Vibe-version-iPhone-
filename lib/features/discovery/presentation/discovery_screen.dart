import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/audio_engine/player_controller.dart';
import '../../../core/shared/widgets/add_to_playlist_sheet.dart';
import '../../../core/shared/widgets/online_track_card.dart';
import '../../../core/shared/widgets/playlist_card.dart';
import '../../../core/shared/widgets/skeleton_loader.dart';
import '../../../core/shared/widgets/track_actions_sheet.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/theme/design_system/app_spacing.dart';
import '../../../core/theme/design_system/vibe_design_system.dart';
import '../../../core/theme/vibe_engine/active_vibe_provider.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../../playlists/data/playlist_providers.dart';
import '../data/artist_providers.dart';
import '../data/autocomplete_providers.dart';
import '../data/search_providers.dart';
import '../domain/artist_filter.dart';
import '../domain/artist_sort.dart';
import '../domain/autocomplete_suggestion.dart';
import '../domain/search_result.dart';
import '../domain/top_artist_playlist.dart';

/// Délai de debounce avant d'interroger l'autocomplétion — évite une requête
/// iTunes à chaque frappe.
const Duration _autocompleteDebounce = Duration(milliseconds: 300);

/// Tab 1 : recherche unifiée (locale d'abord, repli API publique si aucun
/// résultat local), autocomplétion dynamique pendant la frappe, ingestion de
/// liens Spotify, imports JSON, et — quand la recherche est vide — le tableau
/// de bord de suggestions : tes playlists, puis les 7 artistes les plus
/// présents dans ta bibliothèque locale (Section 5.2, sans aucune incidence
/// sur la Vibe, choix exclusivement manuel).
class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounceTimer;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    ref.read(liveQueryProvider.notifier).set(value);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_autocompleteDebounce, () {
      ref.read(debouncedAutocompleteQueryProvider.notifier).set(value);
    });
  }

  /// Valide la recherche et referme l'autocomplétion — [text] permet à une
  /// suggestion tapée de remplir le champ puis soumettre en un seul geste.
  void _submit([String? text]) {
    final String value = text ?? _controller.text;
    if (text != null) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    }
    _debounceTimer?.cancel();
    ref.read(liveQueryProvider.notifier).set('');
    ref.read(debouncedAutocompleteQueryProvider.notifier).set('');
    ref.read(searchQueryProvider.notifier).set(value);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<SearchResult>> results = ref.watch(searchResultsProvider);
    final String activeQuery = ref.watch(searchQueryProvider);
    final String liveQuery = ref.watch(liveQueryProvider);
    final bool showAutocomplete = activeQuery.isEmpty && liveQuery.trim().length >= 2;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Paramètres',
          onPressed: () => context.push('/settings'),
        ),
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: 'Titre, artiste, playlist...',
            border: InputBorder.none,
            suffixIcon: IconButton(
              icon: const Icon(Icons.search, semanticLabel: 'Rechercher'),
              onPressed: () => _submit(),
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Importer (Spotify / JSON)',
            onPressed: () => context.push('/discovery/import'),
          ),
        ],
      ),
      body: showAutocomplete
          ? _AutocompletePanel(onSelect: _submit)
          : activeQuery.isEmpty
              ? const _SuggestionsPanel()
              : results.when(
                  data: (data) => data.isEmpty
                      ? const Center(child: Text('Aucun résultat.'))
                      : ListView.builder(
                          itemCount: data.length,
                          itemBuilder: (context, index) => _ResultTile(result: data[index]),
                        ),
                  loading: () => ListView(children: List.generate(6, (_) => const SkeletonLoader())),
                  error: (error, _) => Center(child: Text('Erreur de recherche : $error')),
                ),
    );
  }
}

/// Menu déroulant d'autocomplétion (Google/Spotify-style) : matchs locaux
/// d'abord, puis en ligne, puis un repli "Rechercher '...'" — stylisé selon
/// la Vibe active (fond semi-translucide, icônes teintées à l'accent).
/// [onSelect] remplit le champ ET soumet ; pour un artiste, on navigue
/// directement vers son profil à la place (fiche existante, plus utile
/// qu'un simple remplissage de champ).
class _AutocompletePanel extends ConsumerWidget {
  const _AutocompletePanel({required this.onSelect});

  final void Function(String text) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<AutocompleteSuggestion>> suggestions = ref.watch(autocompleteSuggestionsProvider);
    final VibeVisual vibe = ref.watch(activeVibeProvider);

    return Container(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
      child: suggestions.when(
        data: (data) {
          if (data.isEmpty) return const SizedBox.shrink();

          // Ordre d'affichage strict imposé par la charte de recherche :
          // Artistes en haut, Titres en bas — déjà l'ordre renvoyé par
          // AutocompleteRepository.suggest, ce regroupement ajoute juste les
          // en-têtes de section (le reste, ex. "Rechercher '...'", suit tel quel).
          final List<AutocompleteSuggestion> artists = data.where((s) => s.kind == SuggestionKind.artist).toList();
          final List<AutocompleteSuggestion> tracks = data.where((s) => s.kind == SuggestionKind.track).toList();
          final List<AutocompleteSuggestion> rest =
              data.where((s) => s.kind != SuggestionKind.artist && s.kind != SuggestionKind.track).toList();

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              if (artists.isNotEmpty) _AutocompleteSectionHeader('Artistes'),
              for (final suggestion in artists)
                _AutocompleteTile(suggestion: suggestion, accentColor: vibe.accentColor, onSelect: onSelect),
              if (tracks.isNotEmpty) _AutocompleteSectionHeader('Titres'),
              for (final suggestion in tracks)
                _AutocompleteTile(suggestion: suggestion, accentColor: vibe.accentColor, onSelect: onSelect),
              for (final suggestion in rest)
                _AutocompleteTile(suggestion: suggestion, accentColor: vibe.accentColor, onSelect: onSelect),
            ],
          );
        },
        loading: () => Padding(
          padding: const EdgeInsets.all(16),
          child: LinearProgressIndicator(color: vibe.accentColor),
        ),
        error: (error, _) => const SizedBox.shrink(),
      ),
    );
  }
}

class _AutocompleteSectionHeader extends StatelessWidget {
  const _AutocompleteSectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
      ),
    );
  }
}

class _AutocompleteTile extends StatelessWidget {
  const _AutocompleteTile({required this.suggestion, required this.accentColor, required this.onSelect});

  final AutocompleteSuggestion suggestion;
  final Color accentColor;
  final void Function(String text) onSelect;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: suggestion.artworkUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                suggestion.artworkUrl!,
                semanticLabel: 'Pochette de ${suggestion.label}',
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Icon(_iconFor(suggestion.kind), color: accentColor),
              ),
            )
          : Icon(_iconFor(suggestion.kind), color: accentColor),
      title: Text(suggestion.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle:
          suggestion.subtitle == null ? null : Text(suggestion.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: suggestion.kind == SuggestionKind.artist ? const Icon(Icons.chevron_right, size: 18) : null,
      onTap: () {
        if (suggestion.kind == SuggestionKind.artist) {
          context.push('/discovery/artist/${suggestion.label}');
        } else {
          onSelect(suggestion.label);
        }
      },
    );
  }

  IconData _iconFor(SuggestionKind kind) => switch (kind) {
        SuggestionKind.track => Icons.music_note,
        SuggestionKind.artist => Icons.person_outline,
        SuggestionKind.album => Icons.album_outlined,
        SuggestionKind.query => Icons.search,
      };
}

/// Tableau de bord affiché quand la recherche est vide : tes playlists, puis
/// les 7 artistes les plus présents dans ta bibliothèque locale (Section 5.2
/// — le carrousel "Suggestions d'artistes" ne montre plus que ça, ni Mots-clés
/// ni filtre "Playlist"/"Local / Banque de données", supprimés avec l'ancien
/// moteur de recommandation, voir Section 5.1).
class _SuggestionsPanel extends ConsumerWidget {
  const _SuggestionsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);
    final AsyncValue<List<TopArtistPlaylist>> topArtists = ref.watch(topArtistPlaylistsProvider);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16),
      children: [
        playlists.maybeWhen(
          data: (data) => data.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text('Tes playlists', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                      const SizedBox(height: AppSpacing.s),
                      SizedBox(
                        height: 220,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          scrollDirection: Axis.horizontal,
                          itemCount: data.length,
                          separatorBuilder: (context, index) => const SizedBox(width: AppSpacing.m),
                          itemBuilder: (context, index) => PlaylistCard(
                            playlist: data[index],
                            onTap: () => playPlaylistAndNavigate(context, ref, data[index]),
                            onLongPress: () => context.push('/space/playlist/${data[index].id}/edit'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          orElse: () => const SizedBox.shrink(),
        ),
        topArtists.when(
          data: (data) => data.isEmpty
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child:
                            Text("Suggestions d'artistes", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                      const SizedBox(height: AppSpacing.s),
                      SizedBox(
                        height: 220,
                        child: ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          scrollDirection: Axis.horizontal,
                          itemCount: data.length,
                          separatorBuilder: (context, index) => const SizedBox(width: AppSpacing.m),
                          itemBuilder: (context, index) => _TopArtistPlaylistCard(playlist: data[index]),
                        ),
                      ),
                    ],
                  ),
                ),
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(),
          ),
          error: (error, _) => const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Lecture immédiate d'un artiste du carrousel (Section 2) — appui simple :
/// charge tous ses morceaux locaux (même périmètre que l'onglet "Dans ta
/// bibliothèque" de la fiche artiste, [ArtistFilter.all]/[ArtistSort.
/// chronological]) et démarre la lecture au premier morceau. Ne fait rien si
/// l'artiste n'a aucun morceau local (jamais les extraits en ligne 30s, qui
/// ne sont lus qu'à la demande explicite — voir ArtistProfileScreen). Id de
/// playlist synthétique (aucune ligne `Playlists` correspondante, voir
/// [TopArtistPlaylist]) : la Vibe retombe simplement sur le repli neutre
/// (voir `activeVibeProvider`), sans incidence puisque Découverte n'a jamais
/// d'effet sur la Vibe.
///
/// Bug QA "le tap ne lance la lecture qu'après un appui long" : l'ancienne
/// version attendait `ref.read(artistTracksProvider(...).future)`. Sans
/// listener actif, Riverpod met ce StreamProvider en pause et le `Future` ne
/// se résout jamais — sauf si la fiche artiste (appui long) avait déjà
/// écouté ce même provider juste avant. Lecture directe du repository, comme
/// `AddByArtistSheet._addArtist` qui avait rencontré le même piège.
Future<void> _playTopArtistPlaylist(BuildContext context, WidgetRef ref, TopArtistPlaylist playlist) async {
  final List<Track> tracks = await ref
      .read(artistRepositoryProvider)
      .watchArtistTracks(playlist.artistName, filter: ArtistFilter.all, sort: ArtistSort.chronological)
      .first;
  if (tracks.isEmpty) return;
  await ref.read(playerControllerProvider.notifier).playPlaylist('discovery-artist-${playlist.artistName}', tracks);
  if (context.mounted) context.go('/player');
}

/// Carte d'une playlist auto-générée par artiste (Section 5.2) — même gabarit
/// visuel que [PlaylistCard] (pochette carrée + titre + sous-titre), mais
/// jamais construite à partir d'une vraie `Playlist` (voir [TopArtistPlaylist]).
/// Appui simple = lecture immédiate ([_playTopArtistPlaylist]) ; appui long =
/// fiche artiste détaillée (Section 5.3 — morceaux locaux + suggestions en
/// ligne avec extraits 30s), l'ancien comportement du tap simple (Section 2).
class _TopArtistPlaylistCard extends ConsumerWidget {
  const _TopArtistPlaylistCard({required this.playlist});

  final TopArtistPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? coverPath = playlist.coverArtPath;
    return SizedBox(
      width: 152,
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.card)),
        onTap: () => _playTopArtistPlaylist(context, ref, playlist),
        onLongPress: () => context.push('/discovery/artist/${playlist.artistName}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(AppRadii.card)),
                child: coverPath == null
                    ? Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.person_outline, size: 40),
                      )
                    : Image(
                        image: coverPath.startsWith('http')
                            ? NetworkImage(coverPath)
                            : FileImage(File(coverPath)) as ImageProvider,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.person_outline, size: 40),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: AppSpacing.s),
            Text(
              playlist.artistName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              '${playlist.trackCount} morceau${playlist.trackCount > 1 ? 'x' : ''}',
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

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result});

  final SearchResult result;

  @override
  Widget build(BuildContext context) {
    return switch (result) {
      TrackSearchResult(:final track) => ListTile(
          leading: const Icon(Icons.music_note),
          title: Text(track.title),
          subtitle: Text(track.artists.join(', ')),
          trailing: IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'Ajouter à une playlist',
            onPressed: () => AddToPlaylistSheet.show(context, track.id),
          ),
          onLongPress: () => TrackActionsSheet.show(context, track),
        ),
      PlaylistSearchResult(:final playlist) => ListTile(
          leading: const Icon(Icons.queue_music),
          title: Text(playlist.title),
        ),
      ArtistSearchResult(:final artistName) => ListTile(
          leading: const Icon(Icons.person_outline),
          title: Text(artistName),
          onTap: () => context.push('/discovery/artist/$artistName'),
          onLongPress: () => context.push('/discovery/artist/$artistName'),
        ),
      OnlineTrackSearchResult(:final track) => OnlineTrackCard(track: track),
    };
  }
}
