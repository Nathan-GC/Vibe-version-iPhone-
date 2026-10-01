import 'package:file_picker/file_picker.dart';

/// Vide le cache de `file_picker` après un import audio : sur Android, le
/// plugin copie chaque fichier choisi dans le cache de l'app avant d'en
/// renvoyer le chemin. L'import (StorageManagerService) en refait une copie
/// dans le dossier de l'app — sans ce nettoyage, chaque MP3 importé restait
/// en double dans le cache jusqu'à ce qu'Android décide de le purger. Même
/// situation sur iOS : le sélecteur de documents y livre une copie
/// (`asCopy`) dans le dossier temporaire de l'app, vidée de la même façon.
///
/// À appeler une fois l'import TERMINÉ (le chemin renvoyé par le plugin
/// n'est plus lisible ensuite). Au mieux : un échec (plateforme sans cache,
/// fichier verrouillé) ne doit jamais faire échouer l'import lui-même.
Future<void> clearPickedFileCache() async {
  try {
    await FilePicker.clearTemporaryFiles();
  } catch (_) {
    // Nettoyage opportuniste — le cache reste de toute façon purgeable par
    // le système.
  }
}
