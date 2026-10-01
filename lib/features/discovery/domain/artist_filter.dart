/// `collaborations` = morceaux où `artists.length > 1`.
enum ArtistFilter { all, albums, singlesEps, collaborations }

extension ArtistFilterLabel on ArtistFilter {
  String get label => switch (this) {
        ArtistFilter.all => 'Tout',
        ArtistFilter.albums => 'Albums',
        ArtistFilter.singlesEps => 'Singles / EPs',
        ArtistFilter.collaborations => 'Collaborations',
      };
}
