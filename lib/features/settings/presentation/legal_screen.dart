import 'package:flutter/material.dart';

import '../../../core/platform/app_platform.dart';
import '../../../core/shared/constants/app_constants.dart';
import '../../../core/theme/design_system/app_spacing.dart';

// À compléter avant toute publication (mentions légales, RGPD : identité et
// contact du responsable de traitement obligatoires).
const String _editor = '[Nom et prénom, ou raison sociale]';
const String _editorAddress = '[Adresse postale]';
const String _contactEmail = AppConstants.contactEmail;
const String _backgroundImageCredit = '[Auteur, source et licence de l\'image de fond Neon (cyberpunk_city_1.png)]';
const String _lastUpdated = '1er octobre 2026';

/// Paramètres > Légal : textes juridiques de l'application, en lecture seule.
/// Les licences des dépendances viennent de `showLicensePage` (Flutter les
/// collecte automatiquement depuis chaque paquet).
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Légal')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.l),
        children: [
          for (final (String title, IconData icon, String body) in _documents)
            ExpansionTile(
              leading: Icon(icon),
              title: Text(title),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.m, 0, AppSpacing.m, AppSpacing.m),
              children: [SelectableText(body)],
            ),
          ListTile(
            leading: const Icon(Icons.code_outlined),
            title: const Text('Licences open source'),
            subtitle: const Text('Bibliothèques et composants intégrés à Vibe'),
            onTap: () => showLicensePage(context: context, applicationName: 'Vibe'),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.m),
            child: Text('Dernière mise à jour : $_lastUpdated', style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

// iOS : seuls ces trois passages diffèrent d'Android (voir AppPlatform).
String get _secureStorage =>
    AppPlatform.isIOS ? "chiffrés dans le trousseau d'iOS" : "chiffrés dans le stockage sécurisé d'Android";

String get _permissions => AppPlatform.isIOS
    ? '''5. Autorisations iOS
• Fichiers audio : aucune autorisation ; Vibe lit uniquement les morceaux déposés dans son dossier (Fichiers > Sur mon iPhone > Vibe) ou choisis dans le sélecteur de fichiers.
• Photos : aucune autorisation ; le sélecteur d'iOS ne transmet que l'image ou la vidéo que vous choisissez (pochette, fond de Vibe).
• Lecture en arrière-plan : pour continuer la lecture écran verrouillé.
• Actualisation en arrière-plan : contrôle périodique du nettoyage de la bibliothèque.
• Notifications : rappel local de nettoyage de la bibliothèque, généré sur l'appareil.'''
    : '''5. Autorisations Android
• Accès aux fichiers audio : pour importer et analyser vos morceaux.
• Internet : pour les services tiers ci-dessus.
• Lecture en arrière-plan : pour continuer la lecture écran éteint.
• Notifications : rappel local de nettoyage de la bibliothèque, généré sur l'appareil.
• Installation d'applications : uniquement dans la version distribuée hors Google Play, pour la mise à jour manuelle depuis un fichier APK que vous choisissez.''';

String get _eraseAll => AppPlatform.isIOS
    ? '''• Tout effacer : désinstallez l'application (appui long sur son icône > « Supprimer l'app », ou Réglages > Général > Stockage iPhone > Vibe). La bibliothèque, les playlists, les préférences, les copies de fichiers importés et les morceaux déposés dans Fichiers > Sur mon iPhone > Vibe sont alors supprimés. Les identifiants Spotify, qu'iOS conserve chiffrés dans le trousseau même après la désinstallation, sont effacés si vous réinstallez Vibe.'''
    : '''• Tout effacer : Paramètres Android > Applications > Vibe > Stockage > « Effacer les données », ou désinstallez l'application. La bibliothèque, les playlists, les préférences, les identifiants Spotify et les copies de fichiers importés sont alors supprimés.''';

List<(String, IconData, String)> get _documents => [
  (
    'Mentions légales',
    Icons.business_outlined,
    '''Éditeur de l'application Vibe :
$_editor
$_editorAddress
Contact : $_contactEmail

Vibe est une application gratuite, distribuée sans publicité. Elle n'est ni affiliée, ni approuvée, ni sponsorisée par Apple, la MetaBrainz Foundation (MusicBrainz, Cover Art Archive) ou Spotify ; ces noms sont des marques de leurs propriétaires respectifs.''',
  ),
  (
    'Politique de confidentialité',
    Icons.privacy_tip_outlined,
    '''Responsable du traitement : $_editor ($_contactEmail).

1. Principe
Vibe fonctionne localement. Il n'y a ni compte, ni publicité, ni outil de mesure d'audience, ni traceur. L'éditeur ne reçoit et ne conserve aucune de vos données.

2. Données conservées uniquement sur votre appareil
• Votre bibliothèque : titres, artistes, albums, genres, pochettes, durées, emplacement des fichiers, nombre d'écoutes et date de dernière écoute.
• Vos playlists, leurs réglages visuels et l'ordre des morceaux.
• Vos préférences : thème, couleur, dernière file de lecture.
• Le nom d'auteur saisi lors d'un export de playlist (il est aussi inscrit dans le fichier exporté que vous partagez).
• Les identifiants Spotify Developer (Client ID et Client Secret), si vous les saisissez, $_secureStorage.
• Les copies des fichiers audio et des images que vous importez.

3. Données transmises à des services tiers
Seulement lorsque la fonction concernée est utilisée, Vibe envoie des requêtes à :
• Apple (iTunes Search API) : titre et artiste des morceaux, ou votre recherche, pour compléter pochette, album, année et genre.
• MusicBrainz et Cover Art Archive (MetaBrainz Foundation) : titre et artiste, lorsque Apple ne trouve rien ou que vous choisissez cette source ; les requêtes identifient l'application (nom, version, contact de l'éditeur), jamais vous.
• Spotify : le lien de la playlist importée et, si vous les avez saisis, vos identifiants Spotify Developer.
L'enrichissement est automatique après l'analyse initiale et après chaque import (Apple, puis MusicBrainz en repli), sauf si vous le désactivez dans Paramètres > Confidentialité : l'import reste alors entièrement hors-ligne.
Les pochettes s'affichent depuis les serveurs d'Apple et du Cover Art Archive. Comme pour toute connexion internet, votre adresse IP est alors visible par ces services, qui la traitent selon leurs propres politiques :
Apple : apple.com/legal/privacy
MetaBrainz (MusicBrainz, Cover Art Archive) : metabrainz.org/privacy
Spotify : spotify.com/legal/privacy-policy
La police d'affichage est intégrée à l'application : aucun service de polices n'est contacté.

4. Base légale et droit d'opposition
Ces envois sont nécessaires au fonctionnement des fonctions que vous utilisez (exécution du service). L'enrichissement automatique repose sur l'intérêt légitime à présenter une bibliothèque complète ; vous pouvez vous y opposer à tout moment avec le réglage « Enrichissement automatique à l'importation ».

$_permissions

6. Durée de conservation
Vos données restent sur l'appareil tant que l'application est installée, ou jusqu'à ce que vous les supprimiez (voir « Suppression de vos données »).

7. Vos droits
Vos données étant sur votre appareil, vous pouvez les consulter, les corriger et les supprimer directement dans l'application. Pour toute question : $_contactEmail. Pour les données traitées par Apple, la MetaBrainz Foundation ou Spotify, adressez-vous à ces services. Vous pouvez introduire une réclamation auprès de la CNIL (cnil.fr).''',
  ),
  (
    'Conditions d\'utilisation',
    Icons.description_outlined,
    '''1. Objet
Vibe est un lecteur de musique pour les fichiers audio présents sur votre appareil. En utilisant l'application, vous acceptez les présentes conditions.

2. Vos fichiers
Vibe ne télécharge et ne diffuse aucune musique. Vous êtes responsable des fichiers que vous importez et devez disposer des droits nécessaires pour les écouter et les partager, notamment lors de l'export de playlists.

3. Contenus tiers
Les pochettes, métadonnées et aperçus proviennent de services tiers (Apple, MusicBrainz et Cover Art Archive, Spotify) et restent la propriété de leurs titulaires. Leur exactitude n'est pas garantie et leur usage est soumis aux conditions de ces services.

4. Licence
L'éditeur vous accorde un droit d'utilisation personnel et gratuit de l'application. Les composants open source intégrés restent régis par leurs propres licences (voir « Licences open source »), qui prévalent pour ces composants.

5. Responsabilité
L'application est fournie « en l'état », sans garantie de fonctionnement ininterrompu. Dans les limites permises par la loi, l'éditeur ne peut être tenu responsable d'une perte de données : conservez une copie de vos fichiers audio.

6. Évolution et droit applicable
Ces conditions peuvent évoluer ; la date de dernière mise à jour figure en bas de cette page. Elles sont régies par le droit français.''',
  ),
  (
    'Tarifs et remboursement',
    Icons.receipt_long_outlined,
    '''Vibe est entièrement gratuite : aucun achat intégré, aucun abonnement, aucun frais caché. Aucune somme n'étant perçue, aucun remboursement n'est à prévoir.''',
  ),
  (
    'Cookies et traceurs',
    Icons.cookie_outlined,
    '''Vibe n'utilise ni cookie, ni traceur publicitaire ou de mesure d'audience. Les seules informations enregistrées sur l'appareil (préférences, bibliothèque) sont strictement nécessaires au fonctionnement de l'application : elles ne requièrent pas votre consentement et ne sont partagées avec personne. C'est pourquoi aucun bandeau de consentement n'est affiché.''',
  ),
  (
    'Âge minimum',
    Icons.family_restroom_outlined,
    '''Vibe ne demande aucun compte et l'éditeur ne collecte aucune donnée, y compris pour les mineurs. Les fonctions en ligne interrogent Apple, MusicBrainz et Spotify, dont les services ont leurs propres conditions, notamment d'âge minimum. Si vous avez moins de 15 ans, demandez l'accord d'un parent avant de les utiliser.''',
  ),
  (
    'Suppression de vos données',
    Icons.delete_outline,
    '''Toutes vos données sont stockées sur votre appareil. Pour les supprimer :
• Un morceau : appui long > « Supprimer le fichier de l'appareil ».
• Une playlist : Mon espace > menu de la playlist > « Supprimer la playlist ».
$_eraseAll
Les fichiers d'origine restés ailleurs sur l'appareil et les playlists exportées en JSON ne sont pas concernés. L'éditeur ne détenant aucune donnée vous concernant, aucune demande de suppression ne lui est nécessaire.''',
  ),
  (
    'Crédits',
    Icons.palette_outlined,
    '''• Police Outfit : SIL Open Font License 1.1, intégrée à l'application (texte de la licence dans « Licences open source »).
• Image de fond de la Vibe Neon : $_backgroundImageCredit.
• Métadonnées : Apple iTunes Search API ; MusicBrainz (données principales CC0, genres issus des tags MusicBrainz sous licence CC BY-NC-SA 3.0, musicbrainz.org).
• Pochettes : Apple ; Cover Art Archive (coverartarchive.org), chaque image restant la propriété de ses ayants droit.
• Analyse des fichiers audio (silences, métadonnées) : FFmpeg (LGPL 3.0), via ffmpeg-kit.''',
  ),
];
