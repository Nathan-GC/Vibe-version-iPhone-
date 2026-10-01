import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/database/track_repository.dart';
import '../../../core/storage/scanner/library_scan_service.dart';
import '../../../core/storage/storage_manager/storage_manager_service.dart';
import 'missing_track_resolver.dart';

final Provider<MissingTrackResolver> missingTrackResolverProvider = Provider<MissingTrackResolver>((ref) {
  return MissingTrackResolver(StorageManagerService(), LibraryScanService(), ref.watch(trackRepositoryProvider));
});
