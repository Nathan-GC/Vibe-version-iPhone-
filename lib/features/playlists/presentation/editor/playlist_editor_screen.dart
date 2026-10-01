import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/identity/track_search.dart';
import '../../../../core/platform/gallery_image_picker.dart';
import '../../../../core/shared/widgets/local_track_picker_sheet.dart';
import '../../../../core/shared/widgets/playlist_cover_image.dart';
import '../../../../core/shared/widgets/track_actions_sheet.dart';
import '../../../../core/storage/database/app_database.dart';
import '../../../../core/storage/database/track_repository.dart';
import '../../../../core/theme/design_system/app_spacing.dart';
import '../../../library/data/library_providers.dart';
import '../../data/playlist_providers.dart';
import '../../domain/playlist_editor_entry.dart';
import 'add_by_artist_sheet.dart';

/// Éditeur drag-and-drop d'une playlist (Étape 5). Le réordonnancement ne
/// touche que l'état local ; "Enregistrer" commit en base : purge
/// `is_pending_placement` (retire les contours ambre), persiste les
/// `position`, incrémente `version`.
class PlaylistEditorScreen extends ConsumerStatefulWidget {
  const PlaylistEditorScreen({super.key, required this.playlistId});

  final String playlistId;

  @override
  ConsumerState<PlaylistEditorScreen> createState() => _PlaylistEditorScreenState();
}

class _PlaylistEditorScreenState extends ConsumerState<PlaylistEditorScreen> {
  List<PlaylistEditorEntry>? _localOrder;
  bool _saving = false;

  /// Barre de recherche (titre + artiste, sans casse ni accents — voir
  /// [trackMatchesSearch]) réservée à "Tous les titres importés" : la seule
  /// playlist qui grossit avec toute la bibliothèque.
  bool get _searchEnabled => widget.playlistId == kAllImportedPlaylistId;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  bool get _isSearching => _query.trim().isNotEmpty;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
  }

  bool _entryMatches(PlaylistEditorEntry entry) => trackMatchesSearch(
        title: entry.title,
        artists: entry.track?.artists ?? [entry.missing!.artist],
        query: _query,
      );

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final List<PlaylistEditorEntry> list = [..._localOrder!];
      final PlaylistEditorEntry item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
      _localOrder = list;
    });
  }

  /// `_localOrder` n'est peuplé qu'une fois (voir le commentaire sur
  /// `entries.whenData` plus bas) — une action venue de TrackActionsSheet
  /// (retrait de la playlist) ou d'AddByArtistSheet (ajout en masse) ne s'y
  /// refléterait donc jamais sans une resynchronisation explicite après coup.
  ///
  /// Récupère directement un instantané frais via le repository (`.first` sur
  /// son Stream) plutôt que de vider `_localOrder` et compter sur
  /// `entries.whenData` / `ref.watch(playlistEditorEntriesProvider(...))`
  /// pour le repeupler tout seul au prochain rebuild : bug réel reproduit —
  /// après "Ajouter par artiste", les morceaux étaient bien écrits en base
  /// (confirmé par le Snackbar et une requête SQL directe) mais l'écran
  /// continuait d'afficher l'ancienne liste indéfiniment, y compris après
  /// avoir simplement vidé `_localOrder` et même après `ref.invalidate` sur
  /// ce provider — la ré-émission du flux Drift retriggée par l'invalidation
  /// n'arrivait, pour une raison qui reste à élucider dans le comportement de
  /// ce `StreamProvider`, jamais à déclencher un nouveau `entries.whenData`.
  /// Aller chercher explicitement la donnée fraîche et l'assigner directement
  /// élimine toute dépendance à ce timing.
  Future<void> _refreshLocalOrder() async {
    final List<PlaylistEditorEntry> fresh =
        await ref.read(playlistRepositoryProvider).watchEditorEntries(widget.playlistId).first;
    if (!mounted) return;
    setState(() => _localOrder = fresh);
  }

  Future<void> _openTrackActions(Track track) async {
    // `onChanged` (pas seulement l'attente de `show()`) : une action comme
    // "Modifier les métadonnées" ferme cette feuille avant même d'ouvrir son
    // propre dialogue de saisie, donc attendre uniquement `show()` déclenchait
    // la resynchro trop tôt — le titre affiché restait périmé jusqu'à quitter
    // puis rouvrir l'écran. Voir le commentaire de `TrackActionsSheet.onChanged`.
    await TrackActionsSheet.show(
      context,
      track,
      currentPlaylistId: widget.playlistId,
      onChanged: _refreshLocalOrder,
    );
    if (mounted) await _refreshLocalOrder();
  }

  /// Titre grisé (import JSON sans morceau local) : l'associer à un morceau
  /// de la bibliothèque, ou le retirer de la playlist.
  Future<void> _openMissingActions(PlaylistMissingTrack missing) async {
    final _MissingAction? action = await showModalBottomSheet<_MissingAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(missing.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${missing.artist} · introuvable dans ta bibliothèque'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Associer à un morceau de ma bibliothèque'),
              onTap: () => Navigator.of(context).pop(_MissingAction.link),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('Retirer de la playlist'),
              onTap: () => Navigator.of(context).pop(_MissingAction.remove),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _MissingAction.link:
        final Set<String> inPlaylist = {
          for (final PlaylistEditorEntry entry in _localOrder ?? const [])
            if (entry.track != null) entry.track!.id,
        };
        final Track? picked = await LocalTrackPickerSheet.show(
          context,
          title: 'Associer « ${missing.title} »',
          initialQuery: missing.title,
          unavailableIds: inPlaylist,
          unavailableLabel: 'Déjà dans la playlist',
        );
        if (picked == null) return;
        await ref.read(playlistRepositoryProvider).linkMissingEntry(missing.id, picked.id);
      case _MissingAction.remove:
        await ref.read(playlistRepositoryProvider).removeMissingEntry(missing.id);
    }
    if (mounted) await _refreshLocalOrder();
  }

  Future<void> _openAddByArtist() async {
    await AddByArtistSheet.show(context, widget.playlistId);
    if (mounted) await _refreshLocalOrder();
  }

  /// Pochette personnalisée (Design System) — distincte du fond du Vibe
  /// Creator (`/vibe`) : cette image alimente uniquement PlaylistCard, pas le
  /// fond plein écran du Player.
  Future<void> _pickCoverImage() async {
    final XFile? picked = await pickGalleryImage();
    if (picked == null || !mounted) return;

    final File imported =
        await ref.read(storageManagerServiceProvider).importPlaylistCoverImage(File(picked.path), widget.playlistId);
    await ref.read(playlistRepositoryProvider).updateCoverImagePath(widget.playlistId, imported.path);
  }

  Future<void> _commit() async {
    if (_localOrder == null) return;
    setState(() => _saving = true);

    // Titres grisés compris : ils gardent la place où l'utilisateur les a
    // déplacés (numérotation commune, voir PlaylistMissingTracks).
    await ref.read(playlistRepositoryProvider).commitOrder(widget.playlistId, _localOrder!);

    if (!mounted) return;
    setState(() {
      _saving = false;
      _localOrder = null; // reprend le flux à jour : plus de pending, version incrémentée.
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Playlist enregistrée')));
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<PlaylistEditorEntry>> entries = ref.watch(playlistEditorEntriesProvider(widget.playlistId));
    final AsyncValue<Playlist?> playlist = ref.watch(playlistByIdProvider(widget.playlistId));
    // Doit s'exécuter avant la construction du Scaffold ci-dessous : `appBar`
    // lit `_localOrder` pour (dés)activer le bouton Enregistrer, et Dart
    // évalue les arguments nommés d'un même appel dans l'ordre du code —
    // peupler `_localOrder` à l'intérieur de `body:` (plus bas dans l'appel)
    // arrivait donc une évaluation trop tard : le tout premier frame où les
    // données arrivaient rendait le bouton désactivé, sans jamais se
    // rafraîchir ensuite puisque cette affectation ne passe pas par setState.
    entries.whenData((data) => _localOrder ??= data);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Éditeur'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_outlined),
            tooltip: 'Ajouter par artiste',
            onPressed: _openAddByArtist,
          ),
          IconButton(
            icon: _saving
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined, semanticLabel: 'Enregistrer la playlist'),
            onPressed: (_localOrder == null || _saving) ? null : _commit,
          ),
        ],
      ),
      body: Column(
        children: [
          if (playlist.value != null) _CoverHeader(playlist: playlist.value!, onPickImage: _pickCoverImage),
          if (_searchEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.m, 0, AppSpacing.m, AppSpacing.s),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Rechercher un titre ou un artiste',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(icon: const Icon(Icons.clear), tooltip: 'Effacer', onPressed: _clearSearch),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
          Expanded(
            child: entries.when(
              data: (data) {
                final List<PlaylistEditorEntry> list = _localOrder!;
                if (list.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'Playlist vide — utilise "Ajouter par artiste" en haut de l\'écran pour lui ajouter des morceaux.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                // Recherche active : simple liste filtrée, sans glisser-
                // déposer — réordonner un sous-ensemble filtré n'aurait pas
                // de position cohérente dans la playlist complète.
                if (_isSearching) {
                  final List<PlaylistEditorEntry> results = list.where(_entryMatches).toList();
                  if (results.isEmpty) {
                    return const Center(child: Text('Aucun titre ne correspond à cette recherche.'));
                  }
                  return ListView.builder(
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final PlaylistEditorEntry entry = results[index];
                      final Track? track = entry.track;
                      return _EditorTile(
                        key: ValueKey(entry.key),
                        index: index,
                        entry: entry,
                        showDragHandle: false,
                        onTap: track == null ? () => _openMissingActions(entry.missing!) : null,
                        onLongPress:
                            track != null ? () => _openTrackActions(track) : () => _openMissingActions(entry.missing!),
                      );
                    },
                  );
                }

                final int missingCount = list.where((e) => e.isMissing).length;
                return Column(
                  children: [
                    if (missingCount > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline, size: 18, color: Theme.of(context).colorScheme.outline),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '$missingCount titre${missingCount > 1 ? 's' : ''} introuvable${missingCount > 1 ? 's' : ''} '
                                '(grisé${missingCount > 1 ? 's' : ''}) : sauté${missingCount > 1 ? 's' : ''} à la lecture, '
                                'associé${missingCount > 1 ? 's' : ''} automatiquement dès l\'ajout du fichier à ta bibliothèque.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ReorderableListView.builder(
                        // Poignée de drag explicite (voir _EditorTile) plutôt que le
                        // comportement par défaut (glisser-déposer déclenché par un
                        // appui long sur toute la tuile) : cette tuile a déjà son
                        // propre `onLongPress` (ouvre TrackActionsSheet), et les deux
                        // gestes en appui long entraient en conflit dans l'arène de
                        // gestes — bug réel reproduit : le drag ne démarrait jamais
                        // de façon fiable. Isoler le drag sur l'icône dédiée lève
                        // l'ambiguïté.
                        buildDefaultDragHandles: false,
                        itemCount: list.length,
                        onReorderItem: _reorder,
                        itemBuilder: (context, index) {
                          final PlaylistEditorEntry entry = list[index];
                          final Track? track = entry.track;
                          return _EditorTile(
                            key: ValueKey(entry.key),
                            index: index,
                            entry: entry,
                            // Titre grisé : appui simple ET long ouvrent ses
                            // actions (associer / retirer) — il n'a pas d'autre
                            // action principale, n'étant pas lisible.
                            onTap: track == null ? () => _openMissingActions(entry.missing!) : null,
                            onLongPress: track != null
                                ? () => _openTrackActions(track)
                                : () => _openMissingActions(entry.missing!),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text('Erreur : $error')),
            ),
          ),
        ],
      ),
    );
  }
}

/// Aperçu de la pochette personnalisée en tête de l'éditeur, avec le bouton
/// "Changer l'image" demandé par la charte graphique — distinct du Vibe
/// Creator (`/vibe`, fond plein écran du Player).
class _CoverHeader extends StatelessWidget {
  const _CoverHeader({required this.playlist, required this.onPickImage});

  final Playlist playlist;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.m),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            height: 88,
            child: PlaylistCoverImage(playlist: playlist),
          ),
          const SizedBox(width: AppSpacing.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(playlist.title,
                    style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.s),
                OutlinedButton.icon(
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Changer l\'image'),
                  onPressed: onPickImage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _MissingAction { link, remove }

class _EditorTile extends StatelessWidget {
  const _EditorTile({
    super.key,
    required this.index,
    required this.entry,
    required this.onLongPress,
    this.onTap,
    this.showDragHandle = true,
  });

  final int index;
  final PlaylistEditorEntry entry;
  final VoidCallback onLongPress;
  final VoidCallback? onTap;

  /// `false` hors d'une `ReorderableListView` (résultats de recherche) :
  /// [ReorderableDragStartListener] exige un ancêtre réordonnable.
  final bool showDragHandle;

  @override
  Widget build(BuildContext context) {
    // Titre grisé : couleur atténuée (texte ET icônes), mention
    // "introuvable" — reste déplaçable pour garder sa place dans l'ordre.
    final bool missing = entry.isMissing;
    final Color? dimmed = missing ? Theme.of(context).disabledColor : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: entry.isPendingPlacement ? Border.all(color: Colors.amber, width: 2) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        leading: missing ? Icon(Icons.link_off, color: dimmed) : null,
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: dimmed)),
        subtitle: Text(
          missing ? '${entry.artistLabel} · introuvable' : entry.artistLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: dimmed, fontStyle: missing ? FontStyle.italic : null),
        ),
        trailing: showDragHandle
            ? ReorderableDragStartListener(index: index, child: Icon(Icons.drag_handle, color: dimmed))
            : null,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
