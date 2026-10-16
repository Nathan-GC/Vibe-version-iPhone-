import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../audio_engine/player_controller.dart';
import '../../audio_engine/preview_player_controller.dart';
import '../../purge/orphan_purge_service.dart';
import '../../purge/purge_providers.dart';
import '../../storage/database/app_database.dart';

/// Actions sur le FICHIER audio local d'un morceau, partagées entre
/// TrackActionsSheet (appui long) et l'écran des doublons — une seule
/// implémentation de l'écoute et de la suppression physique.

/// Section 6.1 — extrait audio du fichier LOCAL (contrairement aux 20-30s
/// en ligne de [OnlineTrackCard]) : bascule lecture/arrêt, et démarre après
/// le silence de tête déjà détecté (`trimStartMs`, voir
/// SilenceTrimmerService) plutôt qu'au tout début du fichier.
Future<void> toggleLocalTrackPreview(WidgetRef ref, Track track) {
  return ref
      .read(previewPlayerControllerProvider.notifier)
      .togglePreview(track.filePath, startAt: Duration(milliseconds: track.trimStartMs));
}

/// Message affiché quand le système refuse la suppression d'un fichier.
const String kProtectedFileBlacklistedMessage =
    'Fichier physique protégé par le système : le titre a été retiré et ajouté à la liste noire de Vibe.';

enum TrackFileDeletion {
  cancelled,

  /// Fichier effacé de l'appareil, morceau retiré de Vibe.
  deleted,

  /// Suppression refusée par le système : morceau retiré de Vibe et mis en
  /// liste noire (restaurable depuis la page Import).
  blacklisted,
}

/// Suppression **définitive** du fichier audio de l'appareil (Section 6.1)
/// — mêmes garanties que la vue de nettoyage des orphelins
/// ([OrphanPurgeService] : fichier physique + lignes en base). Irréversible,
/// donc confirmé avant d'agir, comme la suppression de playlist
/// (PersonalSpaceScreen._delete).
///
/// Fichier protégé par le système : le morceau quitte Vibe quand même (liste
/// noire, voir [OrphanPurgeService]) et un message discret l'explique. Dans
/// les deux cas, il est aussi retiré de la file de lecture.
Future<TrackFileDeletion> confirmAndDeleteLocalTrackFile(BuildContext context, WidgetRef ref, Track track) async {
  // Lus avant le premier `await` : l'appelant (ligne de liste réactive) peut
  // être démonté dès que la ligne disparaît de la base.
  final OrphanPurgeService purgeService = ref.read(orphanPurgeServiceProvider);
  final PlayerController player = ref.read(playerControllerProvider.notifier);
  final PreviewPlayerController preview = ref.read(previewPlayerControllerProvider.notifier);
  final bool isPreviewingThis = ref.read(previewPlayerControllerProvider) == track.filePath;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Supprimer ce fichier ?'),
      content: Text('"${track.title}" sera définitivement supprimé de l\'appareil. Cette action est irréversible.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Supprimer')),
      ],
    ),
  );
  if (confirmed != true) return TrackFileDeletion.cancelled;

  // Un extrait de ce morceau en cours de lecture tiendrait sinon un handle
  // ouvert sur le fichier qu'on s'apprête à effacer.
  if (isPreviewingThis) await preview.stop();

  // Un morceau indexé par le scan plein-appareil (jamais copié dans le
  // dossier privé de l'app, contrairement à un import manuel) peut être
  // protégé par le stockage cloisonné d'Android : l'app peut le lire mais
  // pas le supprimer — vérifié empiriquement (le fichier reste intact).
  final PurgeResult result = await purgeService.deleteTracks([track]);
  await player.removeTracks(result.removedIds);
  if (result.blacklisted.isEmpty) return TrackFileDeletion.deleted;
  messenger.showSnackBar(const SnackBar(content: Text(kProtectedFileBlacklistedMessage)));
  return TrackFileDeletion.blacklisted;
}
