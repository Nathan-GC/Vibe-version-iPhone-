import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_rescan_providers.dart';
import '../data/library_rescan_service.dart';

/// Bannière discrète affichée en haut de la Bibliothèque pendant le nouveau scan
/// des métadonnées (voir [LibraryRescanService]) : « Mise à jour des
/// métadonnées : 120 / 470 » + barre de progression. Invisible hors passe.
class LibraryRescanBanner extends ConsumerWidget {
  const LibraryRescanBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RescanProgress? progress = ref.watch(libraryRescanProgressProvider);
    if (progress == null) return const SizedBox.shrink();

    final TextTheme textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Semantics(
        // Lu d'un bloc et annoncé quand il change, sans que le lecteur d'écran
        // ne lise séparément le texte et la barre.
        label: 'Mise à jour des métadonnées : ${progress.done} titres sur ${progress.total}',
        liveRegion: true,
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mise à jour des métadonnées : ${progress.done} / ${progress.total}', style: textTheme.bodySmall),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: progress.total == 0 ? null : progress.done / progress.total),
          ],
        ),
      ),
    );
  }
}
