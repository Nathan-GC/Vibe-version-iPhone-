import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../../../core/audio_engine/preview_player_controller.dart';
import '../../../core/networking/metadata_api_client/online_track_result.dart';
import '../../../core/platform/gallery_image_picker.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/track_enricher.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/storage/filename_sanitizer/filename_sanitizer.dart';
import '../data/library_providers.dart';

/// Terme de recherche par défaut tiré du nom du fichier audio, pour un
/// morceau "À renommer" (Titre/Artiste trop ambigus pour une recherche
/// automatique). Un fichier importé est stocké sous `{artiste}-{titre}.mp3`
/// (StorageManagerService.importAudioFile) : on retire le préfixe
/// `Unknown-` d'un artiste non déduit et le suffixe ` (2)` d'anti-collision,
/// et on remplace `_`/`-` par des espaces (texte libre pour iTunes/MusicBrainz).
/// Repli sur [fallbackTitle] (titre existant) si le nom n'apporte rien.
String searchQueryFromFilePath(String filePath, {required String fallbackTitle}) {
  final String query = p
      .basenameWithoutExtension(filePath)
      .replaceFirst(RegExp(r'\s\(\d+\)$'), '')
      .replaceFirst(RegExp(r'^unknown-', caseSensitive: false), '')
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return query.isEmpty ? fallbackTitle.trim() : query;
}

/// Éditeur manuel de métadonnées — accessible à tout moment sur n'importe
/// quel morceau ("À renommer" ou déjà enrichi, ré-enrichissement ou
/// simple correction), pas seulement au premier import. Deux façons de
/// renseigner les champs :
///   1. Recherche API : deux champs Artiste/Titre dédiés à la recherche
///      (pré-remplis à l'ouverture depuis les tags actuels ou, à défaut, le
///      nom de fichier nettoyé), recherche auto-déclenchée après un debounce
///      ou via le bouton "Rechercher", tap sur un résultat pour appliquer sa
///      fiche complète aux champs manuels ci-dessous.
///   2. Saisie manuelle : Titre, Artiste, Album, Année, Genre et Pochette
///      sont tous directement éditables, sans passer par une suggestion —
///      des champs distincts de ceux de la recherche (voir 1.), jamais
///      synchronisés automatiquement dans l'autre sens.
/// Toujours persisté immédiatement dans Drift via `TrackRepository.
/// updateMetadata` — jamais de brouillon local qui se perdrait.
class MetadataEditorModal extends ConsumerStatefulWidget {
  const MetadataEditorModal({super.key, required this.track, this.initialSearchQuery});

  final Track track;

  /// Terme de recherche imposé à l'ouverture (recherche lancée aussitôt), en
  /// texte libre dans le champ Titre de recherche, champ Artiste vide — voir
  /// [searchQueryFromFilePath] (bouton ✨ sur un morceau "À renommer").
  /// `null` : pré-remplissage habituel depuis Artiste/Titre actuels.
  final String? initialSearchQuery;

  @override
  ConsumerState<MetadataEditorModal> createState() => _MetadataEditorModalState();
}

class _MetadataEditorModalState extends ConsumerState<MetadataEditorModal> {
  late final TextEditingController _artistController;
  late final TextEditingController _titleController;
  late final TextEditingController _albumController;
  late final TextEditingController _yearController;
  late final TextEditingController _genreController;

  // Champs de recherche (Option 1), distincts des champs de saisie manuelle
  // ci-dessus : taper ici ne modifie jamais l'Artiste/Titre manuels tant que
  // l'utilisateur n'a pas explicitement tapé sur une suggestion.
  late final TextEditingController _searchArtistController;
  late final TextEditingController _searchTitleController;
  Timer? _searchDebounce;
  static const Duration _searchDebounceDelay = Duration(milliseconds: 500);

  bool _loadingSuggestions = true;
  List<OnlineTrackResult> _suggestions = const [];
  bool _fetchFailed = false;
  String? _selectedCoverArtUrl;
  bool _saving = false;

  // Sélecteur de source (Section 2.3) — bascule laquelle des deux API
  // interroge les deux champs Artiste/Titre ci-dessus, sans changer le reste
  // du flux (affichage des résultats, application sur les champs manuels).
  EnrichmentSource _searchSource = EnrichmentSource.itunes;

  // Dernière suggestion appliquée (Section 1) — comparée à l'enregistrement
  // pour distinguer une "validation de match" d'une simple saisie manuelle,
  // voir [_resolveEnrichmentStatus]. `null` tant qu'aucune suggestion n'a été
  // tapée dans cette session d'édition.
  OnlineTrackResult? _lastAppliedSuggestion;
  EnrichmentSource? _appliedSuggestionSource;

  @override
  void initState() {
    super.initState();
    final String initialArtist = widget.track.artists.isNotEmpty ? widget.track.artists.first : '';
    _artistController = TextEditingController(text: initialArtist == 'Unknown' ? '' : initialArtist);
    _titleController = TextEditingController(text: widget.track.title);
    _albumController = TextEditingController(text: widget.track.album);
    _yearController = TextEditingController(text: widget.track.releaseYear > 0 ? '${widget.track.releaseYear}' : '');
    _genreController = TextEditingController(text: widget.track.tags.isNotEmpty ? widget.track.tags.first : '');

    // Pré-remplissage : privilégie l'Artiste/Titre déjà connus (déjà tagués
    // ou en cours de ré-enrichissement) — le repli sur le nom de fichier
    // nettoyé ne sert plus qu'aux morceaux réellement ambigus ("À renommer",
    // artiste/titre encore vides à ce stade).
    String initialSearchArtist = _artistController.text.trim();
    String initialSearchTitle = _titleController.text.trim();
    if (widget.initialSearchQuery != null) {
      initialSearchArtist = '';
      initialSearchTitle = widget.initialSearchQuery!;
    } else if (initialSearchArtist.isEmpty && initialSearchTitle.isEmpty) {
      final SanitizedFilename cleaned = FilenameSanitizer().sanitizeFilename(p.basename(widget.track.filePath));
      initialSearchArtist = cleaned.artist == 'Unknown' ? '' : cleaned.artist;
      initialSearchTitle = cleaned.title;
    }
    _searchArtistController = TextEditingController(text: initialSearchArtist);
    _searchTitleController = TextEditingController(text: initialSearchTitle);

    _selectedCoverArtUrl = widget.track.coverArtPath.isEmpty ? null : widget.track.coverArtPath;
    WidgetsBinding.instance.addPostFrameCallback((_) => _performSearch());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _artistController.dispose();
    _titleController.dispose();
    _albumController.dispose();
    _yearController.dispose();
    _genreController.dispose();
    _searchArtistController.dispose();
    _searchTitleController.dispose();
    super.dispose();
  }

  /// Redéclenche la recherche après [_searchDebounceDelay] d'inactivité dans
  /// l'un ou l'autre champ — annule tout timer déjà en attente pour ne
  /// lancer qu'une requête par pause de saisie.
  void _onSearchFieldChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDebounceDelay, _performSearch);
  }

  /// Recherche iTunes (Option 1) à partir des deux champs Artiste/Titre
  /// dédiés — déclenchée par le debounce, le bouton "Rechercher", ou à
  /// l'ouverture de la modale.
  Future<void> _performSearch() async {
    _searchDebounce?.cancel();
    final String artist = _searchArtistController.text.trim();
    final String title = _searchTitleController.text.trim();

    setState(() {
      _loadingSuggestions = true;
      _fetchFailed = false;
    });

    List<OnlineTrackResult> results = const [];
    bool failed = false;
    if (artist.isNotEmpty || title.isNotEmpty) {
      try {
        results = switch (_searchSource) {
          EnrichmentSource.itunes =>
            await ref.read(metadataApiClientProvider).searchByArtistAndTitle(artist: artist, title: title, limit: 5),
          EnrichmentSource.musicBrainz =>
            await ref.read(musicBrainzClientProvider).searchRecordings(artist: artist, title: title),
        };
      } catch (_) {
        // Pas de réseau, timeout, API indisponible... — la modale reste
        // utilisable en saisie manuelle, mais on distingue ce cas de "aucune
        // correspondance trouvée" pour permettre une nouvelle tentative.
        failed = true;
      }
    }

    if (!mounted) return;
    setState(() {
      _suggestions = results.take(5).toList();
      _loadingSuggestions = false;
      _fetchFailed = failed;
    });
  }

  void _applySuggestion(OnlineTrackResult suggestion) {
    setState(() {
      _artistController.text = suggestion.artist;
      _titleController.text = suggestion.title;
      _albumController.text = suggestion.album ?? '';
      _yearController.text = suggestion.releaseYear?.toString() ?? '';
      if (suggestion.genre != null) _genreController.text = suggestion.genre!;
      _selectedCoverArtUrl = suggestion.coverArtUrl;
      _lastAppliedSuggestion = suggestion;
      _appliedSuggestionSource = _searchSource;
    });
  }

  /// Statut de provenance appliqué à l'enregistrement (Section 1) : si
  /// Artiste/Titre sont encore exactement ceux de la dernière suggestion
  /// tapée, l'utilisateur vient de "valider un match" (source de cette
  /// suggestion) ; toute retouche d'Artiste/Titre après coup repasse en
  /// édition manuelle pure, même si une suggestion avait été tapée avant.
  EnrichmentStatus _resolveEnrichmentStatus() {
    final OnlineTrackResult? suggestion = _lastAppliedSuggestion;
    final EnrichmentSource? source = _appliedSuggestionSource;
    if (suggestion == null || source == null) return EnrichmentStatus.enrichedManualEdit;
    if (_artistController.text.trim() != suggestion.artist || _titleController.text.trim() != suggestion.title) {
      return EnrichmentStatus.enrichedManualEdit;
    }
    return source == EnrichmentSource.itunes
        ? EnrichmentStatus.enrichedManualItunes
        : EnrichmentStatus.enrichedManualMusicBrainz;
  }

  /// Pochette manuelle (Option 2) — même mécanique que
  /// `TrackActionsSheet._editCoverArt` : import dans le dossier de l'app puis
  /// chemin local stocké tel quel dans `coverArtPath` (double-usage avec les
  /// URL distantes des suggestions, voir `_CoverThumbnail`).
  Future<void> _pickCoverManually() async {
    final XFile? picked = await pickGalleryImage();
    if (picked == null || !mounted) return;

    final File imported =
        await ref.read(storageManagerServiceProvider).importTrackCoverImage(File(picked.path), widget.track.id);
    if (!mounted) return;
    setState(() => _selectedCoverArtUrl = imported.path);
  }

  Future<void> _save() async {
    final String artist = _artistController.text.trim();
    final String title = _titleController.text.trim();
    if (artist.isEmpty || title.isEmpty) return;

    setState(() => _saving = true);
    await ref.read(trackRepositoryProvider).updateMetadata(
          widget.track.id,
          title: title,
          artist: artist,
          album: _albumController.text.trim(),
          releaseYear: int.tryParse(_yearController.text.trim()),
          coverArtUrl: _selectedCoverArtUrl,
          genre: _genreController.text.trim(),
          enrichmentStatus: _resolveEnrichmentStatus(),
        );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Modifier les métadonnées'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CoverPreview(path: _selectedCoverArtUrl, onTap: _pickCoverManually),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                            controller: _artistController, decoration: const InputDecoration(labelText: 'Artiste')),
                        const SizedBox(height: 12),
                        TextField(controller: _titleController, decoration: const InputDecoration(labelText: 'Titre')),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(controller: _albumController, decoration: const InputDecoration(labelText: 'Album')),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _yearController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Année'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child:
                        TextField(controller: _genreController, decoration: const InputDecoration(labelText: 'Genre')),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Recherche en ligne', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<EnrichmentSource>(
                  segments: const [
                    ButtonSegment(
                        value: EnrichmentSource.itunes, label: Text('iTunes'), icon: Icon(Icons.apple, size: 16)),
                    ButtonSegment(
                      value: EnrichmentSource.musicBrainz,
                      label: Text('MusicBrainz'),
                      icon: Icon(Icons.library_music_outlined, size: 16),
                    ),
                  ],
                  selected: {_searchSource},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    setState(() => _searchSource = selection.first);
                    _performSearch();
                  },
                ),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        TextField(
                          controller: _searchArtistController,
                          decoration: const InputDecoration(labelText: 'Artiste', hintText: 'Artiste recherché'),
                          onChanged: (_) => _onSearchFieldChanged(),
                          onSubmitted: (_) => _performSearch(),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _searchTitleController,
                          decoration: const InputDecoration(labelText: 'Titre', hintText: 'Titre recherché'),
                          onChanged: (_) => _onSearchFieldChanged(),
                          onSubmitted: (_) => _performSearch(),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Rechercher',
                    onPressed: _performSearch,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_loadingSuggestions)
                const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())
              else if (_fetchFailed)
                Row(
                  children: [
                    const Expanded(child: Text('Connexion impossible.')),
                    TextButton(onPressed: _performSearch, child: const Text('Réessayer')),
                  ],
                )
              else if (_suggestions.isEmpty)
                const Text('Aucune suggestion trouvée.')
              else
                ..._suggestions.map((suggestion) {
                  final String? previewUrl = suggestion.previewUrl;
                  final String? activePreviewUrl = ref.watch(previewPlayerControllerProvider);
                  final bool isPlayingThis = previewUrl != null && activePreviewUrl == previewUrl;

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: suggestion.coverArtUrl != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              suggestion.coverArtUrl!,
                              width: 40,
                              height: 40,
                              fit: BoxFit.cover,
                              semanticLabel: 'Pochette proposée pour ${suggestion.title}',
                            ),
                          )
                        : const Icon(Icons.album_outlined),
                    title: Text('${suggestion.artist} - ${suggestion.title}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        if (suggestion.album != null) suggestion.album!,
                        if (suggestion.releaseYear != null) '${suggestion.releaseYear}'
                      ].join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: previewUrl == null
                        ? null
                        : IconButton(
                            icon: Icon(isPlayingThis ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                            tooltip: isPlayingThis ? 'Arrêter la preview' : 'Écouter un extrait',
                            onPressed: () =>
                                ref.read(previewPlayerControllerProvider.notifier).togglePreview(previewUrl),
                          ),
                    onTap: () => _applySuggestion(suggestion),
                  );
                }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Enregistrer'),
        ),
      ],
    );
  }
}

/// Aperçu 56x56 de la pochette sélectionnée (suggestion API ou import
/// manuel) — double-usage URL distante/chemin local, comme partout ailleurs
/// dans l'app (voir `PlaylistCoverImage`, `_CoverThumbnail` de LibraryScreen).
class _CoverPreview extends StatelessWidget {
  const _CoverPreview({required this.path, required this.onTap});

  final String? path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String? p = path;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 56,
          height: 56,
          child: p == null || p.isEmpty
              ? ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.add_photo_alternate_outlined),
                )
              : Image(
                  image: p.startsWith('http') ? NetworkImage(p) : FileImage(File(p)) as ImageProvider,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const ColoredBox(
                    color: Colors.black26,
                    child: Icon(Icons.broken_image_outlined),
                  ),
                ),
        ),
      ),
    );
  }
}
