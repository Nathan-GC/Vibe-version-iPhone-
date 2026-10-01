import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/library/data/library_providers.dart';
import '../../identity/track_match_key.dart';
import '../../storage/database/app_database.dart';

/// Recherche d'un morceau de la bibliothèque locale pour l'associer à un
/// titre importé (fenêtre de matching manuel, titre grisé de l'éditeur).
/// Recherche insensible à la casse et aux accents sur titre, artistes et
/// album ; chaque mot saisi doit être présent.
///
/// [unavailableIds] : morceaux déjà associés à un autre titre de la même
/// playlist — affichés mais non sélectionnables (une playlist ne contient
/// jamais deux fois le même morceau).
class LocalTrackPickerSheet extends ConsumerStatefulWidget {
  const LocalTrackPickerSheet({
    super.key,
    required this.title,
    this.initialQuery = '',
    this.unavailableIds = const {},
    this.unavailableLabel = 'Déjà associé à un autre titre',
  });

  final String title;
  final String initialQuery;
  final Set<String> unavailableIds;
  final String unavailableLabel;

  static Future<Track?> show(
    BuildContext context, {
    required String title,
    String initialQuery = '',
    Set<String> unavailableIds = const {},
    String unavailableLabel = 'Déjà associé à un autre titre',
  }) {
    return showModalBottomSheet<Track>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => LocalTrackPickerSheet(
        title: title,
        initialQuery: initialQuery,
        unavailableIds: unavailableIds,
        unavailableLabel: unavailableLabel,
      ),
    );
  }

  @override
  ConsumerState<LocalTrackPickerSheet> createState() => _LocalTrackPickerSheetState();
}

class _LocalTrackPickerSheetState extends ConsumerState<LocalTrackPickerSheet> {
  static const int _maxResults = 200;

  late final TextEditingController _controller = TextEditingController(text: widget.initialQuery);
  late String _query = widget.initialQuery;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<Track> _filter(List<Track> library) {
    final List<String> words = foldDiacritics(_query).split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) return library.take(_maxResults).toList();
    return library
        .where((track) {
          final String haystack = foldDiacritics('${track.title} ${track.artists.join(' ')} ${track.album}');
          return words.every(haystack.contains);
        })
        .take(_maxResults)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Track>> library = ref.watch(libraryTracksProvider);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Titre, artiste ou album',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Effacer',
                          onPressed: () => setState(() {
                            _controller.clear();
                            _query = '';
                          }),
                        ),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: library.when(
                data: (tracks) {
                  final List<Track> results = _filter(tracks);
                  if (results.isEmpty) return const Center(child: Text('Aucun morceau ne correspond.'));
                  return ListView.builder(
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final Track track = results[index];
                      final bool unavailable = widget.unavailableIds.contains(track.id);
                      return ListTile(
                        enabled: !unavailable,
                        leading: const Icon(Icons.music_note_outlined),
                        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          unavailable
                              ? widget.unavailableLabel
                              : [track.artists.join(', '), if (track.album.isNotEmpty) track.album].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.of(context).pop(track),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(child: Text('Erreur : $error')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
