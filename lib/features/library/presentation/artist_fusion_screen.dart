import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/identity/track_match_key.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../discovery/data/artist_providers.dart';
import '../../discovery/domain/top_artist_playlist.dart';

/// Fusion d'artistes — déplacée des Réglages vers la zone d'importation de
/// la Bibliothèque (bouton sous "Importer des MP3", voir LibraryScreen) :
/// c'est juste après un import que les doublons d'artistes apparaissent.
///
/// Deux modes clairement séparés en haut d'écran :
///  - **Fusion automatique** : [TrackRepository.mergeDuplicateCaseArtists]
///    (variantes de casse du même nom, "DAFT PUNK" / "Daft Punk") ;
///  - **Fusion manuelle** : barre de recherche dynamique (insensible à la
///    casse et aux accents) + sélection multiple par appui simple (l'appui
///    long fait de même, voir la convention de gestes de PlaylistCard) :
///     - >= 2 sélectionnés : "Fusionner" (choix du nom cible parmi la
///       sélection ou nom personnalisé) ;
///     - exactement 1 sélectionné : "Renommer".
///    Les deux passent par [TrackRepository.renameOrMergeArtists].
/// La sélection survit au filtrage : les artistes sélectionnés restent
/// visibles en puces au-dessus de la liste même s'ils ne correspondent plus
/// à la recherche.
class ArtistFusionScreen extends ConsumerStatefulWidget {
  const ArtistFusionScreen({super.key, this.initialMode = ArtistFusionMode.manual});

  final ArtistFusionMode initialMode;

  @override
  ConsumerState<ArtistFusionScreen> createState() => _ArtistFusionScreenState();
}

enum ArtistFusionMode { automatic, manual }

/// Repli minuscule + sans accents pour la recherche ("beyonce" trouve
/// "Beyoncé", "ANGELE" trouve "Angèle").
String foldForArtistSearch(String input) => foldDiacritics(input.trim());

class _ArtistFusionScreenState extends ConsumerState<ArtistFusionScreen> {
  final Set<String> _selected = {};
  final TextEditingController _searchController = TextEditingController();
  late ArtistFusionMode _mode = widget.initialMode;
  String _query = '';
  bool _busy = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggle(String artistName) {
    setState(() {
      if (!_selected.remove(artistName)) _selected.add(artistName);
    });
  }

  Future<void> _runAutomaticFusion() async {
    setState(() => _busy = true);
    final int mergedGroups = await ref.read(trackRepositoryProvider).mergeDuplicateCaseArtists();
    ref.invalidate(allArtistsWithTrackCountProvider);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mergedGroups == 0 ? 'Aucun doublon de casse trouvé.' : '$mergedGroups artiste(s) fusionné(s).'),
      ),
    );
  }

  Future<void> _rename() async {
    final String current = _selected.single;
    final String? newName = await _promptForName(initial: current, title: 'Renommer "$current"');
    if (newName == null || newName.trim().isEmpty) return;
    await _apply([current], newName.trim());
  }

  Future<void> _merge() async {
    final String? targetName = await _pickMergeTargetName();
    if (targetName == null || targetName.trim().isEmpty) return;
    await _apply(_selected.toList(), targetName.trim());
  }

  Future<void> _apply(List<String> sources, String target) async {
    setState(() => _busy = true);
    await ref.read(trackRepositoryProvider).renameOrMergeArtists(sources, target);
    ref.invalidate(allArtistsWithTrackCountProvider);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"$target" appliqué à ${sources.length} artiste(s).')),
    );
  }

  Future<String?> _promptForName({required String initial, required String title}) {
    final TextEditingController controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content:
            TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Nom')),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Valider')),
        ],
      ),
    );
  }

  /// Choix du nom cible parmi la sélection, ou saisie d'un nom personnalisé
  /// (ex. fusionner "Artist & A" + "Artist & B" en "Artist") — les deux
  /// options s'excluent mutuellement : taper dans le champ personnalisé
  /// désélectionne la radio, et inversement.
  Future<String?> _pickMergeTargetName() {
    final List<String> choices = _selected.toList()..sort();
    final TextEditingController customController = TextEditingController();
    String? selectedChoice = choices.first;

    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Fusionner vers...'),
            content: SingleChildScrollView(
              child: RadioGroup<String>(
                groupValue: selectedChoice,
                onChanged: (value) => setDialogState(() {
                  selectedChoice = value;
                  customController.clear();
                }),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final choice in choices) RadioListTile<String>(title: Text(choice), value: choice),
                    const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider()),
                    TextField(
                      controller: customController,
                      decoration: const InputDecoration(labelText: 'Nom personnalisé'),
                      onChanged: (value) => setDialogState(() {
                        if (value.trim().isNotEmpty) selectedChoice = null;
                      }),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(
                  customController.text.trim().isNotEmpty ? customController.text.trim() : selectedChoice,
                ),
                child: const Text('Fusionner'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool manual = _mode == ArtistFusionMode.manual;
    final int selectedCount = _selected.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(manual && selectedCount > 0 ? '$selectedCount sélectionné(s)' : 'Fusion d\'artistes'),
        actions: [
          if (manual && selectedCount == 1)
            TextButton(onPressed: _busy ? null : _rename, child: const Text('Renommer')),
          if (manual && selectedCount >= 2)
            TextButton(onPressed: _busy ? null : _merge, child: const Text('Fusionner')),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<ArtistFusionMode>(
                segments: const [
                  ButtonSegment(
                    value: ArtistFusionMode.automatic,
                    icon: Icon(Icons.auto_fix_high_outlined),
                    label: Text('Fusion automatique'),
                  ),
                  ButtonSegment(
                    value: ArtistFusionMode.manual,
                    icon: Icon(Icons.checklist_outlined),
                    label: Text('Fusion manuelle'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: _busy ? null : (value) => setState(() => _mode = value.single),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          Expanded(child: manual ? _buildManual(context) : _buildAutomatic(context)),
        ],
      ),
    );
  }

  Widget _buildAutomatic(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Regroupe automatiquement les variantes de casse d\'un même artiste '
          '(ex. "DAFT PUNK", "daft punk" et "Daft Punk") sous un nom unique.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.auto_fix_high_outlined),
          label: const Text('Lancer la fusion automatique'),
          onPressed: _busy ? null : _runAutomaticFusion,
        ),
        const SizedBox(height: 16),
        Text(
          'Pour fusionner des noms réellement différents (ex. "Artist & A" et '
          '"Artist & B"), utilise la Fusion manuelle.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildManual(BuildContext context) {
    final AsyncValue<List<TopArtistPlaylist>> artists = ref.watch(allArtistsWithTrackCountProvider);
    final String foldedQuery = foldForArtistSearch(_query);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Rechercher un artiste',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Effacer',
                      onPressed: () => setState(() {
                        _searchController.clear();
                        _query = '';
                      }),
                    ),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        if (_selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final String name in (_selected.toList()..sort()))
                    InputChip(label: Text(name), onDeleted: () => _toggle(name)),
                ],
              ),
            ),
          ),
        Expanded(
          child: artists.when(
            data: (data) {
              if (data.isEmpty) return const Center(child: Text('Aucun artiste.'));
              final List<TopArtistPlaylist> filtered = foldedQuery.isEmpty
                  ? data
                  : data.where((a) => foldForArtistSearch(a.artistName).contains(foldedQuery)).toList();
              if (filtered.isEmpty) return const Center(child: Text('Aucun artiste ne correspond.'));
              return ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final TopArtistPlaylist artist = filtered[index];
                  final bool selected = _selected.contains(artist.artistName);
                  return ListTile(
                    selected: selected,
                    leading: CircleAvatar(child: Icon(selected ? Icons.check : Icons.person_outline)),
                    title: Text(artist.artistName),
                    subtitle: Text('${artist.trackCount} morceau${artist.trackCount > 1 ? 'x' : ''}'),
                    onTap: _busy ? null : () => _toggle(artist.artistName),
                    onLongPress: _busy ? null : () => _toggle(artist.artistName),
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text('Erreur : $error')),
          ),
        ),
      ],
    );
  }
}
