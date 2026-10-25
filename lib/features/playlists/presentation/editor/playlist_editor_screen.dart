import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../domain/block_reorder.dart';
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

  /// Clés de [_localOrder] telles que lues/enregistrées en base la dernière
  /// fois : sert à savoir si l'utilisateur a réordonné depuis (voir
  /// [_hasUnsaved]).
  List<String> _savedKeys = const [];
  bool _saving = false;

  /// Réorganisation intelligente par bloc (Lot 3.2), activée par son propre
  /// bouton : le long-appui reste réservé aux actions du titre. Temps 1 :
  /// cocher des titres, même éloignés ([_selectedKeys], clés
  /// [PlaylistEditorEntry.key]) ; temps 2 : "Déplacer…" vers une position.
  bool _smartReorder = false;
  final Set<String> _selectedKeys = {};

  /// Barre de recherche (titre + artiste, sans casse ni accents — voir
  /// [trackMatchesSearch]) réservée à "Tous les titres importés" : la seule
  /// playlist qui grossit avec toute la bibliothèque.
  bool get _searchEnabled => widget.playlistId == kAllImportedPlaylistId;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  bool get _isSearching => _query.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Toujours un instantané frais de la base à l'ouverture : le provider du
    // flux reste en vie entre deux visites, sa première valeur pouvait donc
    // être une liste périmée (titres ajoutés depuis le Player invisibles).
    _refreshLocalOrder();
  }

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

  /// `_localOrder` n'est peuplé que par cet instantané (à l'ouverture, voir
  /// [initState], puis après chaque modification) — une action venue de TrackActionsSheet
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
    setState(() {
      _localOrder = fresh;
      _savedKeys = [for (final PlaylistEditorEntry entry in fresh) entry.key];
    });
  }

  /// Quelque chose n'est pas enregistré : ordre modifié depuis la dernière
  /// lecture/sauvegarde, titre au contour ambre (placement en attente) ou
  /// ajouté depuis le dernier enregistrement.
  bool get _hasUnsaved {
    final List<PlaylistEditorEntry>? list = _localOrder;
    if (list == null) return false;
    if (list.any((entry) => entry.isPendingPlacement || entry.addedSinceSave)) return true;
    if (list.length != _savedKeys.length) return true;
    for (int i = 0; i < list.length; i++) {
      if (list[i].key != _savedKeys[i]) return true;
    }
    return false;
  }

  /// Sortie (flèche de l'AppBar ou Retour Android) avec des changements non
  /// enregistrés. Fermer un dialogue sans choisir laisse dans l'éditeur.
  Future<void> _confirmLeave() async {
    if (_saving) return;
    final _LeaveChoice? choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Attention, vous n\'avez pas enregistré'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(_LeaveChoice.save), child: const Text('Enregistrer')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_LeaveChoice.savePartially),
            child: const Text('Enregistrer partiellement'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_LeaveChoice.discard),
            child: const Text('Ne pas enregistrer'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    switch (choice) {
      case _LeaveChoice.save:
        await _saveAndLeave(keepPending: false);
      case _LeaveChoice.savePartially:
        await _saveAndLeave(keepPending: true);
      case _LeaveChoice.discard:
        // Rien à départager : "Tous les titres importés" contient toujours
        // toute la bibliothèque, et sans titre ajouté depuis le dernier
        // enregistrement seul l'ordre avait changé.
        if (widget.playlistId == kAllImportedPlaylistId || !_localOrder!.any((entry) => entry.addedSinceSave)) {
          _leave();
          return;
        }
        final bool? keepAdded = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Titres ajoutés'),
            content: const Text('Que faire des titres ajoutés depuis le dernier enregistrement ?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Conserver les titres ajoutés'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Ne pas conserver les nouveaux titres'),
              ),
            ],
          ),
        );
        if (keepAdded == null || !mounted) return;
        if (!keepAdded) await ref.read(playlistRepositoryProvider).discardAdditionsSinceSave(widget.playlistId);
        if (mounted) _leave();
    }
  }

  /// Enregistrement complet (`keepPending: false`, les titres ambre sont
  /// considérés bien placés) ou partiel (ils restent ambre jusqu'à un
  /// enregistrement complet), puis sortie.
  Future<void> _saveAndLeave({required bool keepPending}) async {
    setState(() => _saving = true);
    await ref.read(playlistRepositoryProvider).commitOrder(widget.playlistId, _localOrder!, keepPending: keepPending);
    if (mounted) _leave();
  }

  /// `Navigator.pop` direct : contrairement à `maybePop`, il ne repasse pas
  /// par le [PopScope] qui a justement intercepté la sortie.
  void _leave() => Navigator.of(context).pop();

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

  Future<void> _commit({String message = 'Playlist enregistrée'}) async {
    if (_localOrder == null) return;
    setState(() => _saving = true);

    // Titres grisés compris : ils gardent la place où l'utilisateur les a
    // déplacés (numérotation commune, voir PlaylistMissingTracks). Une seule
    // transaction : toutes les positions changent ensemble, ou aucune.
    await ref.read(playlistRepositoryProvider).commitOrder(widget.playlistId, _localOrder!);

    // Ordre relu en base (plus de pending, version incrémentée) plutôt que
    // `_localOrder = null` : le flux pouvait encore porter l'ordre d'avant
    // l'enregistrement au rebuild suivant — voir [_refreshLocalOrder].
    if (mounted) await _refreshLocalOrder();
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _toggleSmartReorder() {
    if (!_smartReorder) _clearSearch(); // l'ordre complet, jamais un sous-ensemble filtré
    setState(() {
      _smartReorder = !_smartReorder;
      _selectedKeys.clear();
    });
  }

  void _toggleSelected(PlaylistEditorEntry entry) {
    setState(() {
      if (!_selectedKeys.remove(entry.key)) _selectedKeys.add(entry.key);
    });
  }

  /// Temps 2 : la position choisie est celle du 1er titre du bloc dans la
  /// playlist finale ; les titres cochés y sont réunis dans leur ordre
  /// actuel, puis l'ordre complet est enregistré d'un bloc ([_commit]).
  Future<void> _moveSelection() async {
    final List<PlaylistEditorEntry> list = _localOrder!;
    final Set<int> selected = {
      for (int i = 0; i < list.length; i++)
        if (_selectedKeys.contains(list[i].key)) i,
    };
    final int maxPosition = list.length - selected.length + 1;
    final int? position = await showDialog<int>(
      context: context,
      builder: (context) => _MoveBlockDialog(count: selected.length, maxPosition: maxPosition),
    );
    if (position == null || !mounted) return;

    setState(() {
      _localOrder = moveAsBlock(list, selected, position - 1);
      _selectedKeys.clear();
    });
    final int count = selected.length;
    await _commit(
      message: count > 1
          ? '$count titres regroupés en positions $position à ${position + count - 1}'
          : 'Titre déplacé en position $position',
    );
  }

  Widget _smartReorderList(List<PlaylistEditorEntry> list) {
    final int count = _selectedKeys.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.m, 0, AppSpacing.m, AppSpacing.s),
          child: Text(
            '1. Coche les titres à regrouper, même éloignés.\n'
            '2. « Déplacer » : ils sont réunis à la position choisie, dans leur ordre actuel.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, index) {
              final PlaylistEditorEntry entry = list[index];
              final Track? track = entry.track;
              return _EditorTile(
                key: ValueKey(entry.key),
                index: index,
                entry: entry,
                showDragHandle: false,
                selected: _selectedKeys.contains(entry.key),
                onTap: () => _toggleSelected(entry),
                onLongPress: track != null ? () => _openTrackActions(track) : () => _openMissingActions(entry.missing!),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.m),
            child: Row(
              children: [
                Expanded(
                  child: Text(count == 0
                      ? 'Aucun titre sélectionné'
                      : '$count titre${count > 1 ? 's' : ''} sélectionné${count > 1 ? 's' : ''}'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.low_priority),
                  label: const Text('Déplacer…'),
                  onPressed: count == 0 || _saving ? null : _moveSelection,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<Playlist?> playlist = ref.watch(playlistByIdProvider(widget.playlistId));
    // Chargement tant que l'instantané frais de [initState] n'est pas arrivé.
    final AsyncValue<List<PlaylistEditorEntry>> entries =
        _localOrder == null ? const AsyncLoading() : AsyncData(_localOrder!);

    return PopScope(
      canPop: !_hasUnsaved,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_smartReorder ? 'Réorganisation' : 'Éditeur'),
          actions: [
            IconButton(
              icon: Icon(_smartReorder ? Icons.close : Icons.low_priority),
              tooltip: _smartReorder ? 'Quitter la réorganisation intelligente' : 'Réorganisation intelligente',
              // Toujours possible d'en SORTIR, même si la playlist s'est vidée.
              onPressed: _saving || (!_smartReorder && (_localOrder?.isEmpty ?? true)) ? null : _toggleSmartReorder,
            ),
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
            if (_searchEnabled && !_smartReorder)
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

                  if (_smartReorder) return _smartReorderList(list);

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
                          onLongPress: track != null
                              ? () => _openTrackActions(track)
                              : () => _openMissingActions(entry.missing!),
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

enum _LeaveChoice { save, savePartially, discard }

class _EditorTile extends StatelessWidget {
  const _EditorTile({
    super.key,
    required this.index,
    required this.entry,
    required this.onLongPress,
    this.onTap,
    this.showDragHandle = true,
    this.selected,
  });

  final int index;
  final PlaylistEditorEntry entry;
  final VoidCallback onLongPress;
  final VoidCallback? onTap;

  /// `false` hors d'une `ReorderableListView` (résultats de recherche) :
  /// [ReorderableDragStartListener] exige un ancêtre réordonnable.
  final bool showDragHandle;

  /// Non nul en réorganisation intelligente (Lot 3.2) : case à cocher en
  /// tête et position (1, 2, 3...) en fin de ligne, pour viser la cible.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    // Titre grisé : couleur atténuée (texte ET icônes), mention
    // "introuvable" — reste déplaçable pour garder sa place dans l'ordre.
    final bool missing = entry.isMissing;
    final Color? dimmed = missing ? Theme.of(context).disabledColor : null;
    final bool? selected = this.selected;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        border: entry.isPendingPlacement ? Border.all(color: Colors.amber, width: 2) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        selected: selected ?? false,
        leading: selected != null
            ? Checkbox(
                value: selected,
                semanticLabel: 'Sélectionner ${entry.title}',
                onChanged: (_) => onTap?.call(),
              )
            : (missing ? Icon(Icons.link_off, color: dimmed) : null),
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: dimmed)),
        subtitle: Text(
          missing ? '${entry.artistLabel} · introuvable' : entry.artistLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: dimmed, fontStyle: missing ? FontStyle.italic : null),
        ),
        trailing: selected != null
            ? Text('${index + 1}', semanticsLabel: 'position ${index + 1}')
            : (showDragHandle
                ? ReorderableDragStartListener(index: index, child: Icon(Icons.drag_handle, color: dimmed))
                : null),
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}

/// Temps 2 de la réorganisation intelligente : position (1 à [maxPosition])
/// que prendra le 1er titre du bloc. StatefulWidget pour posséder (et
/// libérer) son propre contrôleur de saisie.
class _MoveBlockDialog extends StatefulWidget {
  const _MoveBlockDialog({required this.count, required this.maxPosition});

  final int count;
  final int maxPosition;

  @override
  State<_MoveBlockDialog> createState() => _MoveBlockDialogState();
}

class _MoveBlockDialogState extends State<_MoveBlockDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final int? position = int.tryParse(_controller.text);
    if (position == null) return;
    Navigator.of(context).pop(position.clamp(1, widget.maxPosition));
  }

  @override
  Widget build(BuildContext context) {
    final int count = widget.count;
    return AlertDialog(
      title: Text('Déplacer $count titre${count > 1 ? 's' : ''}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: 'Nouvelle position',
          helperText: 'De 1 à ${widget.maxPosition} — position du 1er titre du bloc',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(1), child: const Text('Au début')),
        TextButton(onPressed: () => Navigator.of(context).pop(widget.maxPosition), child: const Text('À la fin')),
        FilledButton(onPressed: _submit, child: const Text('Déplacer')),
      ],
    );
  }
}
