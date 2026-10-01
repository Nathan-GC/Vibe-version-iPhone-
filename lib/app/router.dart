import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/audio_engine/player_immersive_mode_provider.dart';
import '../core/navigation/shell_route_visibility.dart';
import '../core/platform/app_platform.dart';
import '../core/system/focus_keep_screen_on.dart';
import '../features/discovery/presentation/artist_profile_screen.dart';
import '../features/discovery/presentation/discovery_screen.dart';
import '../features/discovery/presentation/import_screen.dart';
import '../features/library/presentation/artist_fusion_screen.dart';
import '../features/library/presentation/duplicate_tracks_screen.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/library/presentation/orphan_cleanup_screen.dart';
import '../features/onboarding/presentation/onboarding_screen.dart';
import '../features/player/presentation/master_player_screen.dart';
import '../features/playlists/presentation/editor/playlist_editor_screen.dart';
import '../features/playlists/presentation/personal_space_screen.dart';
import '../features/playlists/presentation/vibe_customizer/vibe_customizer_screen.dart';
import '../features/settings/presentation/legal_screen.dart';
import '../features/settings/presentation/settings_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/player',
  routes: [
    GoRoute(path: '/onboarding', builder: (context, state) => const OnboardingScreen()),
    GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
    GoRoute(path: '/settings/legal', builder: (context, state) => const LegalScreen()),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => _TabShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/discovery', builder: (context, state) => const DiscoveryScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/player', builder: (context, state) => const MasterPlayerScreen())],
        ),
        StatefulShellBranch(
          routes: [GoRoute(path: '/space', builder: (context, state) => const PersonalSpaceScreen())],
        ),
      ],
    ),
    GoRoute(
      path: '/discovery/artist/:artistName',
      builder: (context, state) => ArtistProfileScreen(artistName: state.pathParameters['artistName']!),
    ),
    GoRoute(path: '/discovery/import', builder: (context, state) => const ImportScreen()),
    GoRoute(
      path: '/space/playlist/:playlistId/edit',
      builder: (context, state) => PlaylistEditorScreen(playlistId: state.pathParameters['playlistId']!),
    ),
    GoRoute(
      path: '/space/playlist/:playlistId/vibe',
      builder: (context, state) => VibeCustomizerScreen(playlistId: state.pathParameters['playlistId']!),
    ),
    GoRoute(path: '/space/cleanup', builder: (context, state) => const OrphanCleanupScreen()),
    GoRoute(path: '/space/library', builder: (context, state) => const LibraryScreen()),
    GoRoute(path: '/space/library/duplicates', builder: (context, state) => const DuplicateTracksScreen()),
    // Fusion d'artistes : déplacée des Réglages vers la zone d'importation
    // de la Bibliothèque (voir LibraryScreen).
    GoRoute(path: '/space/library/artist-fusion', builder: (context, state) => const ArtistFusionScreen()),
  ],
);

/// Hiérarchie du bouton Retour Android au niveau de la coque de navigation
/// (Ergonomie & Navigation Android, 2.B) : les pages de détail/modales sont
/// des `GoRoute` sœurs poussées sur le Navigator racine au-dessus de ce Shell
/// (voir `/discovery/artist/:artistName`, `/space/playlist/:id/edit`, etc.),
/// donc le pop par défaut de Flutter les referme déjà avant que ce `PopScope`
/// ne soit jamais atteint (2.B.1). Ce qui reste à gérer ici : depuis
/// Découverte/Espace, Retour bascule vers l'onglet Lecteur plutôt que de
/// quitter l'app (2.B.2) ; depuis Lecteur, Retour réduit d'abord le mode
/// immersif du Master Player avant d'autoriser la sortie (2.B.3).
///
/// `canPop` reste TOUJOURS `false` ici, y compris à la racine de l'onglet
/// Lecteur où la sortie de l'app est censée être autorisée : `canPop: true`
/// délègue au pop par défaut de Flutter, qui — vérifié empiriquement sur
/// émulateur (Android "predictive back") — ne fait alors STRICTEMENT RIEN
/// puisqu'il n'y a plus rien à dépiler sur ce Navigator racine (l'app reste
/// bloquée au premier plan, un bouton Retour qui ne répond plus). Appeler
/// explicitement [SystemNavigator.pop] dans ce cas précis est la seule
/// façon fiable de vraiment quitter l'app.
///
/// iOS : pas de bouton Retour système ; le geste de retour (balayage depuis
/// le bord gauche) ne concerne que les pages poussées par-dessus cette coque,
/// jamais sa racine — ce `PopScope` n'y est donc jamais déclenché, et
/// [SystemNavigator.pop] y serait de toute façon ignoré (une app iOS ne se
/// ferme pas elle-même). Le mode système, lui, s'applique à l'identique :
/// `immersiveSticky` masque la barre d'état et l'indicateur d'accueil en
/// Focus, `edgeToEdge` les réaffiche.
/// Persistance des 3 onglets (Robustesse Système, Section 3) :
/// `StatefulShellRoute.indexedStack` (voir plus haut) construit déjà en
/// interne un `IndexedStack` sur les Navigators de chaque branche — les 3
/// onglets restent donc mounted en permanence, jamais détruits/reconstruits
/// à la bascule, `navigationShell` ci-dessous n'a donc pas besoin d'un
/// `IndexedStack` explicite supplémentaire. Le crash `_dependents.isEmpty`
/// observé en QA lors de bascules rapides d'onglets ne venait pas d'ici :
/// root-cause identifiée dans `MasterPlayerScreen` (voir `_pageViewKey`,
/// `master_player_screen.dart`) — le PageView Player/Queue était recréé à
/// chaque bascule du fond Vibe entre vidéo et fluide, pas par ce Shell.
class _TabShell extends ConsumerWidget {
  const _TabShell({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const int _playerTabIndex = 1;

  /// Bug critique QA ("hybrid Focus mode") : le Timer d'inactivité du Player
  /// (MasterPlayerScreen._PlayerPageState) continue de tourner même quand cet
  /// onglet n'est pas affiché — l'IndexedStack de StatefulShellRoute le garde
  /// monté. Point d'entrée UNIQUE pour (ré)appliquer le mode système, appelé
  /// EXPLICITEMENT à chaque endroit qui change soit l'onglet actif
  /// (`goBranch`, bouton Retour) soit le mode immersif lui-même — plutôt que
  /// de compter uniquement sur une reconstruction implicite de `build()`
  /// (retest QA : toujours désynchronisé sur émulateur avec cette seule
  /// approche, la cadence exacte de reconstruction de `_TabShell` au
  /// changement d'onglet dépendant de détails internes de go_router hors de
  /// notre contrôle). `build()` en garde tout de même un appel de secours
  /// (idempotent côté Android) pour couvrir tout appelant qui aurait été
  /// oublié.
  static void _syncSystemUiMode({required bool onPlayerTab, required bool isImmersive}) {
    SystemChrome.setEnabledSystemUIMode(
      onPlayerTab && isImmersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isImmersive = ref.watch(playerImmersiveModeProvider);
    // Maintient l'écran allumé pendant le mode Focus (hors économie
    // d'énergie) — lu ici pour que le contrôleur vive aussi longtemps que la
    // coque, voir FocusKeepScreenOnController.
    ref.watch(focusKeepScreenOnProvider);
    final bool onPlayerTab = navigationShell.currentIndex == _playerTabIndex;
    // Retest QA (61b5cf1) : barre d'état masquée DANS les Paramètres. Les
    // sous-pages (/settings, fiche artiste...) sont poussées sur le Navigator
    // racine par-dessus cette coque, sans changer `currentIndex` : "onglet
    // Lecteur" ne veut donc pas dire "Lecteur affiché". `isCurrentOf` crée
    // une dépendance — cette coque est reconstruite (et le mode système
    // réappliqué, Déclencheur 2) à chaque ouverture/fermeture de sous-page.
    final bool shellIsCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final bool playerDisplayed = onPlayerTab && shellIsCurrent;

    // Déclencheur 1 : le mode immersif change SANS changement d'onglet
    // (entrée automatique après inactivité pendant qu'on est déjà sur
    // Lecteur, ou sortie par tap) — réagit précisément à ce changement de
    // valeur plutôt que d'attendre la prochaine reconstruction.
    ref.listen<bool>(playerImmersiveModeProvider, (previous, next) {
      _syncSystemUiMode(
        onPlayerTab: navigationShell.currentIndex == _playerTabIndex && shellIsCurrent,
        isImmersive: next,
      );
    });

    // Déclencheur 2 (filet de sécurité) : réapplique aussi le mode courant à
    // chaque reconstruction de la coque, au cas où go_router en déclencherait
    // une sans que les déclencheurs explicites ci-dessous n'aient encore agi.
    _syncSystemUiMode(onPlayerTab: playerDisplayed, isImmersive: isImmersive);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (!onPlayerTab) {
          // Jamais de retour direct en Focus (voir onDestinationSelected).
          if (ref.read(playerImmersiveModeProvider)) {
            ref.read(playerImmersiveModeProvider.notifier).set(false);
          }
          navigationShell.goBranch(_playerTabIndex);
          // Déclencheur 3 : retour vers l'onglet Lecteur depuis le bouton
          // Retour Android — réapplique immédiatement plutôt que de compter
          // sur une reconstruction ultérieure de `_TabShell`.
          _syncSystemUiMode(onPlayerTab: true, isImmersive: false);
          return;
        }
        if (isImmersive) {
          ref.read(playerImmersiveModeProvider.notifier).set(false);
          _syncSystemUiMode(onPlayerTab: true, isImmersive: false);
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        // Publie `shellIsCurrent` aux onglets : le Lecteur s'en sert pour
        // annuler son Timer de Focus dès qu'une sous-page le recouvre.
        body: ShellRouteVisibility(isCurrent: shellIsCurrent, child: navigationShell),
        // Bug régression (Focus Mode) : la barre de navigation restait
        // visible par-dessus le canevas noir du mode immersif — seuls les
        // contrôles PROPRES au Player réagissaient à `isImmersive`, cette
        // coque de navigation (racine, partagée par les 3 onglets) n'en
        // tenait aucun compte. Repliée en hauteur (AnimatedSize) plutôt que
        // simplement masquée d'un coup, avec la même durée que le fondu des
        // contrôles du Player (`kImmersiveTransitionDuration`) pour que les
        // deux transitionnent ensemble. Seulement quand on est SUR l'onglet
        // Lecteur : le minuteur d'inactivité peut activer `isImmersive`
        // pendant que Découverte/Espace est au premier plan (voir
        // _syncSystemUiMode) — la barre de navigation de ces onglets ne doit
        // jamais disparaître dans ce cas.
        bottomNavigationBar: AnimatedSize(
          duration: kImmersiveTransitionDuration,
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: (onPlayerTab && isImmersive)
              ? const SizedBox.shrink()
              : SafeArea(
                  // iOS : la NavigationBar gère elle-même la zone de la barre
                  // d'accueil (SafeArea interne) — sans ce SafeArea externe,
                  // son fond se prolonge sous l'indicateur d'accueil comme une
                  // barre d'onglets native, au lieu d'y laisser une bande du
                  // fond de l'écran. Android : inchangé.
                  bottom: !AppPlatform.isIOS,
                  child: NavigationBar(
                    selectedIndex: navigationShell.currentIndex,
                    onDestinationSelected: (index) {
                      // Quitter l'onglet Lecteur sort toujours du Focus : le
                      // retour sur le Lecteur ne doit jamais réafficher un
                      // mode Focus resté actif en arrière-plan. Le Timer
                      // d'inactivité, lui, est annulé côté `_PlayerPageState`
                      // (écoute du routerDelegate, master_player_screen.dart).
                      if (index != _playerTabIndex && ref.read(playerImmersiveModeProvider)) {
                        ref.read(playerImmersiveModeProvider.notifier).set(false);
                      }
                      navigationShell.goBranch(index);
                      // Déclencheur 4 : bascule d'onglet via la barre de
                      // navigation — le point d'entrée le plus courant pour
                      // "revenir sur l'onglet Lecteur en mode Focus" (retest
                      // QA), réappliqué explicitement ici plutôt que supposé
                      // couvert par une reconstruction implicite de `_TabShell`.
                      _syncSystemUiMode(
                        onPlayerTab: index == _playerTabIndex,
                        isImmersive: index == _playerTabIndex && ref.read(playerImmersiveModeProvider),
                      );
                    },
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.explore_outlined),
                        selectedIcon: Icon(Icons.explore),
                        label: 'Découverte',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.play_circle_outline),
                        selectedIcon: Icon(Icons.play_circle),
                        label: 'Lecteur',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.library_music_outlined),
                        selectedIcon: Icon(Icons.library_music),
                        label: 'Espace',
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
