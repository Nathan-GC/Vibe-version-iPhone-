import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/playlist_manifest/playlist_manifest.dart';
import '../../../../core/storage/database/app_database.dart';
import '../../../diff/domain/diff_result.dart';
import '../../../diff/presentation/diff_modal.dart';
import '../../data/playlist_manifest_service.dart';
import '../../data/playlist_providers.dart';
import '../../data/playlist_repository.dart';
import '../../domain/import_match_plan.dart';
import 'import_matching_screen.dart';

/// Parcours complet d'import d'une playlist JSON, partagé par l'écran Import
/// (Découverte) et le bouton "+" de Mon espace :
///  1. lecture/validation du fichier ;
///  2. nouvelle playlist, ou mise à jour d'une playlist déjà importée depuis
///     ce même manifeste (aperçu des différences puis confirmation) ;
///  3. matching automatique, puis fenêtre de matching manuel si besoin ;
///  4. enregistrement : la playlist apparaît dans "Tes playlists"
///     (Découverte ET Mon espace), titres non associés grisés.
class PlaylistJsonImportFlow {
  const PlaylistJsonImportFlow._();

  /// Sélection d'un fichier `.json` sur l'appareil puis [importManifest].
  static Future<void> pickAndImport(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PlatformFile? picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
    final String? path = picked?.path;
    if (path == null) return;

    final PlaylistManifest manifest;
    try {
      final Object? decoded = jsonDecode(await File(path).readAsString());
      if (decoded is! Map<String, dynamic>) throw const FormatException('Objet JSON attendu');
      manifest = PlaylistManifest.fromJson(decoded);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Fichier JSON invalide : $error')));
      return;
    }
    if (!context.mounted) return;
    await importManifest(context, ref, manifest);
  }

  static Future<void> importManifest(BuildContext context, WidgetRef ref, PlaylistManifest manifest) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final GoRouter router = GoRouter.of(context);
    final PlaylistRepository playlists = ref.read(playlistRepositoryProvider);
    final PlaylistManifestService service = ref.read(playlistManifestServiceProvider);

    final Playlist? existing = await playlists.findBySourceManifestId(manifest.id);
    if (existing != null) {
      if (!context.mounted) return;
      await _updateExisting(context, messenger, service, existing, manifest);
      return;
    }

    if (!context.mounted) return;
    final List<String?>? resolution = await _resolve(context, service, manifest);
    if (resolution == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Import annulé.')));
      return;
    }

    final Playlist created = await service.importAsNewPlaylist(manifest, resolution);
    final int missing = resolution.where((id) => id == null).length;
    final int linked = resolution.length - missing;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '« ${created.title} » ajoutée à Tes playlists — $linked titre${linked > 1 ? 's' : ''}'
          '${missing > 0 ? ', $missing grisé${missing > 1 ? 's' : ''}' : ''}.',
        ),
        action: SnackBarAction(label: 'Ouvrir', onPressed: () => router.push('/space/playlist/${created.id}/edit')),
        // Un SnackBar à action reste affiché indéfiniment par défaut
        // (`persist`) : observé en test, il recouvrait encore la légende du
        // mode Focus plusieurs minutes après l'import.
        persist: false,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  static Future<void> _updateExisting(
    BuildContext context,
    ScaffoldMessengerState messenger,
    PlaylistManifestService service,
    Playlist existing,
    PlaylistManifest manifest,
  ) async {
    if (existing.version == manifest.version) {
      messenger.showSnackBar(SnackBar(content: Text('« ${existing.title} » est déjà à jour.')));
      return;
    }

    final DiffResult diff = await service.computeDiff(existing.id, manifest);
    if (!context.mounted) return;
    bool accepted = false;
    await showDialog<void>(
      context: context,
      builder: (context) => DiffModal(diff: diff, onAccept: () => accepted = true),
    );
    if (!accepted || !context.mounted) return;

    final List<String?>? resolution = await _resolve(context, service, manifest);
    if (resolution == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Mise à jour annulée.')));
      return;
    }
    final Playlist updated = await service.applyUpdate(existing.id, manifest, resolution);
    messenger.showSnackBar(SnackBar(content: Text('« ${updated.title} » mise à jour (v${updated.version}).')));
  }

  /// Matching automatique ; fenêtre de matching manuel seulement s'il reste
  /// des titres ambigus ou introuvables. `null` : import abandonné.
  static Future<List<String?>?> _resolve(
    BuildContext context,
    PlaylistManifestService service,
    PlaylistManifest manifest,
  ) async {
    final ImportMatchPlan plan = await service.planImport(manifest.tracks);
    if (!plan.requiresManualReview) return plan.autoResolution;
    if (!context.mounted) return null;
    return ImportMatchingScreen.show(context, playlistTitle: manifest.title, plan: plan);
  }
}
