import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/networking/metadata_api_client/metadata_api_client.dart';
import '../../../core/storage/database/database_provider.dart';
import '../domain/autocomplete_suggestion.dart';
import 'autocomplete_repository.dart';

final Provider<AutocompleteRepository> autocompleteRepositoryProvider = Provider<AutocompleteRepository>((ref) {
  return AutocompleteRepository(ref.watch(appDatabaseProvider), MetadataApiClient());
});

/// Texte tapé en direct, à chaque frappe — pilote seulement l'affichage
/// (ouvrir/fermer le panneau) ; la requête réseau, elle, attend le texte
/// débouncé ci-dessous.
class LiveQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final NotifierProvider<LiveQuery, String> liveQueryProvider = NotifierProvider<LiveQuery, String>(LiveQuery.new);

/// Texte débouncé (300ms d'inactivité) écrit par un `Timer` géré dans
/// `_DiscoveryScreenState` — c'est cette valeur, pas `liveQueryProvider`, qui
/// déclenche la requête de suggestions.
class DebouncedAutocompleteQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final NotifierProvider<DebouncedAutocompleteQuery, String> debouncedAutocompleteQueryProvider =
    NotifierProvider<DebouncedAutocompleteQuery, String>(DebouncedAutocompleteQuery.new);

/// Suggestions d'autocomplétion pour le texte débouncé courant. `autoDispose`
/// recrée ce provider à chaque changement de texte — l'ancienne instance est
/// alors disposée, ce qui annule son `CancelToken` Dio encore en vol (voir
/// `ref.onDispose` ci-dessous) : la réponse obsolète ne peut jamais s'afficher
/// après une réponse plus récente.
final autocompleteSuggestionsProvider = FutureProvider.autoDispose<List<AutocompleteSuggestion>>((ref) async {
  final String query = ref.watch(debouncedAutocompleteQueryProvider);
  if (query.trim().length < 2) return const [];

  final CancelToken cancelToken = CancelToken();
  ref.onDispose(() => cancelToken.cancel());

  return ref.watch(autocompleteRepositoryProvider).suggest(query, cancelToken: cancelToken);
});
