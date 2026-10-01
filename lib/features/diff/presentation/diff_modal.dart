import 'package:flutter/material.dart';

import '../../../core/playlist_manifest/manifest_track_ref.dart';
import '../domain/diff_result.dart';

/// Modal de comparaison côte-à-côte (Étape 6) : +Ajoutés en vert, -Retirés en
/// rouge, avec bouton "Accepter la mise à jour".
class DiffModal extends StatelessWidget {
  const DiffModal({super.key, required this.diff, required this.onAccept});

  final DiffResult diff;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Mise à jour disponible (v${diff.localVersion} → v${diff.incomingVersion})'),
      content: SizedBox(
        width: double.maxFinite,
        child: diff.hasChanges
            ? SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _DiffColumn(title: '+ Ajoutés', color: Colors.green, tracks: diff.added)),
                    const SizedBox(width: 12),
                    Expanded(child: _DiffColumn(title: '- Retirés', color: Colors.red, tracks: diff.removed)),
                  ],
                ),
              )
            : const Text('Aucun changement de morceaux, seule la version a été mise à jour.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Annuler')),
        FilledButton(
          onPressed: () {
            onAccept();
            Navigator.of(context).pop();
          },
          child: const Text('Accepter la mise à jour'),
        ),
      ],
    );
  }
}

class _DiffColumn extends StatelessWidget {
  const _DiffColumn({required this.title, required this.color, required this.tracks});

  final String title;
  final Color color;
  final List<ManifestTrackRef> tracks;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        if (tracks.isEmpty) const Text('—', style: TextStyle(color: Colors.grey)),
        ...tracks.map(
          (t) => Text(
            '${t.title} — ${t.artist}',
            style: TextStyle(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
