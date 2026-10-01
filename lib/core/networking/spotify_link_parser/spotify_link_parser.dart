class SpotifyLink {
  const SpotifyLink({required this.type, required this.id});

  final String type;
  final String id;
}

/// Extrait type/id depuis un lien de partage Spotify (open.spotify.com/...).
class SpotifyLinkParser {
  static final RegExp _pattern = RegExp(r'open\.spotify\.com/(track|playlist|album)/([a-zA-Z0-9]+)');

  SpotifyLink? parse(String url) {
    final Match? match = _pattern.firstMatch(url);
    if (match == null) return null;
    return SpotifyLink(type: match.group(1)!, id: match.group(2)!);
  }
}
