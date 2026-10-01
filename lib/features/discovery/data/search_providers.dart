import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/networking/metadata_api_client/metadata_api_client.dart';
import '../../../core/storage/database/database_provider.dart';
import '../domain/search_result.dart';
import 'search_repository.dart';

final Provider<SearchRepository> searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return SearchRepository(ref.watch(appDatabaseProvider), MetadataApiClient());
});

/// Requête actuellement soumise par l'utilisateur (mise à jour à la validation).
class SearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final NotifierProvider<SearchQuery, String> searchQueryProvider =
    NotifierProvider<SearchQuery, String>(SearchQuery.new);

final FutureProvider<List<SearchResult>> searchResultsProvider = FutureProvider<List<SearchResult>>((ref) {
  final String query = ref.watch(searchQueryProvider);
  return ref.watch(searchRepositoryProvider).search(query);
});
