import 'package:flutter/material.dart';

import '../../storage/database/track_enricher.dart';

/// Choix de la source d'un enrichissement global (Section 2.1) — partagé
/// entre LibraryScreen ("Enrichir tout"/post-import manuel) et
/// OnboardingScreen (scan plein-appareil du premier lancement), toujours
/// affiché une fois par lot plutôt que mélangé au sein d'un même lot. `null`
/// si l'utilisateur annule (voir chaque appelant pour le comportement associé).
Future<EnrichmentSource?> showEnrichmentSourceDialog(BuildContext context) {
  return showDialog<EnrichmentSource>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text("Source d'enrichissement"),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, EnrichmentSource.itunes),
          child: const ListTile(
            leading: Icon(Icons.apple),
            title: Text('API iTunes / Apple Music'),
            subtitle: Text('Pochettes HD, Album/Genre/Année complets'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, EnrichmentSource.musicBrainz),
          child: const ListTile(
            leading: Icon(Icons.library_music_outlined),
            title: Text('MusicBrainz'),
            subtitle: Text('Base musicale ouverte, pochettes Cover Art Archive'),
          ),
        ),
      ],
    ),
  );
}
