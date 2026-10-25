import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/shared/widgets/playlist_card.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/theme/design_system/app_spacing.dart';
import '../../../core/theme/vibe_engine/playlist_vibe_resolver.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../data/playlist_providers.dart';
import '../data/playlist_repository.dart';
import '../domain/playlist_category.dart';
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
              for (final PlaylistCategory category in PlaylistCategory.values) _PlaylistCarousel(category: category),
              const Divider(height: 1),
              for (final PlaylistCategory category in PlaylistCategory.values) _PlaylistSection(category: category),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Erreur : $error')),
      ),
    );
  }
}

/// Titre affiché au-dessus du carrousel d'une famille.
String _carouselTitle(PlaylistCategory category) => switch (category) {
      PlaylistCategory.created => 'Playlists créées',
      PlaylistCategory.auto => 'Playlists auto',
      PlaylistCategory.imported => 'Playlists importées',
    };

/// Titre de la section repliable d'une famille.
String _sectionTitle(PlaylistCategory category) => switch (category) {
      PlaylistCategory.created => 'Playlists créées',
      PlaylistCategory.auto => 'Playlists automatiques',
      PlaylistCategory.imported => 'Playlists importées',
    };

/// Carrousel d'une famille de playlists, réordonnable
/// par appui long puis glisser-déposer — poignée par défaut de
/// ReorderableListView sur mobile : la carte n'a donc aucun onLongPress, qui
/// gagnerait l'arène de gestes.
class _PlaylistCarousel extends ConsumerStatefulWidget {
  const _PlaylistCarousel({required this.category});

  final PlaylistCategory category;

  @override
  ConsumerState<_PlaylistCarousel> createState() => _PlaylistCarouselState();
}

class _PlaylistCarouselState extends ConsumerState<_PlaylistCarousel> {
  /// Ordre déposé, affiché tout de suite : sans lui, la carte revenait à son
  /// ancienne place le temps que le flux Drift réémette après l'écriture.
  List<String>? _droppedIds;

  List<Playlist> _visible(List<Playlist> fromDb) {
    final List<String>? dropped = _droppedIds;
    if (dropped == null) return fromDb;
    final Map<String, Playlist> byId = {for (final Playlist playlist in fromDb) playlist.id: playlist};
    // Base rattrapée, ou playlist ajoutée / supprimée entre-temps : la base fait foi.
    if (dropped.length != fromDb.length ||
        !dropped.every(byId.containsKey) ||
        listEquals(dropped, byId.keys.toList())) {
      _droppedIds = null;
      return fromDb;
    }
    return [for (final String id in dropped) byId[id]!];
  }

  @override
  Widget build(BuildContext context) {
    final List<Playlist> carousel = _visible(ref.watch(carouselByCategoryProvider(widget.category)).value ?? const []);
    // Famille vide : ni titre ni carrousel (l'invitation à créer est dans la section du dessous).
    if (carousel.isEmpty) return const SizedBox.shrink();
    final Widget list = ReorderableListView.builder(
      padding: const EdgeInsets.only(left: AppSpacing.m),
      scrollDirection: Axis.horizontal,
      itemCount: carousel.length,
      onReorderItem: (oldIndex, newIndex) {
        final List<String> ids = carousel.map((p) => p.id).toList();
        ids.insert(newIndex, ids.removeAt(oldIndex));
        setState(() => _droppedIds = ids);
        ref.read(playlistRepositoryProvider).reorderCarousel(ids);
      },
      itemBuilder: (context, index) => Padding(
        key: ValueKey(carousel[index].id),
        padding: const EdgeInsets.only(right: AppSpacing.m),
        child: PlaylistCard(
          playlist: carousel[index],
          onTap: () => playPlaylistAndNavigate(context, ref, carousel[index]),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
          child: Semantics(
            header: true,
            child: Text(_carouselTitle(widget.category),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ),
        const SizedBox(height: AppSpacing.s),
        SizedBox(height: 220, child: list),
        const SizedBox(height: AppSpacing.m),
      ],
    );
  }
}

/// Section repliable listant les playlists d'une famille. L'état replié est
/// mémorisé dans SharedPreferences (une clé par famille), déplié par défaut.
class _PlaylistSection extends ConsumerStatefulWidget {
  const _PlaylistSection({required this.category});

  final PlaylistCategory category;

  @override
  ConsumerState<_PlaylistSection> createState() => _PlaylistSectionState();
}

class _PlaylistSectionState extends ConsumerState<_PlaylistSection> {
  /// `null` tant que l'état mémorisé n'est pas relu : la liste n'est alors
  /// pas affichée, plutôt que de s'ouvrir un instant puis se replier à
  /// chaque démarrage pour une section laissée repliée.
  bool? _collapsed;

  String get _prefsKey => 'personal_space_collapsed_${widget.category.name}';

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool collapsed = prefs.getBool(_prefsKey) ?? false;
    if (mounted) setState(() => _collapsed = collapsed);
  }

  Future<void> _toggle() async {
    final bool collapsed = !(_collapsed ?? false);
    setState(() => _collapsed = collapsed);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final List<Playlist> playlists = ref.watch(playlistsByCategoryProvider(widget.category)).value ?? const [];
    // Section vide masquée, sauf "créées" (toujours là, avec son invitation).
    if (playlists.isEmpty && widget.category != PlaylistCategory.created) return const SizedBox.shrink();

    final String title = _sectionTitle(widget.category);
    final bool? collapsed = _collapsed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: AppSpacing.m, right: AppSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ),
              ),
              IconButton(
                icon: Icon(collapsed ?? false ? Icons.expand_more : Icons.expand_less),
                tooltip: collapsed ?? false ? 'Déplier la section $title' : 'Replier la section $title',
                onPressed: collapsed == null ? null : _toggle,
              ),
            ],
          ),
        ),
        if (collapsed == false) ...[
          if (playlists.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.m, 0, AppSpacing.m, AppSpacing.m),
              child: Text('Aucune playlist créée. Touche le bouton "+" pour en créer une.'),
            )
          else
            ...playlists.map((playlist) => _PlaylistTile(playlist: playlist)),
        ],
      ],
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
