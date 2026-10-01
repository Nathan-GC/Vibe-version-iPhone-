/// Les URLs de vignette renvoyées par l'API iTunes Search se terminent par
/// "100x100bb.jpg" ; remplacer ce segment de taille suffit à demander une
/// résolution plus grande (servie directement par Apple, jusqu'à ~3000x3000
/// selon l'asset source) — aucun second appel réseau n'est nécessaire.
class ItunesArtwork {
  const ItunesArtwork._();

  static String upgrade(String artworkUrl100, {int size = 1000}) {
    return artworkUrl100.replaceFirst('100x100', '${size}x$size');
  }
}
