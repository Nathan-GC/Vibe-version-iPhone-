import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio_engine/player_controller.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/blacklist_repository.dart';
import '../../../core/storage/scanner/library_scan_service.dart';
import '../../../core/storage/scanner/scanned_track.dart';
import '../../../core/storage/storage_manager/picked_file_cache.dart';
import '../../library/data/library_providers.dart';

/// Filtre d'affichage de l'onglet "Titres" de la page Import.
enum ImportedTracksFilter { all, recent, blacklist }

/// Onglet "Titres" de la page Import — seul accès à la liste noire (voir
/// [BlacklistRepository]) : titres importés (tous, ou nouveaux) à masquer
/// par sélection, fichiers de l'appareil à masquer avant tout import, et
/// titres masqués à restaurer.
class ImportedTracksTab extends ConsumerStatefulWidget {
  const ImportedTracksTab({super.key, this.pickAudioFiles = _pickAudioFiles});

  /// Chemins des fichiers audio choisis pour « Masquer un fichier... »
  /// (vide si annulé) — injectable pour les tests.
  final Future<List<String>> Function() pickAudioFiles;

  static Future<List<String>> _pickAudioFiles() async => [
        for (final PlatformFile file in await FilePicker.pickFiles(type: FileType.audio))
          if (file.path != null) file.path!,
      ];

  /// "Nouveaux" : importés depuis moins de 7 jours.
  static const Duration recentWindow = Duration(days: 7);

  @override
  ConsumerState<ImportedTracksTab> createState() => _ImportedTracksTabState();
}

class _ImportedTracksTabState extends ConsumerState<ImportedTracksTab> {
  ImportedTracksFilter _filter = ImportedTracksFilter.all;
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final int blacklisted = ref.watch(blacklistedTracksProvider).value?.length ?? 0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<ImportedTracksFilter>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: ImportedTracksFilter.all, label: Text('Tous')),
              const ButtonSegment(value: ImportedTracksFilter.recent, label: Text('Nouveaux')),
              ButtonSegment(value: ImportedTracksFilter.blacklist, label: Text('Liste noire ($blacklisted)')),
            ],
            selected: {_filter},
            onSelectionChanged: (selection) => setState(() {
              _filter = selection.first;
              _selected.clear();
            }),
          ),
        ),
        Expanded(child: _filter == ImportedTracksFilter.blacklist ? _blacklistView() : _tracksView()),
      ],
    );
  }

  Widget _tracksView() {
    return ref.watch(libraryTracksProvider).when(
          data: (all) {
            final DateTime since = DateTime.now().subtract(ImportedTracksTab.recentWindow);
            final List<Track> tracks =
                _filter == ImportedTracksFilter.recent ? all.where((t) => t.createdAt.isAfter(since)).toList() : all;
            if (tracks.isEmpty) {
              return Center(
                child: Text(_filter == ImportedTracksFilter.recent
                    ? 'Aucun titre importé ces 7 derniers jours.'
                    : 'Aucun titre importé.'),
              );
            }
            return Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final Track track = tracks[index];
                      return CheckboxListTile(
                        value: _selected.contains(track.id),
                        onChanged: _busy
                            ? null
                            : (checked) => setState(
                                  () => checked == true ? _selected.add(track.id) : _selected.remove(track.id),
                                ),
                        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(track.artists.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis),
                      );
                    },
                  ),
                ),
                if (_selected.isNotEmpty)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                                '${_selected.length} titre${_selected.length > 1 ? 's' : ''} sélectionné${_selected.length > 1 ? 's' : ''}'),
                          ),
                          FilledButton.icon(
                            icon: const Icon(Icons.visibility_off_outlined),
                            label: const Text('Masquer'),
                            onPressed: _busy ? null : () => _hide(all.where((t) => _selected.contains(t.id)).toList()),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('Erreur : $error')),
        );
  }

  Widget _blacklistView() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.visibility_off_outlined),
              label: const Text('Masquer un fichier...',
                  semanticsLabel: "Masquer un fichier de l'appareil, sans l'importer"),
              onPressed: _busy ? null : _hideDeviceFiles,
            ),
          ),
        ),
        Expanded(child: _blacklistEntries()),
      ],
    );
  }

  Widget _blacklistEntries() {
    return ref.watch(blacklistedTracksProvider).when(
          data: (entries) {
            if (entries.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'Liste noire vide. Les titres masqués ici, ou dont le système refuse la suppression du '
                    'fichier, y apparaissent et peuvent être restaurés.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            return ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final BlacklistedTrack entry = entries[index];
                final bool protectedFile = entry.reason == BlacklistReason.deletionFailed;
                return ListTile(
                  isThreeLine: true,
                  leading: Icon(
                    protectedFile ? Icons.lock_outline : Icons.visibility_off_outlined,
                    semanticLabel: protectedFile ? 'Fichier protégé par le système' : 'Masqué manuellement',
                  ),
                  title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${entry.artists.join(', ')}\n${entry.filePath}',
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: TextButton.icon(
                    icon: const Icon(Icons.restore),
                    label: Text('Restaurer', semanticsLabel: 'Restaurer ${entry.title}'),
                    onPressed: _busy ? null : () => _restore(entry),
                  ),
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('Erreur : $error')),
        );
  }

  /// Masquage manuel : retirés de Vibe (bibliothèque, recherche, playlists,
  /// file de lecture), jamais réimportés, fichiers laissés intacts.
  Future<void> _hide(List<Track> tracks) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PlayerController player = ref.read(playerControllerProvider.notifier);
    final BlacklistRepository blacklist = ref.read(blacklistRepositoryProvider);
    final int count = tracks.length;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Masquer $count titre${count > 1 ? 's' : ''} ?'),
        content: const Text(
          'Ils sont retirés de Vibe (bibliothèque, recherche, playlists, file de lecture) et ne seront plus '
          'réimportés. Les fichiers restent sur l\'appareil ; restauration possible depuis « Liste noire ».',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Masquer')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    await blacklist.blacklist(tracks, reason: BlacklistReason.manual);
    await player.removeTracks({for (final Track track in tracks) track.id});
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
    });
    messenger.showSnackBar(
      SnackBar(content: Text('$count titre${count > 1 ? 's' : ''} ajouté${count > 1 ? 's' : ''} à la liste noire.')),
    );
  }

  /// Masque des fichiers de l'appareil, importés ou non : jamais indexés
  /// ensuite (scan de l'appareil, import manuel), retirés de Vibe s'ils y
  /// étaient déjà. Les fichiers restent intacts.
  Future<void> _hideDeviceFiles() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final PlayerController player = ref.read(playerControllerProvider.notifier);
    final LibraryScanService scanner = ref.read(libraryScanServiceProvider);
    final BlacklistRepository blacklist = ref.read(blacklistRepositoryProvider);
    final List<String> paths = await widget.pickAudioFiles();
    if (paths.isEmpty || !mounted) return;

    setState(() => _busy = true);
    final List<ScannedTrack> files = [];
    try {
      for (final String path in paths) {
        try {
          final ScannedTrack? file = await scanner.identify(File(path));
          if (file != null) files.add(file);
        } catch (_) {
          // Illisible : le scan l'écarterait de toute façon, rien à masquer.
        }
      }
      final List<Track> removed = await blacklist.hideFiles(files);
      await player.removeTracks({for (final Track track in removed) track.id});
    } finally {
      // Copies du sélecteur (cache Android) : seule l'identité est retenue.
      await clearPickedFileCache();
      if (mounted) setState(() => _busy = false);
    }
    final int count = files.length;
    messenger.showSnackBar(SnackBar(
      content: Text(count == 0
          ? 'Aucun fichier audio exploitable à masquer.'
          : '$count fichier${count > 1 ? 's' : ''} ajouté${count > 1 ? 's' : ''} à la liste noire.'),
    ));
  }

  Future<void> _restore(BlacklistedTrack entry) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final RestoreOutcome outcome = await ref.read(blacklistRepositoryProvider).restore(entry);
    if (mounted) setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
      content: Text(switch (outcome) {
        RestoreOutcome.restored => '« ${entry.title} » est de retour dans la bibliothèque.',
        RestoreOutcome.fileMissing => 'Fichier introuvable : « ${entry.title} » est retiré de la liste noire.',
        RestoreOutcome.unhidden => '« ${entry.title} » n\'est plus masqué : il pourra de nouveau être importé.',
        RestoreOutcome.alreadyInLibrary =>
          'Un titre identique est déjà dans la bibliothèque : « ${entry.title} » reste masqué.',
      }),
    ));
  }
}
