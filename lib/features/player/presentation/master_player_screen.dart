import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/animation/tempo_sync/tempo_sync_controller.dart';
import '../../../core/audio_engine/player_controller.dart';
import '../../../core/audio_engine/player_immersive_mode_provider.dart';
import '../../../core/navigation/shell_route_visibility.dart';
import '../../../core/shared/widgets/add_to_playlist_sheet.dart';
import '../../../core/storage/database/app_database.dart';
import '../../../core/theme/global_theme/global_theme.dart';
import '../../../core/theme/vibe_engine/active_vibe_provider.dart';
import '../../../core/theme/vibe_engine/animated_vibe_theme.dart';
import '../../../core/theme/vibe_engine/playlist_vibe_resolver.dart';
import '../../../core/theme/vibe_engine/vibe_engine.dart';
import '../../../core/theme/vibe_engine/vibe_haptic_service.dart';
import '../../playlists/data/playlist_providers.dart';
import '../widgets/album_art_reactive.dart';
import '../widgets/fluid_background.dart';
import '../widgets/like_button.dart';
import '../widgets/progress_slider.dart';
import '../widgets/vibe_video_background.dart';
import 'queue_screen.dart';

/// Tab 2 : swipe horizontal Page 1 (Player) / Page 2 (Queue, voir queue_screen.dart).
class MasterPlayerScreen extends ConsumerStatefulWidget {
  const MasterPlayerScreen({super.key});

  @override
  ConsumerState<MasterPlayerScreen> createState() => _MasterPlayerScreenState();
}

class _MasterPlayerScreenState extends ConsumerState<MasterPlayerScreen> with SingleTickerProviderStateMixin {
  late final TempoSyncController _tempoController = TempoSyncController(vsync: this);

  // Clé stable pour le PageView (Player + Queue) : sans elle, chaque bascule
  // du fond entre `VibeVideoBackground` et `FluidBackground` (types de widget
  // différents) fait recréer tout le sous-arbre `child`, y compris ce
  // PageView et son état de scroll interne — Flutter détruit puis reconstruit
  // au lieu de réutiliser l'élément. Avec un `GlobalKey`, l'élément est
  // déplacé (réutilisé) sous le nouveau parent plutôt que détruit. Cause
  // racine probable du crash `_dependents.isEmpty` observé en QA (Tests
  // Robustesse Système, Section 3) lors de bascules rapides d'onglets : la
  // Vibe peut encore être en transition (800ms, voir AnimatedVibeTheme)
  // pendant qu'on quitte puis revient sur l'onglet Lecteur, et la
  // destruction/reconstruction du PageView en plein vol laissait des
  // `InheritedElement` internes (Scrollable/PrimaryScrollController) avec des
  // dépendants non nettoyés.
  final GlobalKey _pageViewKey = GlobalKey();

  // Voir build() : dernière playlist résolue, réutilisée pendant un
  // rechargement transitoire de `playlistByIdProvider`.
  Playlist? _lastResolvedPlaylist;

  // Position réelle de la pochette pour la nébuleuse Space (voir
  // FluidBackground.coverKey).
  final GlobalKey _coverKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _tempoController.start();
  }

  @override
  void dispose() {
    _tempoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PlayerSnapshot player = ref.watch(playerControllerProvider);

    // Retour haptique synesthésique (Vibe Engine) sur changement de piste —
    // ici plutôt que dans PlayerController : le style dépend de la Vibe
    // active, une préoccupation d'UI, pas du moteur de lecture lui-même.
    ref.listen<PlayerSnapshot>(playerControllerProvider, (previous, next) {
      final String? previousId = previous?.currentTrack?.id;
      final String? nextId = next.currentTrack?.id;
      if (nextId != null && nextId != previousId) {
        VibeHapticService.trigger(context, VibeInteraction.trackChange);
      }
    });

    // Continuité des Vibes : le ticker tourne en permanence (démarré dans
    // initState), lecture en pause comprise — seul le BPM suit la piste.
    _tempoController.updateBpm((player.currentTrack?.bpm ?? 120).toDouble());

    final String? playlistId = player.currentPlaylistId;
    final AsyncValue<Playlist?> playlistAsync =
        playlistId == null ? const AsyncValue.data(null) : ref.watch(playlistByIdProvider(playlistId));
    // Stabilité de la pochette : pendant un rechargement transitoire du
    // stream (valeur momentanément absente), on garde la dernière playlist
    // résolue pour le MÊME id plutôt que de retomber une frame sur le repli
    // neutre — ce qui faisait disparaître la pochette de repli et flasher la
    // Vibe par défaut.
    //
    // Retest QA (61b5cf1) : au passage vers une AUTRE playlist, le stream
    // `playlistByIdProvider(nouvel id)` démarre à vide — le nouveau morceau
    // s'affichait d'abord sous la Vibe précédente/neutre. La liste complète
    // (`playlistsProvider`, déjà chargée pour Mon Espace/Découverte) contient
    // déjà cette playlist : utilisée comme résolution immédiate le temps que
    // le stream dédié émette. `select` : ne reconstruit que si CETTE
    // playlist change, pas à chaque modification d'une autre.
    final Playlist? fromList = playlistId == null
        ? null
        : ref.watch(playlistsProvider.select(
            (AsyncValue<List<Playlist>> all) => all.value?.where((p) => p.id == playlistId).firstOrNull,
          ));
    Playlist? playlist = playlistAsync.value ?? fromList;
    if (playlist != null) {
      _lastResolvedPlaylist = playlist;
    } else if (playlistAsync.isLoading && _lastResolvedPlaylist?.id == playlistId) {
      playlist = _lastResolvedPlaylist;
    }
    // Repli (playlist non résolue, ex. bref chargement après restauration à
    // froid, bug critique QA) : même repli neutre que `activeVibeProvider`
    // (couleur d'accent choisie par l'utilisateur en Réglages), pas un noir
    // figé (`black87`) sans rapport — voir [defaultVibeFor].
    final VibeVisual vibe = playlist?.resolvedVibe ?? defaultVibeFor(ref.watch(userAccentColorProvider));

    final Track? track = player.currentTrack;
    final String? playlistCoverImagePath = playlist?.coverImagePath;
    // Section 3.2 : même repli pochette->playlist que MasterPlayerScreen
    // utilise déjà pour AlbumArtReactive, réutilisé ici pour l'extraction de
    // palette (FluidBackground) — un morceau sans pochette dédiée profite
    // quand même des couleurs de la playlist plutôt que du dégradé statique.
    final String? effectiveCoverArtPath = (track?.coverArtPath.isNotEmpty ?? false)
        ? track!.coverArtPath
        : ((playlistCoverImagePath?.isNotEmpty ?? false) ? playlistCoverImagePath : null);

    // Icônes de la barre d'état (heure, batterie, réseau) : blanches sur une
    // Vibe sombre/OLED, sombres sur une Vibe claire — sans ça, le thème clair
    // de l'app les laissait noires sur le fond noir de Space/OLED (barre
    // pourtant affichée, mais illisible). Le Player n'a pas d'AppBar pour le
    // faire à sa place, contrairement aux autres écrans.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _statusBarStyleFor(vibe, Theme.of(context).scaffoldBackgroundColor),
      child: Scaffold(
        // Transitions fluides de Vibe (800ms, easeInOutCubic) : tout ce qui
        // dépend de la Vibe reçoit la valeur interpolée, jamais `vibe` brute —
        // voir AnimatedVibeTheme.
        body: AnimatedVibeTheme(
          vibe: vibe,
          builder: (context, animatedVibe, child) {
            // Section 4.1 : le fond (FluidBackground ou vidéo) englobe désormais
            // tout le PageView (Player + Queue) plutôt que la seule page 1 — la
            // Vibe reste donc visible et animée pendant le swipe vers la Queue
            // au lieu de disparaître derrière un fond vide.
            final Widget pageView = PageView(
              key: _pageViewKey,
              children: [
                _PlayerPage(
                  tempoController: _tempoController,
                  vibe: animatedVibe,
                  player: player,
                  coverKey: _coverKey,
                  playlistCoverImagePath: playlistCoverImagePath,
                ),
                const QueueScreen(),
              ],
            );

            // Section 4.3 : une vidéo de fond personnalisée remplace
            // entièrement le shader/dégradé/effet — jamais superposée.
            final String? videoPath = animatedVibe.customBackgroundVideoPath;
            if (videoPath != null) {
              return VibeVideoBackground(videoPath: videoPath, child: pageView);
            }

            return FluidBackground(
              tempoController: _tempoController,
              vibe: animatedVibe,
              coverArtPath: effectiveCoverArtPath,
              coverKey: _coverKey,
              child: _VibeBackgroundImageLayer(backgroundImagePath: animatedVibe.backgroundImagePath, child: pageView),
            );
          },
        ),
      ),
    );
  }
}

/// Partie "barre d'état" de [SystemUiOverlayStyle.light] / `.dark`
/// uniquement. Les champs de la barre de navigation sont laissés à `null`
/// (inchangés) : le style complet `.light` impose aussi une barre de
/// navigation noire à icônes claires, alors qu'ici le bas de l'écran est la
/// NavigationBar claire de la coque — la barre gestuelle y deviendrait
/// invisible.
const SystemUiOverlayStyle _kLightStatusBarIcons = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light, // Android : icônes blanches
  statusBarBrightness: Brightness.dark, // iOS : même effet, sémantique inverse
);

const SystemUiOverlayStyle _kDarkStatusBarIcons = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);

/// Space/New OLED (noir pur) et Neon (photo nocturne) sont toujours sombres ;
/// les autres Vibes sont jugées sur la moyenne de leurs couleurs de fond,
/// composées sur [underlay] (le fond du Scaffold, visible sous les couleurs
/// semi-transparentes de Glassmorphism par exemple).
SystemUiOverlayStyle _statusBarStyleFor(VibeVisual vibe, Color underlay) {
  final bool darkBackground = switch (vibe.preset) {
    VibePreset.oled || VibePreset.newOled || VibePreset.neon => true,
    _ =>
      ThemeData.estimateBrightnessForColor(_averageBackgroundColor(vibe.gradientColors, underlay)) == Brightness.dark,
  };
  return darkBackground ? _kLightStatusBarIcons : _kDarkStatusBarIcons;
}

Color _averageBackgroundColor(List<Color> colors, Color underlay) {
  if (colors.isEmpty) return underlay;
  double r = 0, g = 0, b = 0;
  for (final Color color in colors) {
    final Color opaque = Color.alphaBlend(color, underlay);
    r += opaque.r;
    g += opaque.g;
    b += opaque.b;
  }
  final int n = colors.length;
  return Color.from(alpha: 1, red: r / n, green: g / n, blue: b / n);
}

/// Image de fond personnalisée (Vibe Creator, `VibePreset.custom`) posée
/// sous [child] en semi-transparence — extrait de l'ancien corps de
/// `_PlayerPage` pour s'appliquer à tout le PageView (voir Section 4.1)
/// plutôt qu'à sa seule page 1.
class _VibeBackgroundImageLayer extends StatelessWidget {
  const _VibeBackgroundImageLayer({required this.backgroundImagePath, required this.child});

  final String? backgroundImagePath;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final String? path = backgroundImagePath;
    if (path == null) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: 0.35,
          // `errorBuilder` : même garde que PlaylistCoverImage/AlbumArtReactive
          // — un chemin d'image de fond personnalisée supprimé/déplacé/corrompu
          // hors de l'app ne doit pas casser tout l'écran (bug réel reproduit :
          // `Image.file` sans errorBuilder fait planter le rendu du Viewport
          // parent avec "RenderViewport expected a child of type RenderSliver
          // but received a child of type RenderErrorBox").
          child: Image.file(
            File(path),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
          ),
        ),
        child,
      ],
    );
  }
}

class _PlayerPage extends ConsumerStatefulWidget {
  const _PlayerPage(
      {required this.tempoController,
      required this.vibe,
      required this.player,
      required this.coverKey,
      this.playlistCoverImagePath});

  final TempoSyncController tempoController;
  // Posée sur la pochette : FluidBackground y centre la nébuleuse Space.
  final GlobalKey coverKey;
  final VibeVisual vibe;
  final PlayerSnapshot player;
  // Section 3.2 : pochette de repli quand le morceau en cours n'a pas de
  // pochette dédiée (`coverArtPath` vide) — celle de la playlist en cours de
  // lecture plutôt que l'icône générique d'AlbumArtReactive.
  final String? playlistCoverImagePath;

  @override
  ConsumerState<_PlayerPage> createState() => _PlayerPageState();
}

/// Mode Canvas immersif (Vibe Engine) : appui long sur la pochette, ou 15s
/// d'inactivité, masque les contrôles pour une écoute épurée façon
/// cadre/station — un tap n'importe où les ramène instantanément. L'état
/// vit dans [playerImmersiveModeProvider] (pas un simple `bool` local) pour
/// que la coque de navigation (`_TabShell`, router.dart) puisse le lire et
/// le forcer à `false` depuis le bouton Retour Android (Section 2.B).
class _PlayerPageState extends ConsumerState<_PlayerPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Section 3 : 7s (au lieu des 15s précédentes) avant le passage automatique
  // en mode Canvas/Focus.
  static const Duration _inactivityDelay = Duration(seconds: 7);
  // Partagée avec `_TabShell` (repli de la barre de navigation, voir
  // router.dart et player_immersive_mode_provider.dart) pour que les deux
  // transitionnent ensemble.
  static const Duration _fadeDuration = kImmersiveTransitionDuration;

  Timer? _inactivityTimer;

  // Bug QA "retour sur le Lecteur directement en Focus" : l'IndexedStack de
  // StatefulShellRoute garde cette page montée quand on change d'onglet (ou
  // qu'une sous-page comme /settings la recouvre), donc le Timer continuait
  // de tourner hors écran et le Lecteur réapparaissait déjà en Focus.
  //
  // Retest QA (61b5cf1) : le seul chemin du `routerDelegate` ne suffisait
  // pas (Timer déclenché sous /settings, barre d'état masquée dans les
  // Paramètres). La visibilité combine désormais 4 signaux indépendants,
  // tous nécessaires — voir [_computeVisibility] :
  //  - [_tickersEnabled] : `TickerMode` de l'Overlay/IndexedStack, coupé dès
  //    qu'une route opaque recouvre le Lecteur ou que l'onglet est masqué ;
  //  - [_pageRouteCurrent] : la route de la page dans SON Navigator de
  //    branche est au sommet (feuille modale, dialogue de branche...) ;
  //  - [_shellRouteCurrent] : la coque est au sommet du Navigator RACINE
  //    (sous-pages /settings, fiche artiste, dialogues racine), publié par
  //    `_TabShell` via [ShellRouteVisibility] ;
  //  - [_routerPathIsPlayer] : chemin du `routerDelegate` == /player.
  // S'y ajoutent [_appInForeground] (arrière-plan) et [_armedByUser] :
  // l'utilisateur a touché le Lecteur depuis qu'il y est (re)venu — le
  // Focus automatique n'est jamais déclenché par la seule arrivée sur
  // l'onglet, y compris au lancement de l'app. Dès qu'un signal tombe, le
  // Timer est annulé, [_armedByUser] désarmé et le Focus quitté (la
  // NavigationBar de 80dp revient via `_TabShell`).
  bool _tickersEnabled = true;
  bool _pageRouteCurrent = true;
  bool _shellRouteCurrent = true;
  bool _routerPathIsPlayer = true;
  bool _playerVisible = true;
  bool _appInForeground = true;
  bool _armedByUser = false;
  GoRouter? _router;

  late final AnimationController _floatController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat(reverse: true);
  late final Animation<double> _floatAnimation = CurvedAnimation(parent: _floatController, curve: Curves.easeInOut);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final AppLifecycleState? lifecycle = WidgetsBinding.instance.lifecycleState;
    _appInForeground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final GoRouter? router = GoRouter.maybeOf(context);
    if (!identical(router, _router)) {
      _router?.routerDelegate.removeListener(_onRouteChanged);
      _router = router;
      router?.routerDelegate.addListener(_onRouteChanged);
    }
    // Chacun de ces 3 appels crée une dépendance : didChangeDependencies est
    // rappelé dès que l'un d'eux change (route poussée/retirée au-dessus du
    // Lecteur, changement d'onglet).
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
    _pageRouteCurrent = ModalRoute.isCurrentOf(context) ?? true;
    _shellRouteCurrent = ShellRouteVisibility.isCurrentOf(context);
    _routerPathIsPlayer = _isPlayerPath();
    _computeVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` volontairement ignoré : transitoire (volet de
    // notifications, dialogue système), l'app reste affichée. Arrière-plan
    // réel = hidden/paused/detached.
    if (state == AppLifecycleState.inactive) return;
    final bool foreground = state == AppLifecycleState.resumed;
    if (foreground == _appInForeground) return;
    _appInForeground = foreground;
    if (!foreground) _leavePlayer();
  }

  /// Sans GoRouter (widget testé isolément) : considéré comme /player.
  bool _isPlayerPath() {
    final GoRouter? router = _router;
    if (router == null) return true;
    return router.routerDelegate.currentConfiguration.uri.path == '/player';
  }

  void _onRouteChanged() {
    _routerPathIsPlayer = _isPlayerPath();
    _computeVisibility();
  }

  void _computeVisibility() {
    final bool visible = _tickersEnabled && _pageRouteCurrent && _shellRouteCurrent && _routerPathIsPlayer;
    if (visible == _playerVisible) return;
    _playerVisible = visible;
    if (!visible) _leavePlayer();
  }

  /// Sortie du Lecteur (changement d'onglet, route poussée, arrière-plan) :
  /// Timer annulé, Focus quitté (NavigationBar rendue par `_TabShell`), et
  /// plus aucun passage automatique en Focus tant que l'utilisateur n'aura
  /// pas de nouveau touché le Lecteur.
  void _leavePlayer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _armedByUser = false;
    if (!mounted || !ref.read(playerImmersiveModeProvider)) return;
    // Appelé depuis didChangeDependencies (phase de build) ou depuis le
    // `routerDelegate`, qui peut notifier pendant un build/layout : modifier
    // un provider Riverpod à ce moment-là lève une exception, d'où le report
    // à la fin de la frame dans ce cas précis.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(playerImmersiveModeProvider.notifier).set(false);
      });
    } else {
      ref.read(playerImmersiveModeProvider.notifier).set(false);
    }
  }

  bool get _canAutoFocus => _playerVisible && _appInForeground && widget.player.currentTrack != null;

  @override
  void didUpdateWidget(covariant _PlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Retour d'usage (v1.0.x) : un changement de morceau ne quitte PLUS le
    // mode Focus — l'ancien `_exitImmersive()` réaffichait toute l'interface
    // (puis 6,5s d'attente) à chaque piste. En Focus, seuls Titre/Artiste se
    // mettent à jour (_ImmersiveCaption / bloc titre New OLED lisent
    // `widget.player`). Seule exception : plus aucun morceau (file terminée,
    // arrêt) — rien à afficher en Focus, retour à l'interface normale.
    if (oldWidget.player.currentTrack != null && widget.player.currentTrack == null) {
      _exitImmersive();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router?.routerDelegate.removeListener(_onRouteChanged);
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _floatController.dispose();
    super.dispose();
  }

  void _scheduleInactivity() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    if (!_armedByUser || !_canAutoFocus) return;
    _inactivityTimer = Timer(_inactivityDelay, _enterImmersive);
  }

  void _enterImmersive() {
    if (!mounted || ref.read(playerImmersiveModeProvider) || !_canAutoFocus) {
      return;
    }
    // Ergonomie navigation Android (2.A) : masque aussi la barre système
    // (statut + navigation), pas seulement les contrôles in-app. Le
    // `SystemChrome.setEnabledSystemUIMode` correspondant n'est PAS appelé
    // ici (bug critique QA "hybrid Focus mode" corrigé) : ce Timer continue
    // de tourner même quand cet onglet n'est pas affiché (IndexedStack le
    // garde monté), donc appeler l'API système depuis ici pendant que
    // Découverte/Espace est au premier plan modifierait la barre système du
    // MAUVAIS onglet. `_TabShell` (router.dart) réapplique désormais le mode
    // système à chaque reconstruction de la coque, en fonction de l'onglet
    // réellement affiché — seul point qui sait ça de manière fiable.
    ref.read(playerImmersiveModeProvider.notifier).set(true);
  }

  void _exitImmersive() {
    _inactivityTimer?.cancel();
    if (ref.read(playerImmersiveModeProvider) && mounted) {
      ref.read(playerImmersiveModeProvider.notifier).set(false);
    }
    _scheduleInactivity();
  }

  void _onAnyInteraction() {
    _armedByUser = true;
    if (!ref.read(playerImmersiveModeProvider)) _scheduleInactivity();
  }

  @override
  Widget build(BuildContext context) {
    final bool immersive = ref.watch(playerImmersiveModeProvider);
    // Relance le minuteur d'inactivité dès que le mode immersif se termine,
    // qu'il ait été quitté depuis l'intérieur (tap, voir _exitImmersive) ou
    // depuis l'extérieur (bouton Retour Android, voir _TabShell dans
    // router.dart). La restauration de la barre système, elle, est centralisée
    // dans `_TabShell` (voir _enterImmersive ci-dessus) plutôt que dupliquée ici.
    ref.listen<bool>(playerImmersiveModeProvider, (previous, next) {
      if (previous == true && next == false) _scheduleInactivity();
    });

    final Track? track = widget.player.currentTrack;
    final bool isPlaying = widget.player.status == PlaybackStatus.playing;
    final VibeVisual vibe = widget.vibe;
    // Pochette masquable sur toutes les Vibes (voir VibeCustomizerScreen)
    // — quand masquée, le reste du contenu se recentre
    // naturellement dans la Column (mainAxisAlignment.center ci-dessous) sans
    // laisser d'espace vide à sa place.
    final bool showCover = vibe.showCoverImage;
    // Pochette masquée : l'appui long sur la pochette (entrée manuelle en
    // Focus) n'a plus de cible — il se reporte alors sur tout l'arrière-plan
    // du lecteur, hors zones interactives (voir `_LongPressShield` autour
    // des contrôles). Pochette visible : seul l'appui long sur la pochette
    // compte, comme avant.
    final bool backgroundLongPressFocus = !showCover && !immersive;
    // New OLED (Section 3) : seul preset dont le Focus Mode garde Titre/
    // Artiste visibles, directement sous la pochette, au lieu de la légende
    // en bas d'écran (_ImmersiveCaption) des autres Vibes.
    final bool isNewOledFocus = immersive && vibe.preset == VibePreset.newOled;
    // Section 3.2 : repli sur la pochette de la playlist en cours quand le
    // morceau n'en a pas de dédiée — les deux champs partagent la même
    // convention "vide = absente" (voir Tracks.coverArtPath, Playlists.
    // coverImagePath), jamais `null` directement en base.
    final String? albumArtPath = (track?.coverArtPath.isNotEmpty ?? false)
        ? track!.coverArtPath
        : ((widget.playlistCoverImagePath?.isNotEmpty ?? false) ? widget.playlistCoverImagePath : null);

    final Widget albumArt = AnimatedBuilder(
      animation: _floatAnimation,
      builder: (context, child) {
        final double floatOffset = immersive ? (_floatAnimation.value - 0.5) * 16 : 0;
        return Transform.translate(offset: Offset(0, floatOffset), child: child);
      },
      child: AnimatedScale(
        scale: immersive ? 1.12 : 1.0,
        duration: _fadeDuration,
        curve: Curves.easeInOut,
        child: GestureDetector(
          onLongPress: _enterImmersive,
          child: KeyedSubtree(
            key: widget.coverKey,
            child: AlbumArtReactive(
              imagePath: albumArtPath,
              isPlaying: isPlaying,
              semanticLabel: track == null ? null : 'Pochette de ${track.title}',
            ),
          ),
        ),
      ),
    );

    final Widget content = SafeArea(
      child: Listener(
        onPointerDown: (_) => _onAnyInteraction(),
        behavior: HitTestBehavior.translucent,
        child: Stack(
          children: [
            // Ancêtre du défilement (et non frère sous-jacent dans le
            // Stack) : le Scrollable est opaque au hit-test et masquerait un
            // détecteur placé en dessous. Ici, il reçoit l'appui long partout
            // dans la zone de contenu, marges comprises (`translucent`) ; un
            // appui long immobile gagne l'arène face au glissement vertical.
            // `onLongPress: null` quand la pochette est visible : aucun
            // recognizer n'est alors créé, comportement historique intact.
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onLongPress: backgroundLongPressFocus ? _enterImmersive : null,
              child: Padding(
                padding: const EdgeInsets.all(24),
                // `ConstrainedBox(minHeight:)` + `SingleChildScrollView` plutôt
                // qu'un simple Column centré : sur un écran bas (petit téléphone,
                // barre de progression + actions ajoutées) le contenu peut
                // dépasser la hauteur disponible — il scrolle alors au lieu de
                // déborder, tout en restant centré quand il tient dans l'écran.
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      physics: immersive ? const NeverScrollableScrollPhysics() : null,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                        child: Column(
                          // QA "Polish & Final UI Fixes" (retest) : toujours
                          // `center`, même sans pochette — voir juste en dessous
                          // pourquoi `spaceEvenly` (essayé précédemment) sautait.
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (showCover) ...[
                              albumArt,
                              const SizedBox(height: 24),
                            ],
                            // Titre/Artiste + Contrôles regroupés dans une SEULE
                            // Column enfant plutôt que 2 enfants indépendants de
                            // la Column externe : `spaceEvenly` traitait l'espace
                            // ENTRE les deux comme un intervalle supplémentaire à
                            // distribuer (en plus du SizedBox(height:16) déjà
                            // présent avant ProgressSlider), donnant une
                            // impression de contenu dispersé plutôt que centré
                            // comme un groupe cohérent. Un `Spacer`/`Expanded`
                            // classique n'est PAS utilisable ici : cette Column
                            // vit dans un `SingleChildScrollView` (hauteur non
                            // bornée, pour permettre le défilement sur petit
                            // écran) — `Spacer` y lèverait une exception de
                            // layout ("incoming height constraints are
                            // unbounded"). `MainAxisAlignment.center` sur la
                            // Column externe centre ce groupe unique
                            // mathématiquement, sans ce risque.
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Titre/Artiste : masqués comme le reste en Focus
                                // Mode standard, mais laissés visibles pour New
                                // OLED (isNewOledFocus), sous la pochette.
                                AnimatedOpacity(
                                  opacity: (immersive && !isNewOledFocus) ? 0 : 1,
                                  duration: _fadeDuration,
                                  curve: Curves.easeInOut,
                                  child: IgnorePointer(
                                    ignoring: immersive && !isNewOledFocus,
                                    child: Column(
                                      children: [
                                        // QA Section 2.B/2.C : teintés à
                                        // `vibe.accentColor` (illisibles sur les
                                        // Vibes sombres avec le style ambiant
                                        // par défaut) et tronqués sur une ligne
                                        // (comme QueueScreen/PersonalSpaceScreen)
                                        // plutôt que de déborder sur un
                                        // titre/artiste long.
                                        Text(
                                          track?.title ?? 'Aucune lecture',
                                          style:
                                              Theme.of(context).textTheme.titleLarge?.copyWith(color: vibe.accentColor),
                                          textAlign: TextAlign.center,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          track?.artists.join(', ') ?? '',
                                          style:
                                              Theme.of(context).textTheme.bodyMedium?.copyWith(color: vibe.accentColor),
                                          textAlign: TextAlign.center,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                // Barre de progression/contrôles/actions :
                                // masqués en Focus Mode pour toutes les Vibes
                                // sans exception, y compris New OLED.
                                AnimatedOpacity(
                                  opacity: immersive ? 0 : 1,
                                  duration: _fadeDuration,
                                  curve: Curves.easeInOut,
                                  child: IgnorePointer(
                                    ignoring: immersive,
                                    child: _LongPressShield(
                                      active: backgroundLongPressFocus,
                                      child: Column(
                                        children: [
                                          const SizedBox(height: 16),
                                          ProgressSlider(
                                            fallbackDuration: track?.effectivePlaybackDuration ?? Duration.zero,
                                            color: vibe.accentColor,
                                          ),
                                          const SizedBox(height: 8),
                                          _PlaybackControls(vibe: vibe, isPlaying: isPlaying),
                                          const SizedBox(height: 8),
                                          if (track != null) _TrackActions(trackId: track.id, vibe: vibe),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: AnimatedOpacity(
                opacity: immersive ? 0 : 1,
                duration: _fadeDuration,
                curve: Curves.easeInOut,
                child: IgnorePointer(
                  ignoring: immersive,
                  child: _OverlayIconButton(
                    icon: Icons.settings_outlined,
                    color: vibe.accentColor,
                    tooltip: 'Paramètres',
                    // Annulation explicite AVANT la navigation, en plus de
                    // la détection de visibilité (didChangeDependencies) :
                    // aucune fenêtre où le Timer pourrait se déclencher
                    // pendant l'animation d'ouverture des Paramètres.
                    onPressed: () {
                      _leavePlayer();
                      context.push('/settings');
                    },
                  ),
                ),
              ),
            ),
            // Titre/artiste/année minimalistes du mode Canvas — seulement
            // visibles (et interactifs) en immersion. Absent en Focus Mode
            // New OLED (isNewOledFocus) : Titre/Artiste y restent affichés
            // directement sous la pochette à la place (voir plus haut).
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: IgnorePointer(
                ignoring: !immersive || isNewOledFocus,
                child: AnimatedOpacity(
                  opacity: (immersive && !isNewOledFocus) ? 1 : 0,
                  duration: _fadeDuration,
                  curve: Curves.easeInOut,
                  child: _ImmersiveCaption(track: track, accentColor: vibe.accentColor),
                ),
              ),
            ),
            if (immersive)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _exitImmersive,
                ),
              ),
          ],
        ),
      ),
    );

    // FluidBackground/l'image de fond personnalisée sont posés au niveau de
    // MasterPlayerScreen (Section 4.1), pas ici : cette page ne fait plus que
    // son propre contenu, affiché par-dessus le fond partagé avec la Queue.
    return content;
  }
}

/// Zone interactive (barre de progression, contrôles, actions) exclue de
/// l'appui long d'arrière-plan qui déclenche le Focus quand la pochette est
/// masquée. Un appui long sans action sur toute la zone : dans l'arène de
/// gestes, son recognizer (plus profond dans l'arbre, donc enregistré — et
/// son délai lancé — avant celui de l'arrière-plan) gagne le premier et
/// élimine celui de l'arrière-plan. Un appui long propre à un contrôle
/// (info-bulle d'un IconButton), encore plus profond, reste prioritaire.
class _LongPressShield extends StatelessWidget {
  const _LongPressShield({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: active ? () {} : null,
      child: child,
    );
  }
}

/// Titre/artiste/année en bas d'écran, seul repère laissé visible en mode
/// Canvas immersif.
class _ImmersiveCaption extends StatelessWidget {
  const _ImmersiveCaption({required this.track, required this.accentColor});

  final Track? track;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    if (track == null) return const SizedBox.shrink();

    final String subtitle = [
      track!.artists.join(', '),
      if (track!.releaseYear > 0) '${track!.releaseYear}',
    ].join(' · ');

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track!.title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: accentColor, letterSpacing: 0.5),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: accentColor.withValues(alpha: 0.8)),
        ),
      ],
    );
  }
}

/// Bouton en overlay translucide : garde l'écran immersif lisible sur un
/// preset sombre (OLED) comme sur un dégradé clair (Minimal), sans AppBar.
class _OverlayIconButton extends StatelessWidget {
  const _OverlayIconButton({required this.icon, required this.color, required this.tooltip, required this.onPressed});

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.25),
      shape: const CircleBorder(),
      child: IconButton(icon: Icon(icon, color: color), tooltip: tooltip, onPressed: onPressed),
    );
  }
}

class _PlaybackControls extends ConsumerWidget {
  const _PlaybackControls({required this.vibe, required this.isPlaying});

  final VibeVisual vibe;
  final bool isPlaying;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PlayerController controller = ref.read(playerControllerProvider.notifier);
    final PlayerRepeatMode repeatMode = ref.watch(playerControllerProvider.select((s) => s.repeatMode));

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RepeatModeButton(mode: repeatMode, color: vibe.accentColor, onPressed: controller.cycleRepeatMode),
        IconButton(
          iconSize: 36,
          color: vibe.accentColor,
          icon: const Icon(Icons.skip_previous, semanticLabel: 'Morceau précédent'),
          onPressed: controller.previous,
        ),
        IconButton(
          iconSize: 64,
          color: vibe.accentColor,
          icon: Icon(
            isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
            semanticLabel: isPlaying ? 'Pause' : 'Lecture',
          ),
          onPressed: controller.togglePlayPause,
        ),
        IconButton(
          iconSize: 36,
          color: vibe.accentColor,
          icon: const Icon(Icons.skip_next, semanticLabel: 'Morceau suivant'),
          onPressed: controller.next,
        ),
        // Espace muet de la même largeur que le bouton de mode — garde les
        // boutons précédent/lecture/suivant centrés plutôt que décalés vers
        // la droite par le bouton de mode isolé à gauche.
        const SizedBox(width: 36),
      ],
    );
  }
}

/// Bouton unique cyclant les 3 modes de lecture (Feuille de route pt.2) :
/// ordre de la playlist -> aléatoire -> répétition du titre.
class _RepeatModeButton extends StatelessWidget {
  const _RepeatModeButton({required this.mode, required this.color, required this.onPressed});

  final PlayerRepeatMode mode;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String tooltip) = switch (mode) {
      PlayerRepeatMode.playlistOrder => (Icons.repeat, 'Ordre de la playlist — appuyer pour activer l\'aléatoire'),
      PlayerRepeatMode.shuffle => (Icons.shuffle, 'Lecture aléatoire — appuyer pour répéter le titre'),
      PlayerRepeatMode.repeatOne => (Icons.repeat_one, 'Répétition du titre — appuyer pour revenir à l\'ordre normal'),
    };
    // Mode "ordre de la playlist" = repli neutre, atténué ; les deux modes
    // actifs (aléatoire/répétition) restent pleinement colorés pour rester
    // visibles d'un coup d'œil.
    final bool isActiveMode = mode != PlayerRepeatMode.playlistOrder;

    return IconButton(
      iconSize: 22,
      color: isActiveMode ? color : color.withValues(alpha: 0.5),
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}

/// "J'aime" + "Ajouter à une playlist" (Étape 3) — couleurs alignées sur la
/// Vibe active, comme le reste des contrôles.
class _TrackActions extends StatelessWidget {
  const _TrackActions({required this.trackId, required this.vibe});

  final String trackId;
  final VibeVisual vibe;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        LikeButton(trackId: trackId, color: vibe.accentColor),
        const SizedBox(width: 16),
        IconButton(
          iconSize: 28,
          icon: Icon(Icons.playlist_add, color: vibe.accentColor),
          tooltip: 'Ajouter à une playlist',
          onPressed: () => AddToPlaylistSheet.show(context, trackId),
        ),
      ],
    );
  }
}
