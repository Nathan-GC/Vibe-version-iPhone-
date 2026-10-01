import '../../../core/storage/database/app_database.dart';
import '../domain/artist_filter.dart';
import '../domain/artist_sort.dart';
import '../domain/top_artist_playlist.dart';

abstract class ArtistRepository {
  /// Tous les morceaux crédités à [artistName] (y compris en featuring),
  /// filtrés et triés selon les contrôles de la vue Tab 1.
  Stream<List<Track>> watchArtistTracks(String artistName, {required ArtistFilter filter, required ArtistSort sort});

  /// Noms distincts de tous les artistes crédités sur au moins un morceau
  /// local, triés alphabétiquement — alimente le sélecteur "Ajouter par
  /// artiste" de l'éditeur de playlist (Feuille de route pt.9).
  Future<List<String>> fetchAllArtistNames();

  /// Les [limit] artistes les plus présents dans la bibliothèque locale
  /// (Section 5.2, carrousel "Suggestions d'artistes" de Découverte) —
  /// crédits primaires et featurings comptés indifféremment (voir
  /// `TrackArtists`), pochette du morceau le plus écouté de chacun.
  Future<List<TopArtistPlaylist>> fetchTopArtistPlaylists({int limit = 7});

  /// Tous les artistes locaux avec leur nombre de morceaux (crédits
  /// primaires et featurings confondus), triés alphabétiquement — alimente
  /// l'écran de Fusion Manuelle (Section 4). `coverArtPath` toujours `null` :
  /// cet écran n'affiche pas de pochette, contrairement à
  /// [fetchTopArtistPlaylists].
  Future<List<TopArtistPlaylist>> fetchAllArtistsWithTrackCount();
}
