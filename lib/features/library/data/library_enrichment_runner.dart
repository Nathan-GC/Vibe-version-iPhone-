import '../../../core/storage/database/app_database.dart';
import '../../../core/storage/database/track_enricher.dart';
import '../../../core/storage/database/track_repository.dart';
import 'library_providers.dart';

/// Bilan d'un lancement d'"Enrichir tout".
class LibraryEnrichmentResult {
  const LibraryEnrichmentResult({required this.enriched, required this.targets});

  final int enriched;
  final int targets;
}

/// Boucle d'"Enrichir tout" (LibraryScreen._enrichLibrary), sortie de l'UI
/// pour être testable.
///
/// Boucle de nouvelles tentatives (Feuille de route pt.4) : une passe seule
/// laissait parfois des morceaux non enrichis (timeout ponctuel, requête trop
/// proche de la précédente...) — jusqu'à [maxPasses] passes successives,
/// chacune ne retraitant que ce qui manque encore, arrêt dès qu'une passe
/// n'enrichit plus rien de nouveau.
///
/// Synchronisation (recette QA v1.2) : la liste des morceaux restants est
/// relue DIRECTEMENT en base ([TrackRepository.fetchAllTracks]) après les
/// écritures de la passe, jamais via `libraryTracksProvider.future` — ce
/// dernier renvoie la dernière émission du flux Drift, émise de façon
/// asynchrone après chaque écriture : un morceau tout juste enrichi pouvait y
/// paraître encore "À enrichir" et être retraité aussitôt. Chaque morceau est
/// en outre relu juste avant d'être traité, et sauté s'il n'est plus à
/// enrichir (enrichi entre-temps, changé de catégorie...).
class LibraryEnrichmentRunner {
  LibraryEnrichmentRunner({required TrackRepository repository, required TrackEnricher enricher, this.maxPasses = 3})
      : _repository = repository,
        _enricher = enricher;

  final TrackRepository _repository;
  final TrackEnricher _enricher;
  final int maxPasses;

  Future<List<Track>> pendingTargets() async =>
      (await _repository.fetchAllTracks()).where(trackNeedsEnrichment).toList();

  /// [onProgress] : passe courante (1-based), index du morceau (1-based) et
  /// taille de la passe.
  Future<LibraryEnrichmentResult> run({void Function(int pass, int index, int passSize)? onProgress}) async {
    List<Track> targets = await pendingTargets();
    final int totalTargets = targets.length;
    int totalEnriched = 0;

    for (int pass = 1; pass <= maxPasses && targets.isNotEmpty; pass++) {
      int enrichedThisPass = 0;
      for (int i = 0; i < targets.length; i++) {
        onProgress?.call(pass, i + 1, targets.length);
        final Track? current = await _repository.findById(targets[i].id);
        if (current == null || !trackNeedsEnrichment(current)) continue;

        // `enrichTrack` n'aboutit qu'une fois ses écritures en base (données
        // + statut du circuit-breaker) terminées — attendu ici avant de
        // passer au morceau suivant.
        final bool ok = await _enricher.enrichTrack(
          trackId: current.id,
          title: current.title,
          artists: current.artists,
        );
        if (ok) {
          enrichedThisPass++;
          totalEnriched++;
        }
      }

      if (enrichedThisPass == 0) break; // aucun progrès cette passe : inutile de retenter.
      targets = await pendingTargets();
    }

    return LibraryEnrichmentResult(enriched: totalEnriched, targets: totalTargets);
  }
}
