import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/purge/orphan_track.dart';
import '../../../core/purge/purge_providers.dart';

final FutureProvider<List<OrphanTrack>> orphanTracksProvider = FutureProvider<List<OrphanTrack>>((ref) {
  return ref.watch(orphanDetectorServiceProvider).findOrphans();
});

/// `tracks.id` cochés dans la vue de nettoyage (Étape 7.2).
class SelectedOrphanIds extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  void set(Set<String> ids) => state = ids;
}

final NotifierProvider<SelectedOrphanIds, Set<String>> selectedOrphanIdsProvider =
    NotifierProvider<SelectedOrphanIds, Set<String>>(SelectedOrphanIds.new);
