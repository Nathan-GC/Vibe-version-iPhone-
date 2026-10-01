import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio_engine/preview_player_controller.dart';
import '../../../core/shared/widgets/local_track_file_actions.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/duplicate_track_group.dart';
import '../data/library_providers.dart';
import 'metadata_editor_modal.dart';

/// Alerte "doublons stricts" (même Titre + même Artiste) — pour chaque
/// exemplaire : écoute du fichier, suppression physique de l'appareil, ou
/// éditeur de métadonnées pour le renommer/ré-enrichir, plutôt que de
/// laisser deux fiches concurrentes dans la bibliothèque.
class DuplicateTracksScreen extends ConsumerWidget {
  const DuplicateTracksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DuplicateTrackGroup>> groups = ref.watch(duplicateTrackGroupsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Doublons détectés')),
      body: groups.when(
        data: (data) {
          if (data.isEmpty) return const Center(child: Text('Aucun doublon — chaque morceau est unique.'));
          return ListView.builder(
            itemCount: data.length,
            itemBuilder: (context, index) => _DuplicateGroupCard(group: data[index]),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Erreur : $error')),
      ),
    );
  }
}

class _DuplicateGroupCard extends StatelessWidget {
  const _DuplicateGroupCard({required this.group});

  final DuplicateTrackGroup group;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_outlined, color: Colors.amber, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${group.title} — ${group.artist}',
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${group.tracks.length} exemplaires identiques — écoute-les, supprime le moins bon ou renomme-le.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 20),
            for (final track in group.tracks) _DuplicateTrackRow(track: track),
          ],
        ),
      ),
    );
  }
}

/// Un exemplaire du doublon : écoute de CE fichier précis (pour comparer
/// qualité/version avant de choisir lequel garder), suppression physique de
/// l'appareil, ou correction des métadonnées.
class _DuplicateTrackRow extends ConsumerWidget {
  const _DuplicateTrackRow({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isPreviewingThis = ref.watch(previewPlayerControllerProvider) == track.filePath;
    final int minutes = track.durationSeconds ~/ 60;
    final String seconds = (track.durationSeconds % 60).toString().padLeft(2, '0');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(isPreviewingThis ? Icons.graphic_eq : Icons.music_note_outlined),
          title: Text(
            '${track.album.isEmpty ? '(album inconnu)' : track.album} · $minutes:$seconds',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(track.filePath, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              icon: Icon(isPreviewingThis ? Icons.stop_circle_outlined : Icons.play_circle_outline, size: 18),
              label: Text(isPreviewingThis ? 'Arrêter l\'écoute' : 'Écouter le titre téléchargé'),
              onPressed: () => toggleLocalTrackPreview(ref, track),
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Supprimer de l\'appareil'),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: () => _delete(context, ref),
            ),
            TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Modifier'),
              onPressed: () =>
                  showDialog<void>(context: context, builder: (context) => MetadataEditorModal(track: track)),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool deleted = await confirmAndDeleteLocalTrackFile(context, ref, track);
    // Le groupe se met à jour tout seul (flux Drift de
    // duplicateTrackGroupsProvider) : la ligne, voire la carte entière si un
    // seul exemplaire reste, disparaît d'elle-même.
    if (deleted) messenger.showSnackBar(SnackBar(content: Text('« ${track.title} » supprimé de l\'appareil.')));
  }
}
