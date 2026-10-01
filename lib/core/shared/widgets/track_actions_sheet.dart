import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../features/library/data/library_providers.dart';
import '../../../features/library/presentation/metadata_editor_modal.dart';
import '../../../features/playlists/data/playlist_providers.dart';
import '../../audio_engine/preview_player_controller.dart';
import '../../platform/app_platform.dart';
import '../../platform/gallery_image_picker.dart';
import '../../storage/database/app_database.dart';
import '../../storage/database/library_category.dart';
import '../../storage/database/track_repository.dart';
import 'add_to_playlist_sheet.dart';
import 'library_category_picker.dart';
import 'local_track_file_actions.dart';

/// Actions rapides sur un morceau via appui long — utilisé de façon
/// cohérente dans Recherche, Bibliothèque et l'éditeur de playlist plutôt
/// que de dupliquer des menus différents par écran.
class TrackActionsSheet extends ConsumerWidget {
  const TrackActionsSheet({
    super.key,
    required this.track,
    this.currentPlaylistId,
    this.onChanged,
    this.showChangeCategory = false,
  });

  final Track track;

  /// Playlist depuis laquelle ce morceau est affiché — active l'action
  /// "Retirer de cette playlist" quand renseignée (éditeur de playlist).
  final String? currentPlaylistId;

  /// Appelé une fois qu'une action a réellement terminé sa modification en
  /// base — pas au moment où cette feuille se ferme, qui la précède souvent
  /// (ex. "Modifier les métadonnées" ferme la feuille puis ouvre un dialogue
  /// séparé ; attendre uniquement `show()` déclenchait donc une resynchro
  /// prématurée chez l'appelant, avant même la sauvegarde). Optionnel : les
  /// écrans purement réactifs (Recherche, Bibliothèque) n'en ont pas besoin.
  final VoidCallback? onChanged;

  /// Active "Changer de catégorie" (À renommer / À enrichir / Renommé et
  /// enrichi) — réservé à la zone d'importation (Bibliothèque), seul écran
  /// qui affiche et filtre ces catégories.
  final bool showChangeCategory;

  static Future<void> show(
    BuildContext context,
    Track track, {
    String? currentPlaylistId,
    VoidCallback? onChanged,
    bool showChangeCategory = false,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Scrollable : avec "Changer de catégorie", la liste d'actions peut
      // dépasser la hauteur par défaut d'une feuille sur un petit écran.
      isScrollControlled: true,
      // iOS : une feuille à hauteur libre peut monter sous l'encoche/la
      // Dynamic Island — bornée à la zone sûre (Android : inchangé).
      useSafeArea: AppPlatform.isIOS,
      builder: (context) => TrackActionsSheet(
        track: track,
        currentPlaylistId: currentPlaylistId,
        onChanged: onChanged,
        showChangeCategory: showChangeCategory,
      ),
    );
  }

  /// Même précaution que [_editCoverArt] : le repository est lu AVANT de
  /// fermer la feuille, dont le `ref` n'est plus utilisable après le `pop`.
  Future<void> _changeCategory(BuildContext context, WidgetRef ref) async {
    final TrackRepository trackRepository = ref.read(trackRepositoryProvider);
    final NavigatorState navigator = Navigator.of(context);
    navigator.pop();
    final LibraryCategory? applied =
        await changeTrackLibraryCategory(navigator.context, repository: trackRepository, track: track);
    if (applied == null) return;
    onChanged?.call();
  }

  /// Ouvre l'éditeur complet (Titre/Artiste/Album/Année/Genre/Pochette,
  /// recherche API ou saisie manuelle) — remplace l'ancien dialogue minimal
  /// Titre/Artiste : un seul point d'entrée pour renommer ou (ré-)enrichir un
  /// morceau, accessible à tout moment depuis Recherche/Bibliothèque/éditeur
  /// de playlist (partout où `TrackActionsSheet` est utilisé).
  Future<void> _editMetadata(BuildContext context) async {
    Navigator.of(context).pop();
    await showDialog<void>(context: context, builder: (context) => MetadataEditorModal(track: track));
    onChanged?.call();
  }

  /// Même précaution que [_editMetadata] : `pickGalleryImage` est un aller-
  /// retour utilisateur potentiellement long (choix dans la galerie), donc le
  /// `ref` de la feuille déjà démontée ne doit plus servir après cet `await`.
  Future<void> _editCoverArt(BuildContext context, WidgetRef ref) async {
    final storageManager = ref.read(storageManagerServiceProvider);
    final TrackRepository trackRepository = ref.read(trackRepositoryProvider);
    Navigator.of(context).pop();
    final XFile? picked = await pickGalleryImage();
    if (picked == null) return;

    final File imported = await storageManager.importTrackCoverImage(File(picked.path), track.id);
    await trackRepository.updateCoverArtPath(track.id, imported.path);
    onChanged?.call();
  }

  Future<void> _addToPlaylist(BuildContext context) async {
    Navigator.of(context).pop();
    if (context.mounted) await AddToPlaylistSheet.show(context, track.id);
    onChanged?.call();
  }

  Future<void> _removeFromCurrentPlaylist(BuildContext context, WidgetRef ref) async {
    final playlistTrackRepository = ref.read(playlistTrackRepositoryProvider);
    Navigator.of(context).pop();
    final String? playlistId = currentPlaylistId;
    if (playlistId == null) return;
    await playlistTrackRepository.removeTrack(playlistId, track.id);
    onChanged?.call();
  }

  /// Reste ouvert (pas de `pop`) pour laisser basculer lecture/arrêt sans
  /// rouvrir la feuille — voir [toggleLocalTrackPreview].
  Future<void> _togglePreview(WidgetRef ref) => toggleLocalTrackPreview(ref, track);

  /// Voir [confirmAndDeleteLocalTrackFile] — la feuille ne se ferme qu'une
  /// fois le fichier réellement supprimé.
  Future<void> _deleteAudioFile(BuildContext context, WidgetRef ref) async {
    final bool deleted = await confirmAndDeleteLocalTrackFile(context, ref, track);
    if (!deleted) return;
    if (context.mounted) Navigator.of(context).pop();
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? activePreviewPath = ref.watch(previewPlayerControllerProvider);
    final bool isPreviewingThis = activePreviewPath == track.filePath;

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Modifier les métadonnées'),
              onTap: () => _editMetadata(context),
            ),
            if (showChangeCategory)
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Changer de catégorie'),
                subtitle: Text('Actuellement : ${libraryCategoryOf(track).label}'),
                onTap: () => _changeCategory(context, ref),
              ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Éditer la pochette'),
              onTap: () => _editCoverArt(context, ref),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('Ajouter à une playlist'),
              onTap: () => _addToPlaylist(context),
            ),
            if (currentPlaylistId != null)
              ListTile(
                leading: const Icon(Icons.playlist_remove),
                title: const Text('Retirer de cette playlist'),
                onTap: () => _removeFromCurrentPlaylist(context, ref),
              ),
            ListTile(
              leading: Icon(isPreviewingThis ? Icons.stop_circle_outlined : Icons.play_circle_outline),
              title: Text(isPreviewingThis ? 'Arrêter l\'extrait' : 'Écouter un extrait'),
              onTap: () => _togglePreview(ref),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Supprimer le fichier de l\'appareil', style: TextStyle(color: Colors.redAccent)),
              onTap: () => _deleteAudioFile(context, ref),
            ),
          ],
        ),
      ),
    );
  }
}
