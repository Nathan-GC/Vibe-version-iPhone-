import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Layer B : presets visuels appliqués par playlist, indépendants du thème global.
/// Les noms correspondent exactement aux valeurs stockées en base (`playlists.vibe_style`).
/// `custom` délègue son rendu aux champs `bgColors` / `customBackgroundImagePath`
/// de la playlist plutôt qu'à une palette fixe — voir [PlaylistVibeResolver].
/// `oled` reste ce nom en base pour ne rien casser des playlists existantes
/// (voir [VibePresetStyle.label]) malgré son renommage utilisateur en "Space"
/// (Section 3) ; `newOled` est un preset distinct ajouté par cette même
/// section, volontairement séparé plutôt que de réutiliser `oled` : les deux
/// ont désormais des rendus différents (nébuleuse animée vs noir pur figé).
enum VibePreset { minimal, neon, glassmorphism, retro, organic, oled, custom, newOled }

class VibeTheme extends ThemeExtension<VibeTheme> {
  const VibeTheme({required this.preset, required this.gradientColors, required this.accentColor});

  final VibePreset preset;
  final List<Color> gradientColors;
  final Color accentColor;

  @override
  VibeTheme copyWith({VibePreset? preset, List<Color>? gradientColors, Color? accentColor}) {
    return VibeTheme(
      preset: preset ?? this.preset,
      gradientColors: gradientColors ?? this.gradientColors,
      accentColor: accentColor ?? this.accentColor,
    );
  }

  @override
  VibeTheme lerp(ThemeExtension<VibeTheme>? other, double t) {
    if (other is! VibeTheme) return this;
    return t < 0.5 ? this : other;
  }
}

/// Palette de chaque Vibe : dégradé de fond (Tab 2 pulsé au BPM) et couleur
/// d'accent des contrôles de lecture (Étape 5).
extension VibePresetStyle on VibePreset {
  List<Color> get gradientColors => switch (this) {
        VibePreset.minimal => const [Color(0xFFF5F5F5), Color(0xFFE0E0E0)],
        // Cyberpunk/Blade Runner (Feuille de route Vibe v2) : nuit bleu-cyan
        // très sombre et moite en base (voir `_FluidPainter.paint`,
        // `colors.first` remplit tout le canvas) avec des éclats néon
        // magenta/rose et cyan fluo qui dérivent par-dessus.
        VibePreset.neon => const [Color(0xFF050D1A), Color(0xFFFF007F), Color(0xFF00F3FF)],
        // Verre teinté plutôt que blanc quasi-transparent : l'app n'a pas de
        // flou d'arrière-plan (BackdropFilter) pour donner du relief à un
        // vrai glassmorphism, donc un dégradé presque invisible laissait les
        // contrôles (accentColor blanc) illisibles quel que soit le fond
        // sous-jacent — bug réel repéré en testant la vibe en conditions
        // réelles sur le lecteur.
        VibePreset.glassmorphism => [
            Colors.indigo.shade200.withValues(alpha: 0.65),
            Colors.indigo.shade400.withValues(alpha: 0.45)
          ],
        // Synthwave 80s (Feuille de route Vibe v2) : violet nuit profond en
        // haut vers magenta intense — le shader (styleIndex 1) peint
        // lui-même un dégradé vertical marqué + soleil strié + grille par-
        // dessus, ces deux couleurs ne servent donc plus qu'aux halos du
        // fond général (FluidBackground) hors zone du shader.
        VibePreset.retro => const [Color(0xFF12002B), Color(0xFFFF007F)],
        // Nature (Feuille de route Vibe v2) : vert forêt quasi noir plutôt
        // que le vert menthe clair précédent — les lianes/lucioles du shader
        // (styleIndex 2) doivent se détacher d'un fond sombre et mystérieux,
        // pas rivaliser avec lui.
        VibePreset.organic => const [Color(0xFF040B06), Color(0xFF15311F)],
        // Space (ex-OLED, Section 3) : base toujours noire — la nébuleuse
        // animée autour de la pochette (voir FluidBackground._paintNebula)
        // vient se superposer par-dessus, jamais remplacer ce noir de base.
        VibePreset.oled => const [Colors.black, Colors.black],
        // Repli tant que la playlist n'a pas encore de couleurs personnalisées
        // enregistrées (juste après le passage sur "Personnalisé").
        VibePreset.custom => const [Color(0xFF3A3A3A), Color(0xFF1A1A1A)],
        // New OLED (Section 3) : noir pur figé, sans nébuleuse ni palette de
        // pochette (voir VibeCoverPaletteUsage.ignoresCoverPalette) —
        // contrairement à Space, qui lui reflète la pochette en cours.
        VibePreset.newOled => const [Colors.black, Colors.black],
      };

  Color get accentColor => switch (this) {
        VibePreset.minimal => Colors.black87,
        VibePreset.neon => const Color(0xFF00F3FF),
        VibePreset.glassmorphism => Colors.black87,
        // Doré/orangé issu du soleil couchant plutôt que le magenta de la
        // grille : les boutons/contrôles de lecture en magenta sur fond nuit
        // violette étaient illisibles (contraste insuffisant) — bug réel
        // signalé après avoir testé le preset sur le lecteur.
        VibePreset.retro => const Color(0xFFFFD700),
        VibePreset.organic => const Color(0xFF5CDB7A),
        VibePreset.oled => Colors.white,
        VibePreset.custom => Colors.white,
        VibePreset.newOled => Colors.white,
      };

  // "Space" (Section 3) : renommage utilisateur de l'ancien "OLED" — le nom
  // Dart/la valeur stockée en base restent `oled` (voir doc de [VibePreset]).
  String get label => switch (this) {
        VibePreset.minimal => 'Minimal',
        VibePreset.neon => 'Neon',
        VibePreset.glassmorphism => 'Glassmorphism',
        VibePreset.retro => 'Retro',
        VibePreset.organic => 'Organic',
        VibePreset.oled => 'Space',
        VibePreset.custom => 'Personnalisé',
        VibePreset.newOled => 'OLED',
      };
}

/// Section 3 : ces presets ont une identité de couleur figée (palette du
/// preset) ou choisie explicitement par l'utilisateur (Custom) — la pochette
/// en cours de lecture ne doit plus jamais la reteindre (bug remonté : un
/// Custom savamment choisi se faisait recouvrir par la pochette dès qu'elle
/// avait une couleur dominante). `oled` (Space) est l'exception volontaire :
/// sa nébuleuse EST construite à partir de la pochette (voir
/// FluidBackground._maybeExtractPalette/._paintNebula). `glassmorphism` garde
/// son comportement historique (non concerné par cette section) ; `newOled`
/// suit les presets figés : son identité noir pur ne dépend jamais non plus
/// de la pochette.
extension VibeCoverPaletteUsage on VibePreset {
  bool get ignoresCoverPalette => switch (this) {
        VibePreset.minimal ||
        VibePreset.neon ||
        VibePreset.retro ||
        VibePreset.organic ||
        VibePreset.custom ||
        VibePreset.newOled =>
          true,
        VibePreset.glassmorphism || VibePreset.oled => false,
      };
}

/// Style de particules du shader GLSL audio-réactif (Vibe Engine — voir
/// assets/shaders/vibe_particles.frag) : 0 = surcouche buée/pluie/grésillement
/// néon par-dessus la photo de skyline plein écran (`neon`, voir
/// FluidBackground/kCyberpunkCityImage), 1 = grille de perspective + soleil
/// strié synthwave (`retro`), 2 = lianes et lucioles (`organic`), 3 = champ
/// d'étoiles (`oled`, INCHANGÉ).
extension VibeParticleStyle on VibePreset {
  int? get particleStyleIndex => switch (this) {
        VibePreset.neon => 0,
        VibePreset.retro => 1,
        VibePreset.organic => 2,
        VibePreset.oled => 3,
        // Pas d'effet dédié : le dégradé de FluidBackground suffit, inutile
        // de payer le coût GPU du shader pour ces presets. `newOled` reste
        // volontairement dans ce groupe : son identité "noir pur" (Section 3)
        // n'a besoin ni de particules ni de nébuleuse, contrairement à `oled`
        // (Space), qui en garde une.
        VibePreset.minimal || VibePreset.glassmorphism || VibePreset.custom || VibePreset.newOled => null,
      };
}

/// Effet visuel du fond animé pour `VibePreset.custom` (Vibe Creator, Section
/// 4.2) — voir `FluidBackground`/`_FluidPainter` pour le rendu de chacun :
///  - [fluid] : rendu historique (halos flous qui dérivent), aussi utilisé
///    tel quel par tous les presets figés (`minimal`, `neon`, ...) qui
///    n'exposent pas ce choix.
///  - [animatedGradient] : dégradé plein écran dont l'angle tourne en continu,
///    sans les halos flous du mode Fluide.
///  - [radiation] : rayons pulsés depuis le centre au rythme du BPM.
enum VibeCustomEffect { fluid, animatedGradient, radiation }

/// Rendu effectif d'une Vibe : pour les presets fixes, dérivé de [VibePresetStyle] ;
/// pour `VibePreset.custom`, dérivé des champs propres à la playlist
/// (`bgColors`, `customBackgroundImagePath`, `customEffect`) plutôt que d'une
/// palette statique.
class VibeVisual {
  const VibeVisual({
    required this.gradientColors,
    required this.accentColor,
    this.backgroundImagePath,
    this.preset,
    this.effect = VibeCustomEffect.fluid,
    this.customBackgroundVideoPath,
    this.showCoverImage = true,
  });

  final List<Color> gradientColors;
  final Color accentColor;
  final String? backgroundImagePath;
  // Pochette masquable sur toutes les Vibes (UI dans VibeCustomizerScreen)
  // — quand `false`, MasterPlayerScreen omet l'image et
  // recentre le reste du contenu (titre/artiste/contrôles) à sa place plutôt
  // que de laisser un espace vide.
  final bool showCoverImage;
  // Preset d'origine — `null` pour le repli neutre (aucune playlist active).
  // Alimente le choix du style de particules (shader) et du profil haptique
  // (VibeHapticService), qui ont besoin du preset discret, pas seulement des
  // couleurs dérivées.
  final VibePreset? preset;
  // Choix propre à `VibePreset.custom` (Section 4.2) — [VibeCustomEffect.fluid]
  // pour tous les autres presets, qui n'exposent pas ce réglage.
  final VibeCustomEffect effect;
  // Vidéo de fond personnalisée (Section 4.3, `VibePreset.custom` uniquement)
  // — quand non nulle, remplace entièrement le rendu shader/dégradé/[effect]
  // du Master Player (voir MasterPlayerScreen), jamais superposée à celui-ci.
  final String? customBackgroundVideoPath;

  // Égalité par valeur (bug QA "pochette qui clignote") : `resolvedVibe`
  // construit une nouvelle instance à chaque appel, donc sans `==`
  // `AnimatedVibeTheme` (ImplicitlyAnimatedWidget) voyait une "nouvelle"
  // Vibe à CHAQUE rebuild du Master Player (play/pause, position...) et
  // relançait sa transition de 800ms — reconstruisant tout le PageView à
  // chaque frame pour rien, pochette comprise.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VibeVisual &&
          listEquals(other.gradientColors, gradientColors) &&
          other.accentColor == accentColor &&
          other.backgroundImagePath == backgroundImagePath &&
          other.showCoverImage == showCoverImage &&
          other.preset == preset &&
          other.effect == effect &&
          other.customBackgroundVideoPath == customBackgroundVideoPath;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(gradientColors),
        accentColor,
        backgroundImagePath,
        showCoverImage,
        preset,
        effect,
        customBackgroundVideoPath,
      );
}
