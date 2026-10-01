import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/shared/widgets/playlist_card.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/theme/design_system/app_spacing.dart';
import '../../../core/theme/vibe_engine/playlist_vibe_resolver.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../data/playlist_providers.dart';
import '../data/playlist_repository.dart';
import 'export/playlist_export_flow.dart';
import 'import/playlist_json_import_flow.dart';

/// Tab 3 : bibliothèque de playlists locales — accès à l'éditeur, au Vibe
/// Customizer, à "Pour compléter..." (Étape 4), et lecture directe.
class PersonalSpaceScreen extends ConsumerWidget {
  const PersonalSpaceScreen({super.key});

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final TextEditingController controller = TextEditingController();
    final String? title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouvelle playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nom de la playlist'),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Créer'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;

    final Playlist created =
        await ref.read(playlistRepositoryProvider).createEmpty(title: title, vibeStyle: VibePreset.minimal);
    if (context.mounted) context.push('/space/playlist/${created.id}/edit');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Playlist>> playlists = ref.watch(playlistsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Paramètres',
          onPressed: () => context.push('/settings'),
        ),
        title: const Text('Mon espace'),
        actions: [
          PopupMenuButton<_AddAction>(
            icon: const Icon(Icons.add),
            tooltip: 'Nouvelle playlist',
            onSelected: (action) => switch (action) {
              _AddAction.create => _createPlaylist(context, ref),
              _AddAction.importJson => PlaylistJsonImportFlow.pickAndImport(context, ref),
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _AddAction.create,
                child: ListTile(leading: Icon(Icons.playlist_add), title: Text('Nouvelle playlist')),
              ),
              PopupMenuItem(
                value: _AddAction.importJson,
                child: ListTile(leading: Icon(Icons.file_open_outlined), title: Text('Importer une playlist (.json)')),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: 'Bibliothèque',
            onPressed: () => context.push('/space/library'),
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: 'Nettoyage du stockage',
            onPressed: () => context.push('/space/cleanup'),
          ),
        ],
      ),
      body: playlists.when(
        data: (data) {
          if (data.isEmpty) return const Center(child: Text('Aucune playlist pour le moment.'));
          return ListView(
            children: [
              const SizedBox(height: AppSpacing.m),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.m),
                child: Text('Tes playlists', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              ),
              const SizedBox(height: AppSpacing.s),
              SizedBox(
                height: 220,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
                  scrollDirection: Axis.horizontal,
                  itemCount: data.length,
                  separatorBuilder: (context, index) => const SizedBox(width: AppSpacing.m),
                  itemBuilder: (context, index) => PlaylistCard(
                    playlist: data[index],
                    onTap: () => playPlaylistAndNavigate(context, ref, data[index]),
                    onLongPress: () => context.push('/space/playlist/${data[index].id}/edit'),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.l),
              const Divider(height: 1),
              ...data.map((playlist) => _PlaylistTile(playlist: playlist)),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Erreur : $error')),
      ),
    );
  }
}

class _PlaylistTile extends ConsumerWidget {
  const _PlaylistTile({required this.playlist});

  final Playlist playlist;

  /// Playlists système : recréées/gérées automatiquement par l'app (voir
  /// [kAllImportedPlaylistId], [kLikedPlaylistId]), jamais renommables ni
  /// supprimables depuis ce menu.
  bool get _isSystemPlaylist => !PlaylistExportFlow.isExportable(playlist);

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final String? title = await showDialog<String>(
      context: context,
      builder: (context) => _RenamePlaylistDialog(initialTitle: playlist.title),
    );
    if (title == null || title.isEmpty) return;
    await ref.read(playlistRepositoryProvider).renamePlaylist(playlist.id, title);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer la playlist ?'),
        content: Text('"${playlist.title}" sera définitivement supprimée. Les morceaux restent dans ta bibliothèque.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(playlistRepositoryProvider).deletePlaylist(playlist.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VibeVisual vibe = playlist.resolvedVibe;

    final String? attribution = playlist.originalCreator;
    final String subtitle = attribution == null
        ? 'v${playlist.version} · ${playlist.vibeStyle.label}'
        : 'v${playlist.version} · ${playlist.vibeStyle.label} · Inspiré par @$attribution';

    return ListTile(
      leading: CircleAvatar(backgroundColor: vibe.accentColor, radius: 10),
      title: Text(playlist.title),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      // Convention de gestes (voir PlaylistCard) : appui simple = lecture
      // immédiate, appui long = seul accès à l'éditeur. L'ancien bouton
      // "Lire" dédié devenait redondant avec l'appui simple, retiré.
      onTap: () => playPlaylistAndNavigate(context, ref, playlist),
      onLongPress: () => context.push('/space/playlist/${playlist.id}/edit'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            tooltip: 'Vibe',
            onPressed: () => context.push('/space/playlist/${playlist.id}/vibe'),
          ),
          // Sélections système ("Titres likés", "Tous les titres importés") :
          // ni export, ni renommage, ni suppression — menu absent.
          if (!_isSystemPlaylist)
            PopupMenuButton<_PlaylistAction>(
              onSelected: (action) async {
                switch (action) {
                  case _PlaylistAction.export:
                    await PlaylistExportFlow.run(context, ref, playlist);
                  case _PlaylistAction.rename:
                    await _rename(context, ref);
                  case _PlaylistAction.delete:
                    await _delete(context, ref);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: _PlaylistAction.export, child: Text('Exporter en JSON')),
                PopupMenuDivider(),
                PopupMenuItem(value: _PlaylistAction.rename, child: Text('Renommer la playlist')),
                PopupMenuItem(value: _PlaylistAction.delete, child: Text('Supprimer la playlist')),
              ],
            ),
        ],
      ),
    );
  }
}

enum _PlaylistAction { export, rename, delete }

enum _AddAction { create, importJson }

/// Contenu de la boîte "Renommer la playlist", en `StatefulWidget` distinct
/// pour que son `TextEditingController` soit disposé par `State.dispose()`
/// (appelé une fois le dialogue réellement retiré de l'arbre) plutôt que
/// juste après la résolution du `Future` de `showDialog`, pendant que
/// l'`AlertDialog` est encore visible en pleine transition de fermeture —
/// même bug que celui corrigé sur le renommage de morceau, voir
/// `TrackActionsSheet._RenameDialog`.
class _RenamePlaylistDialog extends StatefulWidget {
  const _RenamePlaylistDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenamePlaylistDialog> createState() => _RenamePlaylistDialogState();
}

class _RenamePlaylistDialogState extends State<_RenamePlaylistDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialTitle);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Renommer la playlist'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Nom de la playlist'),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(onPressed: _save, child: const Text('Enregistrer')),
      ],
    );
  }
}
