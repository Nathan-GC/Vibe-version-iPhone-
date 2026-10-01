import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart' show getApplicationSupportDirectory;

import '../../platform/app_platform.dart';
import '../../theme/vibe_engine/vibe_engine.dart';

part 'app_database.g.dart';

/// Sérialise les colonnes `json text array` (artists, tags, bg_colors) en JSON.
class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return const [];
    return (jsonDecode(fromDb) as List<dynamic>).cast<String>();
  }

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

/// Mappe `playlists.vibe_style` ('minimal' | 'neon' | 'glassmorphism' | 'retro' | 'organic' | 'oled').
class VibePresetConverter extends TypeConverter<VibePreset, String> {
  const VibePresetConverter();

  @override
  VibePreset fromSql(String fromDb) {
    return VibePreset.values.firstWhere((preset) => preset.name == fromDb, orElse: () => VibePreset.minimal);
  }

  @override
  String toSql(VibePreset value) => value.name;
}

/// Mappe `playlists.custom_effect` — voir [VibeCustomEffect].
class VibeCustomEffectConverter extends TypeConverter<VibeCustomEffect, String> {
  const VibeCustomEffectConverter();

  @override
  VibeCustomEffect fromSql(String fromDb) {
    return VibeCustomEffect.values.firstWhere((effect) => effect.name == fromDb, orElse: () => VibeCustomEffect.fluid);
  }

  @override
  String toSql(VibeCustomEffect value) => value.name;
}

/// Statut du circuit-breaker d'enrichissement automatique ET provenance de
/// l'enrichissement (Section 1 — voir `Tracks.enrichmentStatus`,
/// `TrackAutoEnricher`, `MusicBrainzAutoEnricher`, `TrackRepository.
/// shouldAttemptEnrichment`/`recordEnrichmentOutcome`/`updateMetadata`) :
///  - [pending] : éligible aux prochaines tentatives auto (post-import,
///    "Enrichir tout").
///  - [enrichedAutoItunes] / [enrichedAutoMusicBrainz] : enrichi automatiquement
///    avec confiance par la source indiquée, plus besoin de retenter.
///  - [enrichedManualEdit] : Titre/Artiste/Album saisis à la main dans
///    l'éditeur, sans passer par une suggestion réseau.
///  - [enrichedManualItunes] / [enrichedManualMusicBrainz] : suggestion de
///    l'onglet réseau correspondant validée telle quelle dans l'éditeur.
///  - [needsManualReview] : `maxEnrichmentAttempts` tentatives auto épuisées
///    sans correspondance fiable — ne repasse plus jamais dans la file
///    automatique et s'affiche sous "À enrichir manuellement" (jusqu'à une
///    correction manuelle, voir `TrackRepository.updateMetadata`, qui
///    réinitialise ce statut).
///  - [requiresReview] : titre/artiste trop ambigus dès le nom de fichier
///    (`requiresUserReview`) pour même tenter une requête API — évite de
///    gaspiller des appels réseau sur un morceau qu'une confirmation humaine
///    va de toute façon changer.
///
/// Stocké en texte (nom de la valeur) : une valeur retirée doit être
/// remappée par une migration (voir `from < 14` et `from < 15`), sans quoi
/// [EnrichmentStatusConverter.fromSql] la ferait retomber sur `pending`.
enum EnrichmentStatus {
  pending,
  enrichedAutoItunes,
  enrichedAutoMusicBrainz,
  enrichedManualEdit,
  enrichedManualItunes,
  enrichedManualMusicBrainz,
  needsManualReview,
  requiresReview,
}

class EnrichmentStatusConverter extends TypeConverter<EnrichmentStatus, String> {
  const EnrichmentStatusConverter();

  @override
  EnrichmentStatus fromSql(String fromDb) {
    return EnrichmentStatus.values
        .firstWhere((status) => status.name == fromDb, orElse: () => EnrichmentStatus.pending);
  }

  @override
  String toSql(EnrichmentStatus value) => value.name;
}

/// `id` = sanitized key (title_slug + album_slug + primary_artist_slug), voir
/// core/identity/track_key.dart. `artists` conserve tous les featurings en
/// tableau JSON, jamais aplatis en string ("Daft Punk feat. Justice" interdit).
class Tracks extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get album => text()();
  IntColumn get releaseYear => integer().withDefault(const Constant(0))();
  TextColumn get artists => text().map(const StringListConverter())();
  IntColumn get durationSeconds => integer()();
  IntColumn get bpm => integer().withDefault(const Constant(120))();
  IntColumn get trimStartMs => integer().withDefault(const Constant(0))();
  IntColumn get trimEndMs => integer().withDefault(const Constant(0))();
  TextColumn get filePath => text().unique()();
  TextColumn get coverArtPath => text().withDefault(const Constant(''))();
  TextColumn get tags => text().map(const StringListConverter()).withDefault(const Constant('[]'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // true quand l'extraction ID3 a échoué et que le repli sur le nom de fichier
  // (FilenameSanitizer) est resté ambigu — voir LibraryScanService (Étape 2).
  BoolColumn get requiresUserReview => boolean().withDefault(const Constant(false))();
  // Nombre de lectures locales, utilisé par le tri "Popularité" (Étape 3).
  IntColumn get playCount => integer().withDefault(const Constant(0))();
  // Dernière lecture, affichée dans la vue de purge des orphelins (Étape 7).
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();
  // Empreinte de fichier pour le scan incrémental (import zero-click, Étape 8) :
  // `lastModifiedEpochMs` (mtime du fichier au dernier scan) permet un test de
  // changement quasi instantané (pas de lecture du contenu) ; `fileHash`
  // (SHA-256, calculé seulement quand mtime/taille diffèrent) confirme qu'un
  // contenu a réellement changé avant de relancer extraction ID3 + trim.
  IntColumn get lastModifiedEpochMs => integer().withDefault(const Constant(0))();
  TextColumn get fileHash => text().nullable()();
  // Numéro de piste/disque officiel (iTunes `trackNumber`/`discNumber`) —
  // alimenté par l'enrichissement (Étape "audit iTunes"), 0 si inconnu.
  // Permet de trier les morceaux d'un album dans leur ordre officiel plutôt
  // que par ordre d'ajout à la bibliothèque (voir AlbumGroup).
  IntColumn get trackNumber => integer().withDefault(const Constant(0))();
  IntColumn get discNumber => integer().withDefault(const Constant(0))();
  IntColumn get trackCount => integer().withDefault(const Constant(0))();
  // Circuit-breaker de l'enrichissement automatique — voir [EnrichmentStatus].
  // Un morceau nouvellement scanné démarre à `requiresReview` s'il est déjà
  // `requiresUserReview` (nom de fichier ambigu), sinon `pending`.
  IntColumn get enrichmentAttempts => integer().withDefault(const Constant(0))();
  TextColumn get enrichmentStatus =>
      text().map(const EnrichmentStatusConverter()).withDefault(const Constant('pending'))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Index dérivé de `tracks.artists` : une ligne par artiste crédité sur un morceau.
/// Permet de retrouver tous les morceaux d'un artiste (y compris en featuring)
/// sans dupliquer le fichier physique ni scanner le JSON à chaque requête.
/// Tenu à jour par TrackRepository.upsertTrack à chaque insert/update de track.
@TableIndex(name: 'idx_track_artists_artist_name', columns: {#artistName})
class TrackArtists extends Table {
  TextColumn get trackId => text().references(Tracks, #id)();
  TextColumn get artistName => text()();
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {trackId, artistName};
}

/// `original_creator` n'est renseigné que pour les playlists forkées (voir Étape 6),
/// auquel cas l'UI affiche "Inspired by @original_creator".
class Playlists extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get originalCreator => text().nullable()();
  // `manifest.id` du JSON importé au moment du fork — distinct de `id` (qui,
  // lui, inclut un suffixe `-fork-<timestamp>` unique par copie locale). Sert
  // à reconnaître qu'un JSON réimporté est une mise à jour d'une playlist déjà
  // forkée ici plutôt que de créer un doublon (voir PlaylistManifestService).
  TextColumn get sourceManifestId => text().nullable()();
  IntColumn get version => integer().withDefault(const Constant(1))();
  TextColumn get tags => text().map(const StringListConverter()).withDefault(const Constant('[]'))();
  TextColumn get vibeStyle => text().map(const VibePresetConverter()).withDefault(const Constant('minimal'))();
  // Pour `vibeStyle == VibePreset.custom` : couleurs choisies dans le Vibe
  // Creator (format hex ARGB, ex. "FFFF00E5"), voir PlaylistVibeResolver.
  TextColumn get bgColors => text().map(const StringListConverter()).withDefault(const Constant('[]'))();
  // Image de fond importée via image_picker pour la Vibe personnalisée
  // (chemin local sous Music/AppFolder/vibe_backgrounds/) — vide si non définie.
  TextColumn get customBackgroundImagePath => text().withDefault(const Constant(''))();
  // Couleur d'accentuation choisie explicitement dans le Vibe Creator (format
  // hex ARGB) — distincte des couleurs de `bgColors` (dégradé de fond). Vide :
  // repli sur la dernière couleur du dégradé (comportement historique).
  TextColumn get customAccentColor => text().withDefault(const Constant(''))();
  // Pochette personnalisée (Design System — carte PlaylistCard), distincte de
  // `customBackgroundImagePath` (fond plein écran du Player, Vibe Creator) :
  // chemin local sous Music/AppFolder/playlist_covers/, vide si non définie
  // — auquel cas l'UI compose un visuel 2x2 des 4 premières pochettes de la
  // playlist (voir PlaylistCoverImage), ou un repli générique Vibe si vide.
  TextColumn get coverImagePath => text().withDefault(const Constant(''))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  // Effet de fond du Vibe Creator (Section 4.2) pour `vibeStyle == custom`
  // uniquement — voir [VibeCustomEffect]. Sans effet pour les autres presets.
  TextColumn get customEffect => text().map(const VibeCustomEffectConverter()).withDefault(const Constant('fluid'))();
  // Vidéo de fond personnalisée (Section 4.3, `vibeStyle == custom`) —
  // chemin local sous Music/AppFolder/vibe_backgrounds/, vide si non définie.
  // Remplace entièrement le rendu shader/dégradé/image du Master Player
  // quand renseignée (voir MasterPlayerScreen) : mutuellement exclusive avec
  // `customEffect`/`customBackgroundImagePath`, jamais superposée.
  TextColumn get customBackgroundVideoPath => text().withDefault(const Constant(''))();
  // Pochette masquable dans le Player ("Afficher la pochette", proposé sur
  // toutes les Vibes depuis la v1.2 — voir VibeCustomizerScreen) : visible
  // par défaut (`true`).
  BoolColumn get showCoverImage => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// `is_pending_placement` : true tant qu'un morceau ajouté (import, fork, suggestion)
/// n'a pas encore été positionné manuellement dans l'éditeur drag-and-drop (Étape 5).
@DataClassName('PlaylistTrack')
class PlaylistTracks extends Table {
  TextColumn get playlistId => text().references(Playlists, #id)();
  TextColumn get trackId => text().references(Tracks, #id)();
  IntColumn get position => integer()();
  BoolColumn get isPendingPlacement => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {playlistId, trackId};
}

/// Titre d'une playlist importée (manifeste JSON) sans morceau local associé
/// — affiché "grisé" dans la playlist, jamais lu (seuls les
/// [PlaylistTracks] sont joués, voir `fetchOrderedTracks`).
///
/// Table distincte de [PlaylistTracks] plutôt qu'une ligne de celle-ci : sa
/// clé étrangère `track_id -> tracks.id` impose un morceau réellement présent
/// en bibliothèque. [position] partage l'espace de numérotation de
/// `playlist_tracks.position` pour la même playlist : l'ordre d'affichage
/// fusionne les deux tables, le titre grisé garde ainsi sa place d'origine.
///
/// Dégrisage automatique : [TrackRepository.upsertTrack] convertit la ligne
/// en [PlaylistTracks] (même position) dès qu'un morceau importé correspond
/// à [sanitizedKey] ou à [matchKey] (titre + artiste normalisés).
@DataClassName('PlaylistMissingTrack')
class PlaylistMissingTracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get playlistId => text().references(Playlists, #id)();
  IntColumn get position => integer()();
  TextColumn get title => text()();
  TextColumn get artist => text()();
  TextColumn get album => text().withDefault(const Constant(''))();
  // `buildSanitizedKey` du manifeste (titre + album + artiste principal).
  TextColumn get sanitizedKey => text()();
  // `buildTrackMatchKey` (titre + artiste principal normalisés, sans album).
  TextColumn get matchKey => text()();
}

@DriftDatabase(tables: [Tracks, Playlists, PlaylistTracks, TrackArtists, PlaylistMissingTracks])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 16;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) => m.createAll(),
        onUpgrade: (Migrator m, int from, int to) async {
          if (from < 2) {
            await m.addColumn(playlists, playlists.sourceManifestId);
          }
          if (from < 3) {
            await m.addColumn(tracks, tracks.lastModifiedEpochMs);
            await m.addColumn(tracks, tracks.fileHash);
          }
          if (from < 4) {
            await m.addColumn(playlists, playlists.customBackgroundImagePath);
          }
          if (from < 5) {
            await m.addColumn(playlists, playlists.customAccentColor);
          }
          if (from < 6) {
            await m.addColumn(tracks, tracks.trackNumber);
            await m.addColumn(tracks, tracks.discNumber);
            await m.addColumn(tracks, tracks.trackCount);
          }
          if (from < 7) {
            await m.addColumn(playlists, playlists.coverImagePath);
          }
          if (from < 8) {
            await m.addColumn(tracks, tracks.enrichmentAttempts);
            await m.addColumn(tracks, tracks.enrichmentStatus);
            // Les morceaux déjà en base avant cette version n'ont jamais eu de
            // statut : les tracks encore "à vérifier" démarrent directement en
            // `requiresReview` (comme un nouveau scan) pour ne pas gaspiller de
            // requêtes API dessus tant qu'un humain n'a pas confirmé
            // Titre/Artiste.
            await (update(tracks)..where((t) => t.requiresUserReview.equals(true))).write(
              const TracksCompanion(enrichmentStatus: Value(EnrichmentStatus.requiresReview)),
            );
          }
          if (from < 9) {
            await m.addColumn(playlists, playlists.customEffect);
            await m.addColumn(playlists, playlists.customBackgroundVideoPath);
          }
          if (from < 10) {
            // Éclatement de [EnrichmentStatus] (Section 1) : les anciennes
            // valeurs texte 'success'/'failedPermanently' n'existent plus
            // côté Dart (EnrichmentStatusConverter.fromSql retomberait
            // silencieusement sur `pending`, perdant tout historique
            // d'enrichissement) — remappées en SQL brut vers leurs
            // équivalents le plus proche avant que l'app ne relise ces
            // lignes : la provenance exacte (iTunes vs YouTube) d'un ancien
            // `success` n'est pas connue, iTunes (source par défaut) sert de
            // repli raisonnable.
            await customStatement(
              "UPDATE tracks SET enrichment_status = 'enrichedAutoItunes' WHERE enrichment_status = 'success'",
            );
            await customStatement(
              "UPDATE tracks SET enrichment_status = 'needsManualReview' WHERE enrichment_status = 'failedPermanently'",
            );
          }
          if (from < 11) {
            await m.addColumn(playlists, playlists.showCoverImage);
          }
          if (from < 12) {
            await m.createTable(playlistMissingTracks);
          }
          if (from < 13) {
            // "Cacher la cover" disponible sur toutes les Vibes (v1.2) :
            // jusqu'ici `show_cover_image` était ignoré (pochette toujours
            // affichée) pour les presets sans bouton. Une valeur `false`
            // héritée d'un ancien passage sur Retro/Neon/New OLED y
            // masquerait soudain la pochette à la mise à jour — remise à
            // `true` pour conserver exactement le rendu que l'utilisateur
            // voyait avant.
            await customStatement(
              "UPDATE playlists SET show_cover_image = 1 WHERE vibe_style IN ('minimal', 'glassmorphism', 'organic', 'oled')",
            );
          }
          if (from < 14) {
            // Recette QA v1.2 (choix 1-A) : un morceau placé à la main dans
            // "Renommé et enrichi" relève désormais de la sous-catégorie
            // "Enrichi totalement manuellement" (`enrichedManualEdit`) —
            // l'ancien statut dédié `markedEnrichedManually` (build de
            // recette 1.2.0+4) n'existe plus côté Dart.
            await customStatement(
              "UPDATE tracks SET enrichment_status = 'enrichedManualEdit' WHERE enrichment_status = 'markedEnrichedManually'",
            );
          }
          if (from < 15) {
            // v1.3 : la source YouTube est remplacée 1 pour 1 par MusicBrainz
            // (sous-catégories de provenance renommées en conséquence).
            await customStatement(
              "UPDATE tracks SET enrichment_status = 'enrichedAutoMusicBrainz' WHERE enrichment_status = 'enrichedAutoYoutube'",
            );
            await customStatement(
              "UPDATE tracks SET enrichment_status = 'enrichedManualMusicBrainz' WHERE enrichment_status = 'enrichedManualYoutube'",
            );
          }
          if (from < 16) {
            // Confidentialité (QA v1.3) : les miniatures YouTube héritées
            // (i.ytimg.com) faisaient encore appeler les serveurs de Google à
            // chaque affichage de pochette. Étape distincte de v15, déjà livrée
            // en 1.3.0+7 : un appareil déjà en v15 ne la rejouerait pas.
            // Pochette vidée ('' = absente : colonne NOT NULL, convention de
            // tous les lecteurs) et morceau remis à enrichir (iTunes puis
            // MusicBrainz), ou laissé "À renommer" s'il l'était. URL distantes
            // seulement : une pochette locale dont le chemin contient
            // "youtube" (nom de fichier du morceau) n'est jamais touchée.
            await customStatement(
              "UPDATE tracks SET cover_art_path = '', enrichment_attempts = 0, "
              "enrichment_status = CASE WHEN requires_user_review = 1 THEN 'requiresReview' ELSE 'pending' END "
              "WHERE cover_art_path LIKE 'http%' AND (cover_art_path LIKE '%ytimg.com%' OR cover_art_path LIKE '%youtube%')",
            );
          }
        },
      );

  /// Android : emplacement par défaut de drift_flutter (inchangé).
  /// iOS : `Library/Application Support` plutôt que le dossier Documents
  /// (défaut de drift_flutter), exposé dans l'app Fichiers
  /// (`UIFileSharingEnabled`) — la base y serait visible, et supprimable ou
  /// écrasable par l'utilisateur. Application Support reste sauvegardé
  /// avec l'appareil et conservé lors des mises à jour.
  static QueryExecutor _openConnection() => driftDatabase(
        name: 'playlist_app',
        native: AppPlatform.isIOS ? const DriftNativeOptions(databaseDirectory: getApplicationSupportDirectory) : null,
      );
}
