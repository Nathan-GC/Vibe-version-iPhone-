import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/shared/widgets/enrichment_source_dialog.dart';
import '../../../core/shared/widgets/library_category_picker.dart';
import '../../../core/shared/widgets/track_actions_sheet.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/duplicate_track_group.dart';
import '../../../core/storage/database/library_category.dart';
import '../../../core/storage/database/track_enricher.dart';
import '../../../core/storage/database/track_repository.dart';
import '../../../core/storage/scanner/audio_import_pipeline.dart';
import '../../../core/storage/scanner/documents_library_sync.dart';
import '../../../core/storage/scanner/scanned_track.dart';
import '../../../core/storage/storage_manager/picked_file_cache.dart';
import '../../settings/data/auto_enrich_preference.dart';
import '../data/documents_sync_controller.dart';
import '../data/library_enrichment_runner.dart';
import '../data/library_providers.dart';
import 'metadata_editor_modal.dart';

/// Bibliothèque locale : import manuel de MP3 depuis le stockage (copiés
/// automatiquement dans le dossier de l'app, voir StorageManagerService),
/// liste des morceaux déjà connus (Étape 3).
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  bool _busy = false;
  String? _statusMessage;

  Future<void> _importFiles() async {
    final List<PlatformFile> picked = await FilePicker.pickFiles(type: FileType.audio);
    if (picked.isEmpty) return;

    setState(() {
      _busy = true;
      _statusMessage = 'Import 0 / ${picked.length}...';
    });

    try {
      final AudioImportPipeline pipeline = AudioImportPipeline(
        storageManager: ref.read(storageManagerServiceProvider),
        scanService: ref.read(libraryScanServiceProvider),
        trackRepository: ref.read(trackRepositoryProvider),
      );

      int imported = 0;
      int tooShort = 0;
      int failed = 0;
      String? lastError;
      // Renommés (repli FilenameSanitizer, pas de tag ID3 exploitable) parmi
      // ce lot — seuls ceux-là seront enrichis automatiquement juste après,
      // une fois TOUS les fichiers du lot renommés et persistés (phase 1
      // renommage, puis phase 2 enrichissement, jamais entrelacées).
      final List<ScannedTrack> renamedTracks = [];

      for (int i = 0; i < picked.length; i++) {
        final String? path = picked[i].path;
        if (path != null) {
          try {
            // Copie privée supprimée d'office si le fichier est refusé
            // (< 30 s) ou échoue, voir AudioImportPipeline.
            final ScannedTrack? track = await pipeline.importFile(File(path));
            if (track != null) {
              imported++;
              if (track.wasRenamedFromFilename) renamedTracks.add(track);
            } else {
              tooShort++;
            }
          } catch (error) {
            // Distingué de "trop court" : un import qui échoue (stockage,
            // permission, fichier corrompu...) doit rester visible plutôt que
            // de se fondre dans les morceaux légitimement ignorés — c'est
            // justement ce qui rendait un vrai problème indétectable depuis
            // l'app installée sur téléphone.
            failed++;
            lastError = error.toString();
          }
        } else {
          failed++;
        }

        if (mounted) {
          setState(() => _statusMessage = 'Import ${i + 1} / ${picked.length}...');
        }
      }

      // Import manuel : enrichissement automatique des morceaux renommés via
      // iTunes exclusivement, sans aucune question posée à l'utilisateur —
      // même principe que le premier scan (voir "Recadrage du Workflow
      // d'Enrichissement"). Seul le bouton étoile ✨ ("Enrichir tout")
      // propose un choix de source.
      // Droit d'opposition (Paramètres) : désactivé, l'import reste hors-ligne.
      int enriched = 0;
      final bool autoEnrich = await AutoEnrichPreference.isEnabled();
      if (renamedTracks.isNotEmpty && mounted && autoEnrich) {
        final TrackEnricher enricher = ref.read(trackAutoEnricherProvider);
        for (int i = 0; i < renamedTracks.length; i++) {
          if (mounted) {
            setState(() => _statusMessage = 'Enrichissement ${i + 1} / ${renamedTracks.length}...');
          }
          final ScannedTrack track = renamedTracks[i];
          final bool ok = await enricher.enrichTrack(
            trackId: track.id,
            title: track.title,
            artists: track.artists,
          );
          if (ok) enriched++;
        }
      }

      if (!mounted) return;
      final String summary = [
        '$imported importé(s)',
        if (renamedTracks.isNotEmpty)
          autoEnrich ? '$enriched/${renamedTracks.length} renommé(s) enrichi(s)' : 'enrichissement auto désactivé',
        if (tooShort > 0) '$tooShort trop court(s) ou illisible(s)',
        if (failed > 0) '$failed échec(s)${lastError == null ? '' : ' : $lastError'}',
      ].join(', ');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary)));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import impossible : $error')));
      }
    } finally {
      // Copies intermédiaires du sélecteur de fichiers (cache Android) :
      // inutiles une fois les fichiers copiés dans le dossier de l'app.
      await clearPickedFileCache();
      if (mounted) {
        setState(() {
          _busy = false;
          _statusMessage = null;
        });
      }
    }
  }

  void _openMetadataEditor(Track track) {
    showDialog<void>(context: context, builder: (context) => MetadataEditorModal(track: track));
  }

  /// Choix de la source pour un enrichissement global (Section 2.1) —
  /// affiché une fois par lancement d'"Enrichir tout" ou post-import, jamais
  /// pour un enrichissement individuel (voir MetadataEditorModal pour le
  /// choix de source par morceau). `null` si l'utilisateur annule.
  Future<EnrichmentSource?> _pickEnrichmentSource() => showEnrichmentSourceDialog(context);

  TrackEnricher _enricherFor(EnrichmentSource source) => switch (source) {
        EnrichmentSource.itunes => ref.read(trackAutoEnricherProvider),
        EnrichmentSource.musicBrainz => ref.read(musicBrainzAutoEnricherProvider),
      };

  /// Scanner de nettoyage des artistes (Feuille de route Vibe v5) : fusionne
  /// les variantes de casse d'un même nom ("DAFT PUNK"/"daft punk") sous une
  /// unique entité en Title Case.
  Future<void> _mergeArtists() async {
    final int mergedGroups = await ref.read(trackRepositoryProvider).mergeDuplicateCaseArtists();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          mergedGroups == 0 ? 'Aucun doublon de casse trouvé.' : '$mergedGroups artiste(s) fusionné(s).',
        ),
      ),
    );
  }

  /// Enrichissement individuel (bouton rapide sur un morceau) — toujours
  /// iTunes : pas de sélection de source pour ce cas précis (voir Section
  /// 2.1, réservée à "Enrichir tout"/post-import), le choix par morceau se
  /// fait plutôt dans MetadataEditorModal (Section 2.3).
  ///
  /// Morceau "À renommer" (recette QA, choix 2-A) : son Titre/Artiste sont
  /// trop ambigus pour une recherche automatique (circuit-breaker
  /// `requiresReview`, qui répondait aussitôt "Aucune correspondance
  /// trouvée") — ouvre plutôt la recherche manuelle iTunes/MusicBrainz de
  /// l'éditeur, pré-remplie avec le nom du fichier audio.
  Future<void> _enrichSingle(Track track) async {
    if (libraryCategoryOf(track) == LibraryCategory.toRename) {
      await showDialog<void>(
        context: context,
        builder: (context) => MetadataEditorModal(
          track: track,
          initialSearchQuery: searchQueryFromFilePath(track.filePath, fallbackTitle: track.title),
        ),
      );
      return;
    }

    final TrackEnricher enricher = ref.read(trackAutoEnricherProvider);
    bool found = false;
    for (int attempt = 1; attempt <= _maxEnrichmentPasses && !found; attempt++) {
      // Non destructif (voir TrackRepository.enrichFromOnlineMetadata) : sûr à relancer.
      found = await enricher.enrichTrack(trackId: track.id, title: track.title, artists: track.artists);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(found ? 'Pochette et genres mis à jour' : 'Aucune correspondance trouvée')),
    );
  }

  /// Passes d'"Enrichir tout" ([LibraryEnrichmentRunner]) et tentatives du
  /// bouton ✨ individuel ([_enrichSingle]).
  static const int _maxEnrichmentPasses = 3;

  /// Enrichit tous les morceaux de la catégorie "À enrichir" (hors échecs
  /// auto déjà épuisés, voir [trackNeedsEnrichment]) — boucle de passes et
  /// synchronisation avec la base dans [LibraryEnrichmentRunner].
  /// L'espacement des requêtes iTunes est géré côté [MetadataApiClient]
  /// (throttle + reprise sur blocage de débit), pas ici.
  Future<void> _enrichLibrary() async {
    final TrackRepository repository = ref.read(trackRepositoryProvider);
    final bool nothingToDo = (await repository.fetchAllTracks()).where(trackNeedsEnrichment).isEmpty;
    if (nothingToDo) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rien à enrichir.')));
      }
      return;
    }

    final EnrichmentSource? source = await _pickEnrichmentSource();
    if (source == null || !mounted) return;
    final LibraryEnrichmentRunner runner = LibraryEnrichmentRunner(
      repository: repository,
      enricher: _enricherFor(source),
      maxPasses: _maxEnrichmentPasses,
    );

    setState(() => _busy = true);

    final LibraryEnrichmentResult result = await runner.run(
      onProgress: (pass, index, passSize) {
        if (mounted) {
          setState(() => _statusMessage = 'Enrichissement (passe $pass/${runner.maxPasses}) $index / $passSize...');
        }
      },
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${result.enriched} / ${result.targets} morceau(x) enrichi(s)')),
    );
    setState(() {
      _busy = false;
      _statusMessage = null;
    });

    await _proposeMergeArtists();
  }

  /// Proposée une fois l'enrichissement global terminé (voir "Recadrage du
  /// Workflow d'Enrichissement", 1.C) : l'enrichissement révèle souvent de
  /// nouveaux doublons de casse (ex. "DAFT PUNK" venu d'un tag ID3 vs "Daft
  /// Punk" déjà normalisé) — proposer la fusion tout de suite plutôt que de
  /// laisser l'utilisateur redécouvrir le bouton dédié.
  Future<void> _proposeMergeArtists() async {
    if (!mounted) return;
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fusionner les artistes en double ?'),
        content: const Text(
          'L\'enrichissement peut avoir révélé des variantes de casse du même artiste (ex. "DAFT PUNK" / "Daft Punk").',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Plus tard')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Fusionner')),
        ],
      ),
    );
    if (proceed == true) await _mergeArtists();
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Track>> allTracks = ref.watch(libraryTracksProvider);
    final List<DuplicateTrackGroup> duplicateGroups = ref.watch(duplicateTrackGroupsProvider).value ?? const [];
    final LibraryFilterState filter = ref.watch(libraryFilterProvider);
    final LibrarySort sort = ref.watch(librarySortProvider);
    final List<Track> allTracksData = allTracks.value ?? const [];

    final Map<LibraryCategory, int> categoryCounts = {for (final category in LibraryCategory.values) category: 0};
    final Map<EnrichmentStatus, int> statusCounts = {};
    for (final track in allTracksData) {
      categoryCounts.update(libraryCategoryOf(track), (count) => count + 1);
      statusCounts.update(track.enrichmentStatus, (count) => count + 1, ifAbsent: () => 1);
    }
    // Sous-catégories de la catégorie sélectionnée qui ont au moins un
    // morceau — une puce à (0) n'apporterait rien.
    final List<EnrichmentProvenanceFilter> visibleProvenances = [
      for (final provenance in EnrichmentProvenanceFilter.values)
        if (provenance.category == filter.category && (statusCounts[provenance.matchingStatus] ?? 0) > 0) provenance,
    ];

    final AsyncValue<List<Track>> tracks = allTracks.whenData((data) => filterLibraryTracks(data, filter));

    return PopScope(
      // Ergonomie navigation Android (2.B) : un filtre actif est un état de
      // la page, pas une vraie route/modale — le bouton Retour doit d'abord
      // l'effacer avant de vraiment quitter cette page.
      canPop: !filter.isActive,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        ref.read(libraryFilterProvider.notifier).clear();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Bibliothèque'),
          actions: [
            PopupMenuButton<LibrarySort>(
              icon: const Icon(Icons.sort),
              tooltip: 'Trier',
              initialValue: sort,
              onSelected: (value) => ref.read(librarySortProvider.notifier).setSort(value),
              itemBuilder: (context) =>
                  LibrarySort.values.map((value) => PopupMenuItem(value: value, child: Text(value.label))).toList(),
            ),
            IconButton(
              icon: const Icon(Icons.auto_awesome_outlined),
              tooltip: 'Enrichir les titres « À enrichir »',
              onPressed: _busy ? null : _enrichLibrary,
            ),
          ],
        ),
        body: Column(
          children: [
            // Zone d'importation : import des fichiers + fusion des artistes
            // (déplacée depuis les Réglages) — les doublons d'artistes
            // apparaissent justement après un import.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.upload_file_outlined),
                  label: const Text('Importer des MP3'),
                  onPressed: _busy ? null : _importFiles,
                ),
              ),
            ),
            // iOS : second canal d'import, propre à l'iPhone — les morceaux
            // déposés dans Fichiers > Sur mon iPhone > Vibe (ou via le
            // Finder) sont indexés automatiquement au lancement et au retour
            // dans l'app ; ce bouton force une synchronisation immédiate.
            if (AppPlatform.isIOS) _DocumentsSyncSection(enabled: !_busy),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Fusionner des artistes'),
                  onPressed: _busy ? null : () => context.push('/space/library/artist-fusion'),
                ),
              ),
            ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(
                  children: [
                    const LinearProgressIndicator(),
                    const SizedBox(height: 4),
                    Text(_statusMessage ?? '', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            if (allTracksData.isNotEmpty || duplicateGroups.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      // Les 3 catégories principales, mutuellement
                      // exclusives (voir libraryCategoryOf) — toujours
                      // affichées, même à (0), pour que la structure de la
                      // bibliothèque reste lisible d'un coup d'œil.
                      for (final category in LibraryCategory.values)
                        FilterChip(
                          label: Text('${category.label} (${categoryCounts[category]})'),
                          avatar: Icon(category.icon, size: 18, color: category.iconColor),
                          selected: filter.category == category,
                          onSelected: (_) => ref.read(libraryFilterProvider.notifier).toggleCategory(category),
                        ),
                      // Alerte doublons stricts (Titre + Artiste identiques) —
                      // navigue vers un écran dédié plutôt qu'un filtre en
                      // place : chaque groupe se corrige avec l'éditeur de
                      // métadonnées, pas avec un simple filtrage de la liste.
                      if (duplicateGroups.isNotEmpty)
                        ActionChip(
                          label: Text('Doublons détectés (${duplicateGroups.length})'),
                          avatar: const Icon(Icons.content_copy_outlined, size: 18, color: Colors.redAccent),
                          onPressed: () => context.push('/space/library/duplicates'),
                        ),
                    ],
                  ),
                ),
              ),
            // Sous-catégories de provenance (QUI/COMMENT un morceau a été
            // enrichi), affichées seulement sous la catégorie sélectionnée
            // qui les contient — plusieurs cumulables (OU logique).
            if (visibleProvenances.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 12, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final provenance in visibleProvenances)
                        FilterChip(
                          label: Text('${provenance.label} (${statusCounts[provenance.matchingStatus]})'),
                          visualDensity: VisualDensity.compact,
                          selected: filter.provenances.contains(provenance),
                          onSelected: (_) => ref.read(libraryFilterProvider.notifier).toggleProvenance(provenance),
                        ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: tracks.when(
                data: (unsorted) {
                  if (unsorted.isEmpty) {
                    return Center(
                      child:
                          Text(filter.isActive ? 'Aucun morceau dans ce filtre.' : 'Aucun morceau — importe des MP3.'),
                    );
                  }
                  final List<Track> data = sortLibraryTracks(unsorted, sort);
                  return ListView.builder(
                    itemCount: data.length,
                    itemBuilder: (context, index) {
                      final Track track = data[index];
                      final int minutes = track.durationSeconds ~/ 60;
                      final int seconds = track.durationSeconds % 60;
                      return ListTile(
                        leading: _CoverThumbnail(path: track.coverArtPath, needsReview: track.requiresUserReview),
                        title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              [track.artists.join(', '), if (track.album.isNotEmpty) track.album].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (track.tags.isNotEmpty)
                              Text(
                                track.tags.join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('$minutes:${seconds.toString().padLeft(2, '0')}'),
                            IconButton(
                              icon: const Icon(Icons.auto_awesome_outlined, size: 20),
                              tooltip: 'Enrichir (pochette HD + genres)',
                              onPressed: () => _enrichSingle(track),
                            ),
                          ],
                        ),
                        // À tout moment, pas seulement pour les morceaux "À
                        // renommer" : un titre déjà enrichi doit pouvoir être
                        // ré-enrichi ou renommé sans repasser par le badge.
                        onTap: () => _openMetadataEditor(track),
                        onLongPress: () => TrackActionsSheet.show(context, track, showChangeCategory: true),
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

/// `coverArtPath` est double-usage (voir Tracks.coverArtPath) : chemin fichier
/// local extrait des tags ID3, ou URL HD renvoyée par l'enrichissement iTunes.
class _CoverThumbnail extends StatelessWidget {
  const _CoverThumbnail({required this.path, required this.needsReview});

  final String path;
  final bool needsReview;

  @override
  Widget build(BuildContext context) {
    if (needsReview) {
      return const CircleAvatar(child: Icon(Icons.warning_amber_outlined, color: Colors.amber));
    }
    if (path.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.music_note_outlined));
    }

    final ImageProvider image = path.startsWith('http') ? NetworkImage(path) : FileImage(File(path)) as ImageProvider;
    return CircleAvatar(backgroundImage: image, onBackgroundImageError: (_, __) {});
  }
}

/// iOS uniquement : synchronisation du dossier Documents de l'app (voir
/// DocumentsLibrarySync) — rappel de l'emplacement où déposer ses morceaux,
/// bouton d'actualisation immédiate et progression pendant l'indexation
/// (qu'elle ait été lancée ici ou automatiquement au retour dans l'app).
class _DocumentsSyncSection extends ConsumerWidget {
  const _DocumentsSyncSection({required this.enabled});

  final bool enabled;

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final DocumentsSyncResult? result = await ref.read(documentsSyncControllerProvider.notifier).sync();
    if (result == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.added == 0
              ? 'Aucun nouveau morceau dans Fichiers › Sur mon iPhone › Vibe.'
              : [
                  '${result.added} morceau(x) ajouté(s) depuis Fichiers',
                  if (result.enriched > 0) '${result.enriched} enrichi(s)',
                  if (result.skippedIncompleteDownloads > 0)
                    '${result.skippedIncompleteDownloads} téléchargement(s) incomplet(s) ignoré(s)',
                ].join(', '),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DocumentsSyncState sync = ref.watch(documentsSyncControllerProvider);
    final TextTheme textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Actualiser depuis l\'app Fichiers'),
            onPressed: enabled && !sync.isRunning ? () => _sync(context, ref) : null,
          ),
          const SizedBox(height: 4),
          if (sync.isRunning) ...[
            LinearProgressIndicator(value: sync.total > 0 ? sync.processed / sync.total : null),
            const SizedBox(height: 4),
            Text(
              sync.total > 0
                  ? 'Indexation depuis Fichiers ${sync.processed} / ${sync.total}...'
                  : 'Recherche de nouveaux morceaux dans Fichiers...',
              style: textTheme.bodySmall,
            ),
          ] else
            Text(
              'Astuce : dépose tes morceaux (MP3, M4A, FLAC, AAC) dans Fichiers › Sur mon iPhone › Vibe, '
              'ou depuis le Finder de ton Mac — ils apparaissent ici automatiquement.',
              style: textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}
