import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/shared/widgets/local_track_picker_sheet.dart';
import '../../../../core/storage/database/app_database.dart';
import '../../../../core/storage/storage_manager/picked_file_cache.dart';
import '../../../diff/data/diff_providers.dart';
import '../../domain/import_match_plan.dart';

/// Fenêtre de matching manuel d'un import JSON : ouverte uniquement quand le
/// matching automatique (ImportTrackMatcher) laisse des titres ambigus ou
/// introuvables. Pour chacun, l'utilisateur choisit :
///  - une suggestion (plusieurs versions, même titre chez un autre
///    artiste...) ;
///  - n'importe quel morceau de sa bibliothèque (recherche) ;
///  - un fichier audio de l'appareil, importé dans la bibliothèque ;
///  - ou de laisser le titre grisé : il reste dans la playlist à sa place,
///    sauté à la lecture, et sera associé automatiquement dès que le fichier
///    correspondant entrera dans la bibliothèque.
///
/// Renvoie la résolution complète (un `trackId` ou `null` par titre du
/// manifeste, dans l'ordre), ou `null` si l'utilisateur abandonne l'import.
class ImportMatchingScreen extends ConsumerStatefulWidget {
  const ImportMatchingScreen({super.key, required this.playlistTitle, required this.plan});

  final String playlistTitle;
  final ImportMatchPlan plan;

  static Future<List<String?>?> show(
    BuildContext context, {
    required String playlistTitle,
    required ImportMatchPlan plan,
  }) {
    // Navigator racine : plein écran au-dessus de la barre d'onglets, même
    // lancé depuis un onglet (Mon espace) — sinon la NavigationBar restait
    // visible sous la fenêtre.
    return Navigator.of(context, rootNavigator: true).push<List<String?>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => ImportMatchingScreen(playlistTitle: playlistTitle, plan: plan),
      ),
    );
  }

  @override
  ConsumerState<ImportMatchingScreen> createState() => _ImportMatchingScreenState();
}

/// Valeur de la radio "Laisser grisé" (aucun morceau associé).
const String _kLeaveMissing = '__leave_missing__';

class _ImportMatchingScreenState extends ConsumerState<ImportMatchingScreen> {
  late final List<ImportMatchEntry> _review = widget.plan.needsReview;
  late final List<String?> _resolution = _initialResolution();
  // Morceaux choisis via la recherche ou l'import de fichier, hors
  // suggestions : nécessaires pour afficher leur libellé dans la carte.
  final Map<int, Track> _extraChoices = {};
  int? _importingIndex;

  /// Associations automatiques conservées ; pour les titres à vérifier, la
  /// première version proposée est présélectionnée seulement quand le titre
  /// ET l'artiste correspondent (plusieurs versions du même morceau) — un
  /// même titre chez un autre artiste n'est jamais présélectionné.
  List<String?> _initialResolution() {
    final List<String?> resolution = [...widget.plan.autoResolution];
    final Set<String> used = resolution.whereType<String>().toSet();
    for (final ImportMatchEntry entry in _review) {
      if (entry.status != ImportMatchStatus.ambiguous) continue;
      for (final Track candidate in entry.candidates) {
        if (used.add(candidate.id)) {
          resolution[entry.index] = candidate.id;
          break;
        }
      }
    }
    return resolution;
  }

  Set<String> _usedElsewhere(int index) => {
        for (int i = 0; i < _resolution.length; i++)
          if (i != index && _resolution[i] != null) _resolution[i]!,
      };

  int get _linkedCount => _resolution.where((id) => id != null).length;

  int get _missingCount => _resolution.length - _linkedCount;

  Future<void> _searchLibrary(ImportMatchEntry entry) async {
    final Track? picked = await LocalTrackPickerSheet.show(
      context,
      title: 'Associer « ${entry.ref.title} »',
      initialQuery: entry.ref.title,
      unavailableIds: _usedElsewhere(entry.index),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _extraChoices[entry.index] = picked;
      _resolution[entry.index] = picked.id;
    });
  }

  Future<void> _importFile(ImportMatchEntry entry) async {
    final PlatformFile? file = await FilePicker.pickFile(type: FileType.audio);
    final String? path = file?.path;
    if (path == null || !mounted) return;

    setState(() => _importingIndex = entry.index);
    Track? imported;
    try {
      imported = await ref.read(missingTrackResolverProvider).importFromDevice(File(path));
    } catch (_) {
      imported = null;
    } finally {
      // Copie intermédiaire du sélecteur (cache Android), voir clearPickedFileCache.
      await clearPickedFileCache();
    }
    if (!mounted) return;
    setState(() => _importingIndex = null);

    if (imported == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fichier trop court ou illisible.')));
      return;
    }
    if (_usedElsewhere(entry.index).contains(imported.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ce morceau est déjà associé à un autre titre de la playlist.')),
      );
      return;
    }
    final Track track = imported;
    setState(() {
      _extraChoices[entry.index] = track;
      _resolution[entry.index] = track.id;
    });
  }

  Future<void> _confirmCancel() async {
    final bool? abandon = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Abandonner l\'import ?'),
        content: const Text('La playlist ne sera pas importée.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Continuer')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Abandonner')),
        ],
      ),
    );
    if (abandon == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final int total = widget.plan.entries.length;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _confirmCancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Abandonner', onPressed: _confirmCancel),
          title: const Text('Associer les titres'),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('« ${widget.playlistTitle} » — $total titre${total > 1 ? 's' : ''}',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      '${widget.plan.autoMatchedCount} associé(s) automatiquement. '
                      '${_review.length} titre(s) à vérifier ci-dessous.',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Un titre laissé grisé reste dans la playlist à sa place, est sauté à la lecture, '
                      'et sera associé automatiquement dès que le fichier correspondant sera ajouté '
                      'à ta bibliothèque.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            for (final ImportMatchEntry entry in _review)
              _MatchCard(
                entry: entry,
                selectedId: _resolution[entry.index],
                extraChoice: _extraChoices[entry.index],
                usedElsewhere: _usedElsewhere(entry.index),
                importing: _importingIndex == entry.index,
                onChanged: (id) => setState(() => _resolution[entry.index] = id),
                onSearch: () => _searchLibrary(entry),
                onImportFile: _importingIndex == null ? () => _importFile(entry) : null,
              ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              icon: const Icon(Icons.playlist_add_check),
              label: Text(
                'Importer · $_linkedCount associé${_linkedCount > 1 ? 's' : ''}'
                '${_missingCount > 0 ? ' · $_missingCount grisé${_missingCount > 1 ? 's' : ''}' : ''}',
              ),
              onPressed:
                  _importingIndex != null ? null : () => Navigator.of(context).pop(List<String?>.of(_resolution)),
            ),
          ),
        ),
      ),
    );
  }
}

class _MatchCard extends StatelessWidget {
  const _MatchCard({
    required this.entry,
    required this.selectedId,
    required this.extraChoice,
    required this.usedElsewhere,
    required this.importing,
    required this.onChanged,
    required this.onSearch,
    required this.onImportFile,
  });

  final ImportMatchEntry entry;
  final String? selectedId;
  final Track? extraChoice;
  final Set<String> usedElsewhere;
  final bool importing;
  final ValueChanged<String?> onChanged;
  final VoidCallback onSearch;
  final VoidCallback? onImportFile;

  /// Diagnostic du matching automatique, remplacé par "Associé
  /// manuellement" dès que l'utilisateur a choisi un morceau pour un titre
  /// que l'automatique n'avait pas trouvé.
  String get _statusLabel {
    if (selectedId != null && entry.status != ImportMatchStatus.ambiguous) return 'Associé manuellement';
    return switch (entry.status) {
      ImportMatchStatus.ambiguous => 'Plusieurs versions possibles — choisis la bonne',
      ImportMatchStatus.titleOnly => 'Même titre chez un autre artiste — à confirmer',
      ImportMatchStatus.notFound => 'Introuvable dans ta bibliothèque',
      ImportMatchStatus.exact || ImportMatchStatus.confident => 'Associé automatiquement',
    };
  }

  bool get _isUnresolved => selectedId == null && entry.status == ImportMatchStatus.notFound;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<Track> options = [
      ...entry.candidates,
      if (extraChoice != null && !entry.candidates.any((t) => t.id == extraChoice!.id)) extraChoice!,
    ];

    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading:
                  CircleAvatar(radius: 16, child: Text('${entry.index + 1}', style: const TextStyle(fontSize: 12))),
              title: Text(entry.ref.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text([entry.ref.artist, if (entry.ref.album != null) entry.ref.album!].join(' · ')),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _statusLabel,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: _isUnresolved ? colors.error : colors.tertiary,
                    ),
              ),
            ),
            RadioGroup<String>(
              groupValue: selectedId ?? _kLeaveMissing,
              onChanged: (value) => onChanged(value == null || value == _kLeaveMissing ? null : value),
              child: Column(
                children: [
                  for (final Track track in options)
                    RadioListTile<String>(
                      dense: true,
                      value: track.id,
                      enabled: !usedElsewhere.contains(track.id),
                      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        usedElsewhere.contains(track.id)
                            ? 'Déjà associé à un autre titre'
                            : [track.artists.join(', '), if (track.album.isNotEmpty) track.album].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  RadioListTile<String>(
                    dense: true,
                    value: _kLeaveMissing,
                    title: const Text('Laisser grisé'),
                    subtitle: const Text('Associé automatiquement dès que le fichier sera ajouté'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Chercher dans ma bibliothèque'),
                    onPressed: onSearch,
                  ),
                  TextButton.icon(
                    icon: importing
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload_file_outlined, size: 18),
                    label: const Text('Importer un fichier'),
                    onPressed: onImportFile,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
