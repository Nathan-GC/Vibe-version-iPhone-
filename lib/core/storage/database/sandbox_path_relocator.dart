import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'app_database.dart';

/// iOS uniquement : l'app vit dans un conteneur
/// `…/Containers/Data/Application/<UUID>/` dont l'UUID CHANGE à chaque mise à
/// jour ou réinstallation (App Store, TestFlight, `flutter run`/Xcode) — les
/// fichiers sont déplacés tels quels dans le nouveau conteneur, mais tous les
/// chemins absolus mémorisés en base (morceaux importés ou indexés, pochettes,
/// fonds de Vibe image/vidéo) pointent encore vers l'ANCIEN : bibliothèque
/// entière « introuvable » après chaque mise à jour.
///
/// Réécrit ces préfixes de conteneur au démarrage, avant toute lecture de la
/// base (le lecteur restaure la dernière session dès `AudioService.init`,
/// voir main.dart). Idempotent : sans effet quand tout pointe déjà vers le
/// conteneur courant (cas de tous les lancements hors mise à jour). Jamais
/// appelé sur Android, dont les chemins sont stables.
class SandboxPathRelocator {
  SandboxPathRelocator(this._db);

  final AppDatabase _db;

  // Racine de conteneur d'app iOS — appareil (`/var/mobile/…`, parfois vu
  // via son alias `/private/var/mobile/…`) comme simulateur
  // (`…/CoreSimulator/Devices/<UUID>/data/Containers/…`).
  static final RegExp _containerRoot = RegExp(
    r'^(.*?/Containers/Data/Application/'
    r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})(?=/|$)',
  );

  /// Racine de conteneur contenue dans [path], `null` si [path] n'est pas un
  /// chemin de conteneur d'app (vide, URL de pochette distante...).
  @visibleForTesting
  static String? containerRootOf(String path) => _containerRoot.firstMatch(path)?.group(1);

  /// [path] réécrit sous [currentRoot], ou `null` s'il n'a pas à changer
  /// (hors conteneur, ou déjà dans le conteneur courant).
  @visibleForTesting
  static String? relocate(String path, String currentRoot) {
    final String? oldRoot = containerRootOf(path);
    if (oldRoot == null || oldRoot == currentRoot) return null;
    return currentRoot + path.substring(oldRoot.length);
  }

  /// Conteneur courant lu via `path_provider`, puis [relocateTo].
  Future<int> relocateToCurrentContainer() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    final String? currentRoot = containerRootOf(documents.path);
    if (currentRoot == null) return 0;
    return relocateTo(currentRoot);
  }

  /// Réécrit tous les chemins de la base sous [currentRoot] ; renvoie le
  /// nombre de lignes modifiées.
  Future<int> relocateTo(String currentRoot) async {
    int updated = 0;
    await _db.transaction(() async {
      for (final Track track in await _db.select(_db.tracks).get()) {
        final String? filePath = relocate(track.filePath, currentRoot);
        final String? coverArtPath = relocate(track.coverArtPath, currentRoot);
        if (filePath == null && coverArtPath == null) continue;
        try {
          await (_db.update(_db.tracks)..where((t) => t.id.equals(track.id))).write(
            TracksCompanion(
              filePath: filePath == null ? const Value.absent() : Value(filePath),
              coverArtPath: coverArtPath == null ? const Value.absent() : Value(coverArtPath),
            ),
          );
          updated++;
        } on Exception {
          // `file_path` est unique : une ligne pointant déjà vers ce chemin
          // dans le conteneur courant garde la priorité — seule cette mise à
          // jour est annulée, le reste du réalignement continue.
        }
      }

      for (final Playlist playlist in await _db.select(_db.playlists).get()) {
        final String? cover = relocate(playlist.coverImagePath, currentRoot);
        final String? image = relocate(playlist.customBackgroundImagePath, currentRoot);
        final String? video = relocate(playlist.customBackgroundVideoPath, currentRoot);
        if (cover == null && image == null && video == null) continue;
        await (_db.update(_db.playlists)..where((t) => t.id.equals(playlist.id))).write(
          PlaylistsCompanion(
            coverImagePath: cover == null ? const Value.absent() : Value(cover),
            customBackgroundImagePath: image == null ? const Value.absent() : Value(image),
            customBackgroundVideoPath: video == null ? const Value.absent() : Value(video),
          ),
        );
        updated++;
      }
    });
    return updated;
  }
}
