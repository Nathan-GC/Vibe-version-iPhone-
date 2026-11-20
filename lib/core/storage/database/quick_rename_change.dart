/// Un renommage à appliquer par `TrackRepository.applyQuickRename`.
///
/// [artists] est déjà calculé et normalisé par l'appelant (artiste principal
/// en premier, featurings ensuite) : le dépôt l'écrit tel quel, sans refaire
/// de découpage ni de nettoyage.
class QuickRenameChange {
  const QuickRenameChange({required this.trackId, required this.title, required this.artists});

  final String trackId;
  final String title;
  final List<String> artists;
}
