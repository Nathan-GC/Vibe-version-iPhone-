import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/purge/orphan_track.dart';
import '../../../core/purge/purge_providers.dart';
import '../../../core/storage/database/app_database.dart';
import 'orphan_cleanup_providers.dart';

/// Assistant de purge mensuelle (Étape 7.2) : morceaux orphelins (0 playlist),
/// sélection multiple, taille sur disque, dernière écoute, suppression
/// définitive (fichier + ligne `tracks`).
class OrphanCleanupScreen extends ConsumerWidget {
  const OrphanCleanupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<OrphanTrack>> orphans = ref.watch(orphanTracksProvider);
    final Set<String> selected = ref.watch(selectedOrphanIdsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nettoyage du stockage'),
        actions: [
          orphans.maybeWhen(
            data: (data) {
              if (data.isEmpty) return const SizedBox.shrink();
              final bool allSelected = selected.length == data.length;
              return TextButton(
                onPressed: () {
                  ref
                      .read(selectedOrphanIdsProvider.notifier)
                      .set(allSelected ? {} : data.map((o) => o.track.id).toSet());
                },
                child: Text(allSelected ? 'Tout désélectionner' : 'Tout sélectionner'),
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: orphans.when(
        data: (data) {
          if (data.isEmpty) {
            return const Center(child: Text('Aucun fichier orphelin — tout est utilisé dans une playlist.'));
          }
          return ListView.builder(
            itemCount: data.length,
            itemBuilder: (context, index) => _OrphanTile(orphan: data[index]),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Erreur : $error')),
      ),
      bottomNavigationBar: selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  icon: const Icon(Icons.delete_outline),
                  label: Text('Supprimer ${selected.length} morceau(x)'),
                  onPressed: () => _confirmAndDelete(context, ref, orphans.value ?? const [], selected),
                ),
              ),
            ),
    );
  }

  Future<void> _confirmAndDelete(
    BuildContext context,
    WidgetRef ref,
    List<OrphanTrack> allOrphans,
    Set<String> selectedIds,
  ) async {
    final List<OrphanTrack> toDelete = allOrphans.where((o) => selectedIds.contains(o.track.id)).toList();
    final double totalMb = toDelete.fold(0.0, (sum, o) => sum + o.fileSizeMb);

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer définitivement ?'),
        content: Text(
          '${toDelete.length} morceau(x) seront supprimés du stockage et de la bibliothèque '
          '(${totalMb.toStringAsFixed(1)} Mo libérés). Cette action est irréversible.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(orphanPurgeServiceProvider).deleteTracks(toDelete.map((o) => o.track).toList());
    ref.read(selectedOrphanIdsProvider.notifier).set({});
    ref.invalidate(orphanTracksProvider);
  }
}

class _OrphanTile extends ConsumerWidget {
  const _OrphanTile({required this.orphan});

  final OrphanTrack orphan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Track track = orphan.track;
    final Set<String> selected = ref.watch(selectedOrphanIdsProvider);
    final bool isSelected = selected.contains(track.id);

    return CheckboxListTile(
      value: isSelected,
      onChanged: (checked) {
        final Set<String> updated = {...selected};
        checked == true ? updated.add(track.id) : updated.remove(track.id);
        ref.read(selectedOrphanIdsProvider.notifier).set(updated);
      },
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${track.artists.join(', ')} · ${orphan.fileSizeMb.toStringAsFixed(1)} Mo · ${_lastPlayedLabel(track.lastPlayedAt)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String _lastPlayedLabel(DateTime? date) {
    if (date == null) return 'Jamais écouté';
    return 'Écouté le ${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}
