enum ArtistSort { chronological, popularity, alphabetical }

extension ArtistSortLabel on ArtistSort {
  String get label => switch (this) {
        ArtistSort.chronological => 'Chronologique',
        ArtistSort.popularity => 'Popularité',
        ArtistSort.alphabetical => 'Alphabétique',
      };
}
