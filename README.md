# OMZA QUEUE

Gestion intelligente des files d'attente — OMZAKREVO INFORMATIQUE.
Architecture client-serveur sur réseau local, **100 % fonctionnelle sans Internet**.

Ce dépôt contient la **première tranche livrable** du cahier des charges v1.0 : le serveur
(Node.js + TypeScript + PostgreSQL + Socket.IO) et les interfaces web locales
(borne, agent, TV, suivi QR, administration).

## État d'avancement

| Cahier des charges | État |
|---|---|
| §3.3–3.6 Serveur, API REST, PostgreSQL, numérotation transactionnelle, Socket.IO | ✅ fait et testé |
| §2.2 Distribution des tickets, ESC/POS 58/80 mm, impression réseau, réimpression | ✅ fait et testé (USB : voir ci-dessous) |
| §2.3 Guichets : appeler, rappeler, terminer, absent, ignorer, transférer, pause, priorités | ✅ fait et testé |
| §2.4 Affichage TV + annonce vocale locale (synthèse du navigateur/système) | ✅ fait, parcours vérifié dans Chromium |
| §2.5 Suivi QR Code (page locale, PWA) | ✅ fait et testé |
| §2.6 Statistiques, filtres de période, export CSV | ✅ fait ; **export PDF et Excel : à faire** |
| §6 Authentification, rôles, mots de passe hachés (scrypt), journal d'audit | ✅ fait et testé |
| §2.1 Administration | 🟡 interface web de consultation + création de services ; CRUD complet disponible via l'API |
| Applications Flutter Windows / Android (§3.2) | ⏳ **non commencées** |
| Impression USB (§5.2) | ⏳ le serveur fournit les octets ESC/POS ; l'envoi USB est du ressort de l'application Flutter |
| Service Windows + installateur, sauvegarde/restauration (§3.3, §6) | ⏳ à faire |

## Démarrage rapide

Prérequis : Node.js ≥ 20, PostgreSQL ≥ 14.

```bash
cd server
npm install
createdb queue                      # ou : DATABASE_URL=postgres://user:pass@hote:5432/queue
npm run seed                        # schéma + données de démonstration (mot de passe démo : demo1234)
npm run dev                         # http://localhost:3000
```

Variables d'environnement : `PORT` (3000), `DATABASE_URL`, `QUEUE_TZ` (Africa/Ouagadougou), `JWT_SECRET`
(sinon généré et conservé en base).

| Interface | URL | Compte démo |
|---|---|---|
| Borne | `/kiosk?terminal=1` | `borne1` |
| Agent | `/agent` | `agent1` (guichet 1), `agent2` (guichet 2) |
| Affichage TV | `/tv` ou `/tv?services=1,2` | `tv1` |
| Suivi visiteur | `/t/<jeton>` (via le QR du ticket) | — |
| Administration | `/admin` | `admin`, `superviseur`, `responsable` |

> Les comptes de démonstration ne sont **pas** à utiliser en production : changez les mots de passe
> (`PUT /api/users/:id`) ou créez vos propres comptes, et ne lancez pas `npm run seed` en production.

**Annonces vocales** : le navigateur de l'écran TV doit autoriser le son. Ouvrez `/tv`, cliquez une fois
sur « Activer le son », ou lancez Chrome en mode kiosque avec `--autoplay-policy=no-user-gesture-required`
et l'URL `/tv?autosound=1`. Une voix française doit être installée sur le poste (Windows : Paramètres →
Heure et langue → Voix).

**QR Code** : réglez `public_base_url` (ex. `http://192.168.1.10:3000`) dans les paramètres pour que
les QR contiennent l'adresse IP du serveur sur le Wi-Fi de l'établissement.

## Tests

```bash
createdb queue_test
cd server && npm test      # 13 tests d'intégration sur PostgreSQL (TEST_DATABASE_URL pour changer la base)
```

Couvre notamment : 60 demandes de tickets simultanées sans doublon, 100 tickets, files indépendantes,
deux guichets appelant en même temps, priorités, QR, réimpression, impression réseau (imprimante TCP
simulée), diffusion temps réel, conservation des données après redémarrage, statistiques et CSV.

## Documentation

- [Architecture et API](docs/ARCHITECTURE.md)
- Cahier des charges d'origine : [docs/cahier-des-charges.md](docs/cahier-des-charges.md)

## Application Android / Windows (Flutter)

Dossier `mobile/`. Au premier lancement, l'application propose deux façons de l'utiliser :

**1. Ce téléphone seul (sans PC, sans TV).** Le téléphone contient son propre moteur de files d'attente
(SQLite) : les visiteurs prennent un ticket sur l'écran (onglet *Tickets*), l'agent appelle depuis le même
téléphone (onglet *Guichet*), et **le téléphone annonce l'appel à voix haute** (synthèse vocale du
système, sans Internet). L'onglet *Réglages* permet de gérer les services, la voix, les statistiques du
jour et la remise à zéro des numéros. Tout fonctionne hors connexion.

**2. Ce téléphone sert aussi de serveur.** Dans *Réglages → Partager ce téléphone*, activez le partage :
le téléphone démarre un serveur (port 3000) avec la même API et les mêmes pages que le serveur Windows.
Les visiteurs peuvent alors scanner le QR du ticket pour suivre leur place, un navigateur (TV, tablette)
peut ouvrir `http://<adresse>:3000/tv`, `/kiosk` ou `/agent`, et d'autres téléphones peuvent se connecter
avec l'application. Les appareils doivent être sur le même Wi-Fi (ou sur le point d'accès du téléphone).
Les codes d'accès des appareils (`admin`, `agent1`, `borne1`, `tv1`) sont générés au premier partage et
**affichés une seule fois** ; seuls leurs hachages sont conservés.

**3. Borne ou poste agent relié à un serveur** (PC Windows ou autre téléphone) : adresse du serveur,
identifiant, mot de passe. Un compte `borne` ouvre la distribution de tickets, un compte `agent` le guichet.

### Impression des tickets (Bluetooth)

Pour imprimer le ticket du visiteur avec coupe automatique : jumelez l'imprimante thermique (58 ou 80 mm)
dans *Réglages Android → Bluetooth* (code 0000 ou 1234), puis dans l'application *Réglages → Imprimante de
tickets* : choisir l'imprimante, largeur du papier, coupe automatique (à désactiver si l'imprimante n'a pas de
couteau : le papier avance alors pour être arraché), puis *Imprimer un ticket test*. Le ticket s'affiche tout de
suite à l'écran ; si l'impression échoue, un bouton *Réimprimer* apparaît (même numéro, aucune nouvelle
numérotation, réimpression tracée). Sur une borne reliée à un serveur, le menu du cadenas (en bas à droite)
donne accès au même réglage. Le ticket contient le QR de suivi quand le partage est actif.

### Compilation de l'APK

GitHub Actions (`.github/workflows/android-apk.yml`) analyse, teste et compile : onglet *Actions* → dernier
run → artefact `omza-queue-apk`. En local : `cd mobile && flutter build apk --release` (Android SDK requis).
Les pages web embarquées (`mobile/assets/web`) sont une copie de `server/public` : après toute modification
de ces pages, lancez `mobile/tool/sync_web.sh` (le workflow échoue si les deux divergent).
L'APK est signé avec la clé de debug : une clé de production sera nécessaire pour le diffuser.

### Limites connues

- Impression : uniquement en Bluetooth (imprimante thermique classique « SPP »). Pas d'impression USB depuis
  le téléphone. Un téléphone qui sert de serveur n'imprime que sur sa propre imprimante : les tickets pris sur
  une autre borne s'impriment sur l'imprimante de cette borne.
- Quand le téléphone sert d'autres appareils, Android peut suspendre l'application si elle passe en arrière-plan :
  gardez-la ouverte (l'écran reste allumé automatiquement tant que le partage est actif) et désactivez
  l'optimisation de batterie pour OMZA QUEUE. Un service Android permanent reste à faire.
- Le serveur du téléphone n'a pas la page d'administration, les horaires d'ouverture par service, les
  exports ni les rôles « superviseur/responsable » du serveur Windows ; la configuration se fait dans
  l'application.
- Le temps réel des pages web servies par le téléphone repose sur une interrogation toutes les ~1,2 s
  (pas de Socket.IO) : l'affichage TV et la page QR se rafraîchissent donc avec ce léger délai.
- Vérifié automatiquement : moteur (concurrence, priorités, persistance), serveur embarqué, écrans, et
  parcours complet borne → agent → TV → QR dans Chromium contre le serveur embarqué. **Non vérifié sur un
  appareil Android réel** (voix, partage réseau, mise en veille) : à tester sur le téléphone.
