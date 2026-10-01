import 'dart:io';

import '../filename_sanitizer/filename_sanitizer.dart';

/// Fichier copié dans /Music/AppFolder/, avec le résultat de sanitization déjà
/// calculé sur le nom de fichier *original* (avant renommage). À réutiliser
/// tel quel pour le repli sans-ID3 du scan — le reparser depuis [file] une
/// fois renommé en `{artist}-{title}.mp3` réintroduirait artificiellement un
/// séparateur "-" que FilenameSanitizer prendrait à tort pour un vrai
/// "Artiste - Titre", annulant le flag `requiresUserReview`.
class ImportedAudioFile {
  const ImportedAudioFile({required this.file, required this.sanitizedFromOriginalName});

  final File file;
  final SanitizedFilename sanitizedFromOriginalName;
}
