import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/networking/spotify/spotify_credentials.dart';
import '../../../core/playlist_manifest/playlist_manifest.dart';
import '../../playlists/presentation/import/playlist_json_import_flow.dart';
import '../data/import_providers.dart';

/// Section "Import" de Tab 1 (Étape 6) : liens Spotify et manifestes JSON
/// partagés convergent vers le même pipeline fork / diff / morceaux manquants.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _clientIdController = TextEditingController();
  final TextEditingController _clientSecretController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _urlController.dispose();
    _clientIdController.dispose();
    _clientSecretController.dispose();
    super.dispose();
  }

  Future<void> _saveCredentials() async {
    if (_clientIdController.text.trim().isEmpty || _clientSecretController.text.trim().isEmpty) return;
    await ref.read(spotifyCredentialsStorageProvider).save(
          SpotifyCredentials(
              clientId: _clientIdController.text.trim(), clientSecret: _clientSecretController.text.trim()),
        );
    ref.invalidate(spotifyCredentialsProvider);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Identifiants enregistrés')));
  }

  /// Toujours en mode `oEmbed` (sans identifiants API) : la récupération de
  /// la liste complète des morceaux via l'API Web Spotify est réservée au
  /// flow Client Credentials, que Spotify restreint depuis fin 2024 (403
  /// systématique) — nécessiterait une vraie connexion utilisateur (Étape
  /// à venir). La section identifiants ci-dessous reste visible mais
  /// désactivée en attendant cette fonctionnalité.
  Future<void> _importFromSpotify() async {
    final String url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() => _busy = true);
    try {
      final PlaylistManifest manifest = await ref.read(discoveryRepositoryProvider).importFromSpotifyLink(url);
      if (!mounted) return;
      await PlaylistJsonImportFlow.importManifest(context, ref, manifest);
    } on DioException catch (error) {
      if (error.response?.statusCode == 403) {
        _showError(
          'La récupération automatique de la liste des pistes nécessite une connexion '
          'utilisateur (fonctionnalité à venir). Seul le titre de la playlist est importé.',
        );
      } else {
        _showError('Import Spotify impossible : ${error.message}');
      }
    } catch (error) {
      _showError('Import Spotify impossible : $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Parcours partagé avec Mon espace (voir PlaylistJsonImportFlow) : matching
  /// automatique puis manuel, titres introuvables grisés, playlist ajoutée à
  /// "Tes playlists".
  Future<void> _importFromJsonFile() async {
    setState(() => _busy = true);
    try {
      await PlaylistJsonImportFlow.pickAndImport(context, ref);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Lien de playlist Spotify', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                hintText: 'https://open.spotify.com/playlist/...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link),
              label: const Text('Importer depuis Spotify'),
              onPressed: _busy ? null : _importFromSpotify,
            ),
            const SizedBox(height: 24),
            ExpansionTile(
              title: const Text('Identifiants API Spotify'),
              subtitle: const Text(
                'Synchronisation complète des pistes — nécessite une connexion utilisateur Spotify '
                '(fonctionnalité à venir). Seul le titre de la playlist est importé pour l\'instant.',
              ),
              children: [
                Tooltip(
                  message: 'Connexion utilisateur Spotify requise — pas encore disponible dans cette version.',
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: 0.5,
                      child: Column(
                        children: [
                          TextField(
                            controller: _clientIdController,
                            decoration: const InputDecoration(labelText: 'Client ID'),
                          ),
                          TextField(
                            controller: _clientSecretController,
                            decoration: const InputDecoration(labelText: 'Client Secret'),
                            obscureText: true,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(onPressed: _saveCredentials, child: const Text('Enregistrer')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 32),
            Text('Manifeste JSON partagé', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Importer un fichier .json'),
              onPressed: _busy ? null : _importFromJsonFile,
            ),
          ],
        ),
      ),
    );
  }
}
