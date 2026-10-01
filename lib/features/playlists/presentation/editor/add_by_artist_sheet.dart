import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/storage/database/app_database.dart';
import '../../../discovery/data/artist_providers.dart';
import '../../../discovery/domain/artist_filter.dart';
import '../../../discovery/domain/artist_sort.dart';
import '../../data/playlist_providers.dart';

/// Feuille "Ajouter par artiste" de l'éditeur de playlist (Feuille de route
/// pt.9) : sélectionner un artiste de la bibliothèque ajoute d'un coup toutes
/// ses musiques déjà téléchargées, triées par ordre chronologique de sortie
/// (le plus ancien en premier — lecture "dans l'ordre" de la discographie de
/// l'artiste, pas l'ordre inverse utilisé par le Profil Artiste pour mettre
/// les nouveautés en avant).
class AddByArtistSheet extends ConsumerStatefulWidget {
  const AddByArtistSheet({super.key, required this.playlistId});

  final String playlistId;

  static Future<void> show(BuildContext context, String playlistId) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // iOS : tirée à pleine hauteur, la feuille passerait sous l'encoche/la
      // Dynamic Island — bornée à la zone sûre (Android : inchangé).
      useSafeArea: AppPlatform.isIOS,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, scrollController) => AddByArtistSheet(playlistId: playlistId),
      ),
    );
  }

  @override
  ConsumerState<AddByArtistSheet> createState() => _AddByArtistSheetState();
}

class _AddByArtistSheetState extends ConsumerState<AddByArtistSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _addingArtist;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Récupère les morceaux de l'artiste en appelant directement
  /// [ArtistRepository] plutôt que `ref.read(artistTracksProvider(...).future)`
  /// : bug réel reproduit avec cette dernière approche — le `Future` ne se
  /// résolvait jamais (observé en conditions réelles : `_addArtist` restait
  /// bloqué indéfiniment sur cet `await`, empêchant tout ajout). L'appel
  /// direct au repository (déjà utilisé ailleurs dans l'app) contourne le
  /// souci sans en changer le comportement fonctionnel.
  Future<void> _addArtist(String artistName) async {
    setState(() => _addingArtist = artistName);

    final List<Track> tracks = await ref
        .read(artistRepositoryProvider)
        .watchArtistTracks(artistName, filter: ArtistFilter.all, sort: ArtistSort.chronological)
        .first;
    // `ArtistSort.chronological` trie du plus récent au plus ancien (voir
    // DriftArtistRepository, pensé pour le Profil Artiste) — on veut ici
    // l'inverse : la discographie dans son ordre de parution.
    final List<Track> chronological = tracks.reversed.toList();

    final int added = await ref
        .read(playlistTrackRepositoryProvider)
        .addTracks(widget.playlistId, chronological.map((t) => t.id).toList());

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'Tous les morceaux de $artistName sont déjà dans la playlist.'
              : '$added morceau(x) de $artistName ajouté(s).',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<String>> artistNames = ref.watch(allLocalArtistNamesProvider);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Ajouter par artiste', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Rechercher un artiste...',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
                ),
              ],
            ),
          ),
          Flexible(
            child: artistNames.when(
              data: (data) {
                final List<String> filtered =
                    _query.isEmpty ? data : data.where((name) => name.toLowerCase().contains(_query)).toList();
                if (filtered.isEmpty) {
                  return const Padding(padding: EdgeInsets.all(24), child: Text('Aucun artiste trouvé.'));
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final String artistName = filtered[index];
                    final bool isAdding = _addingArtist == artistName;
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                      title: Text(artistName),
                      trailing: isAdding
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : null,
                      onTap: _addingArtist != null ? null : () => _addArtist(artistName),
                    );
                  },
                );
              },
              loading: () =>
                  const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
              error: (error, _) => Padding(padding: const EdgeInsets.all(24), child: Text('Erreur : $error')),
            ),
          ),
        ],
      ),
    );
  }
}
