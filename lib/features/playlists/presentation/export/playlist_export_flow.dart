import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/storage/database/app_database.dart';
import '../../../../core/storage/database/track_repository.dart';
import '../../data/playlist_manifest_service.dart';
import '../../data/playlist_providers.dart';
import '../../data/playlist_repository.dart';

/// Export JSON d'une playlist créée par l'utilisateur :
///  1. fenêtre "Nom de l'auteur de la playlist" (dernier nom saisi proposé) ;
///  2. JSON (titre, auteur, pistes) enregistré à l'emplacement choisi via le
///     sélecteur système — repli sur le dossier de l'app si indisponible.
///
/// Jamais proposé pour les sélections système ([isExportable]).
class PlaylistExportFlow {
  const PlaylistExportFlow._();

  static const String _lastAuthorKey = 'playlist_export.last_author';

  /// "Titres likés" et "Tous les titres importés" sont des sélections gérées
  /// par l'app, pas des playlists de l'utilisateur : pas d'export.
  static bool isExportable(Playlist playlist) =>
      playlist.id != kAllImportedPlaylistId && playlist.id != kLikedPlaylistId;

  static Future<void> run(BuildContext context, WidgetRef ref, Playlist playlist) async {
    if (!isExportable(playlist)) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PlaylistManifestService service = ref.read(playlistManifestServiceProvider);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!context.mounted) return;

    final String? author = await showDialog<String>(
      context: context,
      builder: (context) => _ExportAuthorDialog(
        playlistTitle: playlist.title,
        initialAuthor: prefs.getString(_lastAuthorKey) ?? '',
      ),
    );
    if (author == null) return;
    await prefs.setString(_lastAuthorKey, author);

    final String json = await service.exportManifestJson(playlist.id, author: author);
    final String fileName = PlaylistManifestService.exportFileNameFor(playlist.title);
    final Uint8List bytes = Uint8List.fromList(utf8.encode(json));

    try {
      final Uri? saved = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/json',
        dialogTitle: 'Exporter « ${playlist.title} »',
      );
      if (saved == null) return; // Enregistrement annulé par l'utilisateur.
      messenger.showSnackBar(SnackBar(content: Text('« ${playlist.title} » exportée (auteur : $author).')));
    } catch (_) {
      final Directory documents = await getApplicationDocumentsDirectory();
      final File file = File(p.join(documents.path, 'exports', fileName));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      // iOS : le dossier Documents est exposé dans l'app Fichiers
      // (`UIFileSharingEnabled`) — l'emplacement lisible par l'utilisateur
      // plutôt que le chemin absolu du conteneur de l'app.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppPlatform.isIOS
                ? 'Exportée dans Fichiers › Sur mon iPhone › Vibe › exports › $fileName'
                : 'Exportée : ${file.path}',
          ),
        ),
      );
    }
  }
}

class _ExportAuthorDialog extends StatefulWidget {
  const _ExportAuthorDialog({required this.playlistTitle, required this.initialAuthor});

  final String playlistTitle;
  final String initialAuthor;

  @override
  State<_ExportAuthorDialog> createState() => _ExportAuthorDialogState();
}

class _ExportAuthorDialogState extends State<_ExportAuthorDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialAuthor);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canExport => _controller.text.trim().isNotEmpty;

  void _submit() {
    if (_canExport) Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Exporter la playlist'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('« ${widget.playlistTitle} » sera exportée en JSON avec son titre, sa liste de pistes et son auteur.'),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Nom de l\'auteur de la playlist'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(onPressed: _canExport ? _submit : null, child: const Text('Exporter')),
      ],
    );
  }
}
