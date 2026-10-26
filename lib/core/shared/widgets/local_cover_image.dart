import 'dart:io';

import 'package:flutter/widgets.dart';

/// Pochette d'un titre LOCAL, jamais via le réseau (local-first, RGPD) :
/// une URL http(s) restée en base (pas encore rapatriée sur l'appareil)
/// fuirait vers un tiers (Apple, Cover Art Archive) à chaque affichage,
/// interrupteur d'enrichissement OFF compris. Elle est donc traitée comme
/// « pas de pochette » (`null`) et l'appelant retombe sur son repli visuel.
ImageProvider? localCoverImage(String path) {
  if (path.isEmpty || isRemoteCoverPath(path)) return null;
  return FileImage(File(path));
}

/// `true` pour une URL http(s) (valeur de `Tracks.coverArtPath` non rapatriée).
bool isRemoteCoverPath(String path) => path.startsWith('http://') || path.startsWith('https://');
