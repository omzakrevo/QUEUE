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

Dossier `mobile/` : une seule application, deux modes selon le rôle du compte
(`borne` → distribution des tickets plein écran avec QR ; `agent`/`superviseur`/`administrateur` →
poste de guichet). À la première ouverture : adresse du serveur (ex. `192.168.1.10`), identifiant,
mot de passe, et pour une borne le n° de terminal.

L'APK est compilé par GitHub Actions (`.github/workflows/android-apk.yml`) : onglet *Actions* →
dernier run → artefact `omza-queue-apk`. En local : `cd mobile && flutter build apk --release`
(Android SDK requis). L'APK est signé avec la clé de debug : pour une diffusion commerciale, configurez
une clé de signature de production.

Limites actuelles : pas d'impression USB depuis l'application (impression réseau gérée par le serveur) ;
l'application n'a été vérifiée que par `flutter analyze` et ses tests unitaires, pas encore sur un appareil.
