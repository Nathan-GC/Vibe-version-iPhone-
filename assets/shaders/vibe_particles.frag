#include <flutter/runtime_effect.glsl>

// Particules audio-réactives (Vibe Engine) — superposées à FluidBackground.
// Uniforms fournis depuis Dart (voir VibeShaderLayer) dans l'ordre déclaré :
// chaque float/vec occupe un ou plusieurs "slots" consécutifs de
// FragmentShader.setFloat, d'où l'ordre strict ci-dessous.
uniform float uTime;        // secondes écoulées, montant en continu
uniform vec2 uResolution;   // taille du canvas en pixels
uniform float uTempo;       // BPM du morceau en cours (TempoSyncController)
uniform vec3 uPrimaryColor; // couleur d'accent de la Vibe active (0..1)
uniform float uStyle;       // 0=cyberpunk 1=synthwave 2=nature 3=étoiles
// Vibe Neon (styleIndex 0) uniquement — texture de la photo de fond
// (CyberpunkBackdrop), échantillonnée directement par ce shader pour la
// réfraction des gouttes et la détection réelle des zones néon. Sampler
// séparé des floats ci-dessus (index propre via setImageSampler), mais
// déclaré ici pour rester avec le reste des uniforms fournis par Dart.
uniform vec2 uBackdropSize;   // largeur/hauteur natives de la photo
uniform float uBackdropReady; // 1.0 une fois la texture réellement chargée
uniform sampler2D uBackdrop;
// Retro (styleIndex 1) uniquement — 1.0 quand la pochette est masquée
// (`VibeVisual.showCoverImage`, voir VibeCustomizerScreen) : le bloc Titre/
// Artiste remonte alors dans la Column du Player (voir MasterPlayerScreen),
// vers la zone où le soleil se dessinait par défaut — repoussé plus haut/
// réduit dans ce cas précis pour ne jamais chevaucher le texte, plutôt que
// de dégrader sa taille/position habituelle quand la pochette reste visible.
uniform float uCoverHidden;

out vec4 fragColor;

vec2 hash21(float p) {
  vec3 p3 = fract(vec3(p) * vec3(0.1031, 0.1030, 0.0973));
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.xx + p3.yz) * p3.zy);
}

// Reproduit le mapping BoxFit.cover de Flutter (Couche 1, Image.asset) pour
// que l'échantillon pris ici tombe exactement sur le même pixel de la photo
// que celui affiché à l'écran à cet endroit.
vec2 coverUV(vec2 uv, float canvasAspect, float imageAspect) {
  vec2 result = uv;
  if (imageAspect > canvasAspect) {
    float scale = canvasAspect / imageAspect;
    result.x = 0.5 + (uv.x - 0.5) * scale;
  } else {
    float scale = imageAspect / canvasAspect;
    result.y = 0.5 + (uv.y - 0.5) * scale;
  }
  return result;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uResolution;
  float aspect = uResolution.x / uResolution.y;
  vec2 auv = vec2(uv.x * aspect, uv.y);

  // Pulsation synchronisée au BPM — même logique que le halo de
  // FluidBackground (pic à mi-battement, retombe aux bords).
  float beatsPerSecond = max(uTempo, 1.0) / 60.0;
  float beatPhase = fract(uTime * beatsPerSecond);
  float pulse = 1.0 - abs(beatPhase - 0.5) * 2.0;

  int styleIndex = int(uStyle + 0.5);
  vec3 color = vec3(0.0);
  float alpha = 0.0;

  if (styleIndex == 0) {
    // Cyberpunk (Feuille de route Vibe v7) : ce shader échantillonne
    // désormais lui-même la photo de fond (uBackdrop) — jusque-là affichée
    // uniquement par Flutter en dessous (Couche 1, Image.asset) — pour deux
    // raisons précises : (a) réfracter la scène sous chaque goutte de pluie
    // comme une vraie micro-lentille, (b) détecter les zones réellement
    // roses/cyan de l'image pour le grésillement néon, plutôt que d'assener
    // des patches sombres placés à l'aveugle. `backdropReady` (uBackdropReady)
    // désactive proprement tout ce qui en dépend tant que la texture n'est
    // pas chargée — jamais de lecture de sampler invalide.
    bool backdropReady = uBackdropReady > 0.5;
    float imageAspect = uBackdropSize.x / max(uBackdropSize.y, 1.0);
    vec2 imgUV = coverUV(uv, aspect, imageAspect);
    vec3 baseColor = backdropReady ? texture(uBackdrop, imgUV).rgb : vec3(0.05, 0.06, 0.08);

    vec3 scene = vec3(0.0);
    float sceneAlpha = 0.0;

    // --- 0) Respiration globale ------------------------------------------
    // Modulation sinusoïdale LENTE (période ~12,5s) de l'ombrage global,
    // indépendante et bien plus lente que le grésillement néon ci-dessous —
    // la ville semble respirer doucement dans la nuit plutôt que de
    // clignoter. Contribution volontairement faible (7% max).
    float breathe = sin(uTime * 0.5) * 0.5; // -0.5..0.5
    vec3 breatheColor = breathe >= 0.0 ? vec3(1.0) : vec3(0.02);
    float breatheAlpha = abs(breathe) * 0.07;
    scene = mix(scene, breatheColor, breatheAlpha);
    sceneAlpha = max(sceneAlpha, breatheAlpha);

    // --- 1) Grésillement néon ---------------------------------------------
    // Détection réelle des pixels roses/cyan de la photo (canaux dominants +
    // luminosité), puis scintillement BIDIRECTIONNEL par cellule (creux
    // d'assombrissement ET pics de surbrillance/bloom, jamais un simple
    // masque sombre plaqué), calé sur le pulse du battement pour un faux
    // contact électrique d'enseigne.
    if (backdropReady) {
      float maxC = max(baseColor.r, max(baseColor.g, baseColor.b));
      float minC = min(baseColor.r, min(baseColor.g, baseColor.b));
      float saturation = maxC - minC;
      // Portes de brillance/saturation volontairement strictes : la brume
      // ambiante teal/cyan du grade colorimétrique cyberpunk couvre presque
      // toute la photo, sature légèrement ET tire vers le bleu — sans ces
      // seuils, `neonWeight` se déclenchait sur l'image entière plutôt que
      // sur les vraies enseignes (bug réel constaté : la grille de cellules
      // du grésillement se voyait comme un quadrillage plaqué partout).
      // Seuls les pixels à la fois TRÈS lumineux et TRÈS saturés — le
      // signature d'une enseigne néon, pas d'un ciel ou d'un mur embués —
      // passent ces deux portes.
      float brightGate = smoothstep(0.5, 0.8, maxC);
      float satGate = smoothstep(0.22, 0.45, saturation);
      float pinkness = clamp(min(baseColor.r, baseColor.b) - baseColor.g, 0.0, 1.0);
      float cyanness = clamp(min(baseColor.g, baseColor.b) - baseColor.r, 0.0, 1.0);
      float neonWeight = clamp(max(pinkness, cyanness) * 3.0, 0.0, 1.0) * brightGate * satGate;

      vec2 flickerCell = floor(imgUV * 70.0);
      vec2 flickerSeed = hash21(flickerCell.x * 13.7 + flickerCell.y * 91.3 + 4.0);
      float flickerPhase = uTime * (0.8 + flickerSeed.x * 2.2) + flickerSeed.y * 20.0;
      float flickerWave = sin(flickerPhase);       // -1..1, bidirectionnel dans le temps
      float beatKick = 0.4 + pulse * 0.6;          // contact plus franc sur le battement
      float flickerStrength = flickerWave * beatKick;

      vec3 flickered = baseColor * (1.0 + flickerStrength * 0.55);
      flickered += vec3(max(flickerStrength, 0.0)) * (baseColor + 0.2) * 0.5; // bloom sur les pics

      float flickerAlpha = neonWeight * abs(flickerStrength) * 0.85;
      scene = mix(scene, flickered, flickerAlpha);
      sceneAlpha = max(sceneAlpha, flickerAlpha);
    }

    // --- 2) Voile de condensation ------------------------------------------
    // Plat et uniforme, jamais un dégradé radial centré sur l'écran — c'est
    // précisément ce qui dessinait par erreur un faux "hublot rond" dans une
    // version précédente de ce shader.
    scene = mix(scene, vec3(0.08, 0.1, 0.13), 0.045);
    sceneAlpha = max(sceneAlpha, 0.045);

    // --- 3) Vitre pluvieuse ------------------------------------------------
    // 3a) Micro-gouttelettes de condensation, statiques (aucune dépendance à
    // uTime) : restent accrochées au verre, corps + liseré net. Trop petites
    // pour qu'une réfraction s'y voie, donc pas de sampler ici (économise le
    // budget de lectures de texture pour les gouttes qui ruissellent).
    for (int s = 0; s < 40; s++) {
      float fs = float(s);
      vec2 seed = hash21(fs * 71.3 + 5.0);
      vec2 delta = auv - vec2(seed.x * aspect, seed.y);
      float size = 0.0011 + seed.y * 0.0016;

      float body = smoothstep(size, size * 0.2, length(delta));
      float rim = smoothstep(size * 1.4, size * 0.9, length(delta)) -
          smoothstep(size * 0.9, size * 0.2, length(delta));
      float m = body * 0.3 + max(rim, 0.0) * 0.55;

      scene = mix(scene, vec3(0.85, 0.92, 0.98), m);
      sceneAlpha = max(sceneAlpha, m);
    }

    // 3b) Gouttes qui ruissellent : chacune agit comme une micro-lentille
    // convexe — la scène sous la goutte est ré-échantillonnée à une UV
    // décalée (loupe), avec un reflet spéculaire décentré (haut-gauche) et
    // une ombre portée douce (bas-droite) pour un vrai rendu de goutte en
    // verre plutôt qu'un halo flou ou une traînée linéaire. Nombre
    // d'itérations volontairement modéré (14, une seule lecture de texture
    // chacune) : le budget de lectures dépendantes reste faible pour tenir
    // 60/120 FPS même sur un rendu logiciel (SwiftShader).
    for (int i = 0; i < 14; i++) {
      float fi = float(i);
      vec2 seed = hash21(fi * 23.9 + 11.0);
      float speed = 0.045 + seed.y * 0.16;
      float wobble = sin(uTime * 1.4 + fi * 1.7) * 0.006;
      vec2 pos = vec2(seed.x + wobble, fract(seed.y + uTime * speed));
      vec2 dropAuv = vec2(pos.x * aspect, pos.y);
      vec2 delta = auv - dropAuv;
      float dropSize = 0.0036 + seed.x * 0.0046;
      vec2 deltaElliptical = delta * vec2(1.0, 0.62);
      float distDrop = length(deltaElliptical);

      float body = smoothstep(dropSize, dropSize * 0.82, distDrop);
      float rim = smoothstep(dropSize * 1.25, dropSize, distDrop) -
          smoothstep(dropSize, dropSize * 0.82, distDrop);

      // Loupe convexe : décale l'échantillon vers le centre proportionnellement
      // à la distance au centre de la goutte (grossissement local).
      vec2 refractOffset = (dropSize - distDrop) * normalize(deltaElliptical + 1e-4) * 2.2;
      vec2 refractedImgUV = imgUV + vec2(refractOffset.x / aspect, refractOffset.y);
      vec3 refractedColor = backdropReady ? texture(uBackdrop, refractedImgUV).rgb : baseColor;

      float highlight =
          smoothstep(dropSize * 0.4, 0.0, length(delta - vec2(-dropSize * 0.3, -dropSize * 0.3)));
      float shadow =
          smoothstep(dropSize * 0.45, 0.0, length(delta - vec2(dropSize * 0.32, dropSize * 0.36)));

      vec3 dropVisual = mix(refractedColor * 1.05, vec3(1.0), highlight * 0.8);
      dropVisual = mix(dropVisual, dropVisual * 0.55, shadow * 0.6);

      float trailLength = dropSize * 12.0;
      float trailMask = smoothstep(dropSize * 0.5, 0.0, abs(delta.x)) *
          smoothstep(trailLength, 0.0, -delta.y) * step(delta.y, 0.0);

      float dropMask = clamp(max(max(body, max(rim, 0.0) * 0.7), highlight * 0.9), 0.0, 1.0);
      scene = mix(scene, dropVisual, dropMask);
      // Traînée : léger éclaircissement de la photo telle quelle (pas de
      // second échantillon de texture — le décalage y serait incohérent loin
      // du corps de la goutte, et ça doublerait le coût de ce boucle pour un
      // gain visuel marginal sur un filet large de 1-2px).
      scene = mix(scene, baseColor, trailMask * 0.3 * (1.0 - dropMask));
      sceneAlpha = max(sceneAlpha, max(dropMask, trailMask * 0.3));
    }

    color = scene;
    alpha = clamp(sceneAlpha, 0.0, 1.0);
  } else if (styleIndex == 1) {
    // Synthwave 80s (Blade Runner / Outrun) : remplace entièrement l'ancien
    // effet de braises montantes. Couche opaque à elle seule (alpha = 1) —
    // un dégradé de ciel "marqué" se lirait mal derrière les halos flous du
    // fond général (FluidBackground), donc ce style possède son propre ciel.
    float horizonY = 0.62;

    vec3 skyTop = vec3(0.0706, 0.0, 0.1686);  // #12002B — nuit violette profonde
    vec3 skyHorizon = vec3(1.0, 0.0, 0.498);  // #FF007F — ligne d'horizon néon
    vec3 scene = mix(skyTop, skyHorizon, pow(clamp(uv.y / horizonY, 0.0, 1.0), 1.6));

    if (uv.y < horizonY) {
      // Soleil couchant strié : dégradé jaune -> rose, tranché par des
      // bandes horizontales qui s'élargissent vers le bas (effet "vinyle
      // découpé"), classique de l'iconographie synthwave. Position/rayon de
      // base déjà remontés une première fois (QA — Section 2.A, centre à 42%
      // -> 28% de hauteur) pour rester dans une zone "ciel" au-dessus de la
      // grille. Toujours pas suffisant quand la pochette est masquée
      // (`uCoverHidden`, retest QA) : le bloc Titre/Artiste remonte alors
      // encore plus haut dans la Column du Player — repoussé une seconde
      // fois et réduit spécifiquement dans ce cas (centre à 16%, rayon 0.12)
      // pour ne plus jamais le chevaucher, plutôt que de dégrader la taille
      // habituelle du soleil quand la pochette reste affichée.
      vec2 sunCenter = vec2(0.5 * aspect, horizonY - (uCoverHidden > 0.5 ? 0.46 : 0.34));
      float sunRadius = uCoverHidden > 0.5 ? 0.12 : 0.15;
      float distToSun = distance(auv, sunCenter);
      float sunMask = smoothstep(sunRadius, sunRadius - 0.008, distToSun);

      float sunT = clamp((auv.y - (sunCenter.y - sunRadius)) / (sunRadius * 2.0), 0.0, 1.0);
      vec3 sunColor = mix(vec3(1.0, 0.87, 0.35), vec3(1.0, 0.15, 0.55), sunT);

      float bandCount = mix(5.0, 16.0, sunT);
      float bandPhase = fract((auv.y - sunCenter.y + sunRadius) * bandCount);
      float bandWidth = mix(0.72, 0.4, sunT);
      float band = step(bandPhase, bandWidth);

      scene = mix(scene, sunColor, sunMask * band);
    } else {
      // Grille de perspective 3D : un petit nombre de lignes EXPLICITES
      // (pas un motif périodique à haute fréquence, qui aliase et se réduit
      // à une bande illisible près de l'horizon) — lignes horizontales qui
      // reculent puis défilent vers l'utilisateur (asservi au tempo),
      // lignes verticales convergeant en droite vers le point de fuite.
      float t = clamp((uv.y - horizonY) / (1.0 - horizonY), 0.0, 1.0);
      float scrollSpeed = 0.5 * max(beatsPerSecond, 0.6);
      float scrollPhase = fract(uTime * scrollSpeed);

      float gridH = 0.0;
      for (int k = 0; k < 9; k++) {
        float z = float(k) + scrollPhase;
        float lineT = 1.0 / (z * 1.6 + 1.0);
        float dist = abs(t - lineT);
        float width = mix(0.004, 0.018, lineT);
        gridH = max(gridH, smoothstep(width, 0.0, dist));
      }

      float gridV = 0.0;
      for (int k = -3; k <= 3; k++) {
        float lineX = 0.5 * aspect + float(k) * 0.16 * t;
        float dist = abs(auv.x - lineX);
        float width = mix(0.002, 0.012, t);
        gridV = max(gridV, smoothstep(width, 0.0, dist));
      }

      float gridMask = clamp(max(gridH, gridV) * (1.0 + pulse * 0.3), 0.0, 1.0);
      vec3 gridColor = mix(vec3(1.0, 0.0, 0.5), vec3(0.0, 0.95, 1.0), t);

      scene = mix(scene, gridColor, gridMask);
    }

    color = scene;
    alpha = 1.0;
  } else if (styleIndex == 2) {
    // Nature : silhouettes de lianes/lierre suspendues (tracées en courbes
    // sinusoïdales superposées) relevées de quelques lucioles — remplace le
    // simple champ de lucioles isolées, jugé trop discret pour se lire comme
    // un décor végétal.
    vec3 vines = vec3(0.0);
    for (int v = 0; v < 6; v++) {
      float fv = float(v);
      vec2 seed = hash21(fv * 53.1 + 7.0);
      float baseX = seed.x;
      float freq = 3.0 + seed.y * 4.0;
      float phase = seed.x * 20.0;
      float amp = 0.035 + seed.y * 0.06;

      float vineX = baseX + sin(uv.y * freq + phase + uTime * 0.08) * amp * (0.3 + 0.7 * uv.y);
      float dx = auv.x - vineX * aspect;
      float width = mix(0.0035, 0.011, uv.y); // plus épais vers le bas (perspective)
      float lineMask = smoothstep(width, width * 0.2, abs(dx));

      vec3 vineColor = mix(vec3(0.03, 0.09, 0.04), vec3(0.16, 0.42, 0.22), 0.5 + 0.5 * sin(fv * 2.7));
      vines += vineColor * lineMask * 0.75;
    }
    color += vines;

    // Lucioles : dérive douce + scintillement, identique au comportement
    // précédent mais légèrement plus lumineuses pour ressortir sur le fond
    // assombri (voir VibePresetStyle.organic).
    for (int i = 0; i < 24; i++) {
      float fi = float(i);
      vec2 seed = hash21(fi * 17.0 + 1.0);
      float t = uTime * 0.15 + fi * 2.0;
      vec2 pos = fract(seed + vec2(sin(t) * 0.06, cos(t * 0.8) * 0.05));
      float twinkle = 0.5 + 0.5 * sin(uTime * 2.5 + fi * 12.9);
      float size = 0.0014 + 0.002 * twinkle;
      vec3 particleColor = mix(uPrimaryColor, vec3(0.75, 1.0, 0.6), 0.65);

      vec2 particleAuv = vec2(pos.x * aspect, pos.y);
      float d = distance(auv, particleAuv);
      float radius = size * (1.0 + pulse * 0.5);
      float glow = smoothstep(radius * 2.4, 0.0, d);
      color += particleColor * glow;
    }

    alpha = clamp(max(color.r, max(color.g, color.b)), 0.0, 1.0);
  } else {
    // Étoiles (3, INCHANGÉ) et repli neutre : système de particules ponctuelles partagé.
    for (int i = 0; i < 36; i++) {
      float fi = float(i);
      vec2 seed = hash21(fi * 17.0 + 1.0);

      vec2 pos = seed;
      float size = 0.0012;
      vec3 particleColor = uPrimaryColor;

      if (styleIndex == 3) {
        // Étoiles : champ stellaire en parallaxe (3 couches de vitesse).
        // NE PAS MODIFIER — preset OLED/Étoiles figé à l'identique.
        float layer = mod(fi, 3.0);
        float speed = 0.015 + layer * 0.02;
        pos = fract(seed + vec2(uTime * speed, 0.0));
        size = 0.0008 + (layer / 3.0) * 0.0022;
        particleColor = mix(uPrimaryColor, vec3(1.0), 0.75);
      } else {
        // Repli neutre (presets sans style dédié) : poussières discrètes.
        size = 0.0012;
      }

      vec2 particleAuv = vec2(pos.x * aspect, pos.y);
      float d = distance(auv, particleAuv);
      float radius = size * (1.0 + pulse * 0.5);
      float glow = smoothstep(radius * 2.2, 0.0, d);
      color += particleColor * glow;
    }

    alpha = clamp(max(color.r, max(color.g, color.b)), 0.0, 1.0);
  }

  fragColor = vec4(color, alpha);
}
