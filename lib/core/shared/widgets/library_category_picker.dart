import 'package:flutter/material.dart';

import '../../storage/database/app_database.dart';
import '../../storage/database/library_category.dart';
import '../../storage/database/track_repository.dart';

/// Repère visuel de chaque catégorie — partagé entre les puces de filtre de
/// la Bibliothèque et le sélecteur "Changer de catégorie".
extension LibraryCategoryStyle on LibraryCategory {
  IconData get icon => switch (this) {
        LibraryCategory.toRename => Icons.warning_amber_outlined,
        LibraryCategory.toEnrich => Icons.auto_awesome_outlined,
        LibraryCategory.done => Icons.check_circle_outline,
      };

  Color? get iconColor => switch (this) {
        LibraryCategory.toRename => Colors.amber,
        LibraryCategory.toEnrich => null,
        LibraryCategory.done => Colors.green,
      };

  String get pickerHint => switch (this) {
        LibraryCategory.toRename => 'Titre/Artiste à confirmer — exclu de l\'enrichissement auto',
        LibraryCategory.toEnrich => 'Redevient une cible d\'« Enrichir tout »',
        LibraryCategory.done => 'Plus proposé à l\'enrichissement auto',
      };
}

/// Sélecteur "Changer de catégorie" : renvoie la catégorie tapée — MÊME si
/// c'est la catégorie actuelle ([current]) — ou `null` seulement si
/// l'utilisateur ferme la boîte sans choisir.
///
/// Bogue recette QA 4c : la catégorie actuelle renvoyait `null`, or un titre
/// en "Échec auto" appartient déjà à "À enrichir" — le taper n'appelait donc
/// jamais la réinitialisation. [autoEnrichFailed] adapte le libellé de "À
/// enrichir" pour rendre cette action explicite.
Future<LibraryCategory?> showLibraryCategoryPicker(
  BuildContext context, {
  required LibraryCategory current,
  bool autoEnrichFailed = false,
}) {
  return showDialog<LibraryCategory>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Changer de catégorie'),
      children: [
        for (final category in LibraryCategory.values)
          ListTile(
            leading: Icon(category.icon, color: category.iconColor),
            title: Text(category.label),
            subtitle: Text(
              autoEnrichFailed && category == LibraryCategory.toEnrich
                  ? 'Échec auto : réinitialise les tentatives, redevient une cible d\'« Enrichir tout »'
                  : category.pickerHint,
            ),
            trailing: category == current ? const Icon(Icons.check) : null,
            selected: category == current,
            onTap: () => Navigator.of(context).pop(category),
          ),
      ],
    ),
  );
}

/// Flux complet "Changer de catégorie" pour [track] : sélecteur, écriture
/// ([TrackRepository.forceLibraryCategory]) puis confirmation visuelle.
/// Renvoie la catégorie appliquée, `null` si l'utilisateur a annulé.
///
/// Toujours appliqué, y compris sur la catégorie actuelle : c'est justement
/// ce qui réinitialise un titre en "Échec auto" resté dans "À enrichir"
/// (statut `needsManualReview` + compteur de tentatives remis à zéro).
/// [context] doit rester monté pendant la sélection (appelant : contexte du
/// Navigator, pas celui d'une feuille déjà fermée).
Future<LibraryCategory?> changeTrackLibraryCategory(
  BuildContext context, {
  required TrackRepository repository,
  required Track track,
}) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final LibraryCategory current = libraryCategoryOf(track);
  final bool autoEnrichFailed = track.enrichmentStatus == EnrichmentStatus.needsManualReview;

  final LibraryCategory? picked =
      await showLibraryCategoryPicker(context, current: current, autoEnrichFailed: autoEnrichFailed);
  if (picked == null) return null;

  await repository.forceLibraryCategory(track.id, picked);

  final String message = autoEnrichFailed && picked == LibraryCategory.toEnrich
      ? 'Échec auto réinitialisé : « ${track.title} » redevient éligible à « Enrichir tout »'
      : picked == current
          ? '« ${track.title} » reste dans « ${picked.label} »'
          : '« ${track.title} » déplacé vers « ${picked.label} »';
  messenger.showSnackBar(SnackBar(content: Text(message)));
  return picked;
}
