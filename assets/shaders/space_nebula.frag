#include <flutter/runtime_effect.glsl>

// Nébuleuse du preset Space (`VibePreset.oled`) — voir
// FluidBackground._FluidPainter._paintNebula. Remplace l'ancien dégradé
// radial simple (retest QA 61b5cf1) par un bruit fractal (FBM) à domaine
// déformé : filaments/tentacules nuageux, en rotation très lente.
//
// Uniforms fournis depuis Dart dans l'ordre déclaré (slots setFloat
// consécutifs) :
uniform vec2 uResolution;  // 0-1   : taille du canvas (px logiques)
uniform vec2 uCenter;      // 2-3   : centre de la POCHETTE dans ce canvas
uniform float uTime;       // 4     : secondes, monotone (TempoSyncController)
uniform vec2 uRadii;       // 5-6   : demi-axes de l'ellipse au-delà de
                           //         laquelle tout est noir pur (bornés
                           //         côté Dart par la distance aux bords)
uniform float uIntensity;  // 7     : respiration lumineuse, 0.92..1.08
uniform vec3 uColorA;      // 8-10  : couleur de coeur (palette pochette)
uniform vec3 uColorB;      // 11-13 : couleur des filaments externes

out vec4 fragColor;

// Rotation de la nébuleuse : 0.03 rad/s (fourchette demandée 0.02-0.05).
const float kRotationSpeed = 0.03;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float valueNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 4 octaves : assez de détail pour des filaments, coût GPU raisonnable
// (seuls les pixels à l'intérieur de l'ellipse l'évaluent, voir main()).
float fbm(vec2 p) {
  float value = 0.0;
  float amplitude = 0.5;
  mat2 octave = mat2(1.6, 1.2, -1.2, 1.6);
  for (int i = 0; i < 4; i++) {
    value += amplitude * valueNoise(p);
    p = octave * p;
    amplitude *= 0.5;
  }
  return value;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 offset = frag - uCenter;
  vec2 radii = max(uRadii, vec2(1.0));
  // Distance normalisée à l'ellipse : 1.0 = limite noire.
  float r = length(offset / radii);

  // Contrainte OLED stricte : noir pur (#000000 opaque) au-delà de l'ellipse
  // — aucune évaluation de bruit, aucune valeur résiduelle possible.
  if (r >= 1.0) {
    fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }

  // Bruit évalué dans un repère isotrope (pas étiré par l'ellipse), en
  // rotation lente autour de la pochette.
  float angle = uTime * kRotationSpeed;
  mat2 rotation = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
  vec2 p = rotation * (offset / min(radii.x, radii.y)) * 2.2;

  // Domain warping (deux niveaux) : étire le bruit en volutes/tentacules
  // plutôt qu'en taches rondes. Dérive interne très lente (0.01-0.02/s).
  vec2 q = vec2(fbm(p + vec2(0.0, uTime * 0.02)), fbm(p + vec2(5.2, 1.3) - uTime * 0.012));
  vec2 w = vec2(fbm(p + 3.2 * q + vec2(1.7, 9.2)), fbm(p + 3.2 * q + vec2(8.3, 2.8)));
  float cloud = fbm(p + 2.8 * w);

  // Enveloppe : plateau jusqu'à 40% de l'ellipse, puis fondu continu
  // jusqu'à exactement 0 à sa limite (déjà < 8% à 90%).
  float envelope = 1.0 - smoothstep(0.4, 1.0, r);

  float filaments = smoothstep(0.30, 0.80, cloud);
  float light = (0.30 + 1.15 * filaments) * envelope;

  vec3 tint = mix(uColorB, uColorA, clamp(cloud * 1.2 + (1.0 - r) * 0.4 - 0.25, 0.0, 1.0));
  vec3 color = tint * light * uIntensity;

  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
