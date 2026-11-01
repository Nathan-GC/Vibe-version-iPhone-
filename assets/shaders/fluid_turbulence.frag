#include <flutter/runtime_effect.glsl>

// Turbulence de l'effet "Fluide" du Vibe Creator (`VibePreset.custom` +
// `VibeCustomEffect.fluid`) — voir FluidBackground._FluidPainter. Carte de
// chaleur de fluide en BICOLORE : un champ scalaire turbulent dont les deux
// extrêmes sont les 2 couleurs de la Vibe, les valeurs intermédiaires un
// mélange continu. Grandes masses de chaque couleur, frontières découpées en
// volutes fines, grain partout (aucune zone lisse).
//
// Uniforms fournis depuis Dart dans l'ordre déclaré (slots setFloat
// consécutifs) :
uniform vec2 uResolution;  // 0-1 : taille du canvas (px logiques)
uniform float uTime;       // 2   : secondes, monotone (TempoSyncController)
uniform vec3 uColorA;      // 3-5 : couleur 1 de la Vibe (extrême haut du champ)
uniform vec3 uColorB;      // 6-8 : couleur 2 (extrême bas du champ)

out vec4 fragColor;

// ~3 masses sur la largeur d'un téléphone en portrait.
const float kScale = 3.0;
// Pente linéaire autour de 0.5 : assez forte pour de vraies masses aux deux
// extrêmes, sans smoothstep qui les aplatirait (le grain doit y rester
// visible).
const float kContrast = 2.2;
const mat2 kOctave = mat2(1.6, 1.2, -1.2, 1.6);

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

// Normalisés pour rester centrés sur ~0.5 quel que soit le nombre d'octaves.
float fbm2(vec2 p) {
  return (2.0 * valueNoise(p) + valueNoise(kOctave * p)) / 3.0;
}

float fbm4(vec2 p) {
  float value = 0.0;
  float amplitude = 0.5;
  for (int i = 0; i < 4; i++) {
    value += amplitude * valueNoise(p);
    p = kOctave * p;
    amplitude *= 0.5;
  }
  return value / 0.9375;
}

// Dérive en orbite (Lissajous) plutôt qu'en translation : continue, sans
// jamais revenir en arrière ni reboucler, ET bornée — une translation
// linéaire ferait grossir les coordonnées au fil des heures d'écoute et
// dégraderait la précision du hash (bruit qui se pixellise).
vec2 orbit(float speed, float phase, float radius) {
  float a = uTime * speed + phase;
  return radius * vec2(cos(a), sin(a * 0.83 + 1.7));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  // Repère isotrope (divisé par le plus petit côté) : volutes jamais étirées
  // selon le ratio de l'écran.
  vec2 p = (frag - 0.5 * uResolution) / max(min(uResolution.x, uResolution.y), 1.0) * kScale;

  // 16 évaluations de valueNoise par pixel au total : 4 (q) + 4 (r) + 4
  // (champ) + 2 (détail) + 2 (grain). Vitesses réglées pour ~3% de variation
  // moyenne par seconde : le détail, amplifié par le warp, bouge plus vite
  // que les masses, comme dans un vrai fluide.

  // Domain warping, deux niveaux : masses tordues en volutes.
  vec2 q = vec2(fbm2(p + orbit(0.003, 0.0, 4.0)), fbm2(p + vec2(5.2, 1.3) + orbit(-0.0025, 2.1, 4.0)));
  vec2 r = vec2(fbm2(p + 4.0 * q + vec2(1.7, 9.2) + orbit(0.004, 4.2, 3.0)),
                fbm2(p + 4.0 * q + vec2(8.3, 2.8) + orbit(-0.0035, 1.1, 3.0)));
  float field = fbm4(p + 4.0 * r);

  // Haute fréquence entraînée par le même écoulement (r) : micro-volutes
  // alignées sur les grandes, puis un grain encore plus fin déformé par le
  // détail lui-même, qui découpe les frontières et texture l'intérieur des
  // masses.
  vec2 d = p * 7.0 + 9.0 * r;
  float detail = fbm2(d + orbit(0.008, 0.5, 2.0));
  float grain = fbm2(d * 2.3 + vec2(5.0, -5.0) * detail + orbit(-0.01, 3.3, 2.0));

  float value = field + 0.45 * (detail - 0.5) + 0.30 * (grain - 0.5);
  float t = clamp((value - 0.5) * kContrast + 0.5, 0.0, 1.0);

  fragColor = vec4(mix(uColorB, uColorA, t), 1.0);
}
