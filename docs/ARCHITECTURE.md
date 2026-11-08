# Architecture et API

## Principes

- Le **serveur est l'unique source de vérité** : numérotation, files, appels. Les clients (bornes,
  agents, TV, téléphones) n'écrivent jamais directement en base.
- **Aucun doublon de numéro** : `ticket_counters(service_id, scope_key)` est incrémenté par un
  `INSERT … ON CONFLICT DO UPDATE` ; le verrou de ligne sérialise les bornes concurrentes. Une
  contrainte `UNIQUE(origin_service_id, scope_key, seq)` sert de filet de sécurité.
- **Remise à zéro** (`reset_mode`) : `daily` (le périmètre est la date locale), `manual`/`session`
  (le périmètre est une « époque » incrémentée par `POST /api/admin/reset-numbering`).
- **Un appel ne prend jamais le même ticket deux fois** : `SELECT … FOR UPDATE SKIP LOCKED`, ordre
  priorité du ticket → priorité du service → ancienneté.
- **Ne jamais réclamer une 2ᵉ connexion du pool pendant une transaction** (interblocage constaté à
  60 requêtes simultanées pendant le développement) : toute lecture dans une transaction passe par
  la connexion de cette transaction.
- **Sans Internet** : aucune ressource externe. Socket.IO client, QR (SVG généré par le serveur),
  polices système, synthèse vocale du navigateur/OS.

## Cycle de vie d'un ticket

`waiting → called → serving → done`, avec `absent` (depuis `called`), `cancelled`, retour en
`waiting` par **Ignorer** (derrière les autres) ou **Transférer** (le numéro d'origine est conservé).
Chaque transition écrit une ligne dans `ticket_events` (qui, quand, détails), y compris les
changements de priorité et les échecs d'impression.

Statut vu par le visiteur : `waiting` / `soon` (≤ 2 personnes devant) / `called` / `serving` /
`done` / `cancelled`. La page publique ne reçoit qu'un jeton aléatoire de 128 bits et n'expose ni
identifiant interne ni donnée personnelle ; le canal Socket.IO public n'envoie qu'un signal
« rafraîchis-toi ».

## Rôles

| Rôle | Accès |
|---|---|
| administrateur | tout |
| superviseur | services, guichets, utilisateurs (lecture), tickets, stats |
| agent | son guichet uniquement |
| responsable | tableau de bord et statistiques |
| borne | création et réimpression de tickets (priorité forcée à 0) |
| affichage | état de l'écran TV |

Jetons JWT : 12 h pour les personnes, 365 jours pour les appareils fixes (borne, TV).
5 échecs de connexion → blocage d'une minute (par IP + identifiant).

## API REST (préfixe `/api`, `Authorization: Bearer <jeton>`)

| Méthode | Route | Rôles |
|---|---|---|
| POST | `/auth/login` | public |
| GET | `/auth/me` | tous |
| GET/PUT | `/organization` | tous / admin |
| GET/POST/PUT | `/services`, `/services/:id` | tous / superviseur+ |
| GET/POST | `/counters` ; PUT `/counters/:id/services` | tous / superviseur+ |
| GET/POST/PUT | `/users`, `/users/:id` | superviseur+ (lecture) / admin |
| GET/POST | `/terminals` | superviseur+ |
| GET/PUT | `/settings` | tous / admin |
| POST | `/tickets` | borne, superviseur+ |
| POST | `/tickets/:id/reprint` | borne, agent, superviseur+ |
| GET | `/tickets`, `/tickets/:id/history` | superviseur+ |
| POST | `/tickets/:id/priority` | agent, superviseur+ |
| POST | `/tickets/:id/cancel` | superviseur+ |
| POST | `/admin/reset-numbering` | admin |
| GET | `/agent/state` | agent |
| POST | `/agent/counter/{open,pause,resume,close}` | agent |
| POST | `/agent/call-next` | agent |
| POST | `/agent/tickets/:id/{recall,start,complete,absent,skip,transfer}` | agent |
| GET | `/display/state?services=1,2` | affichage |
| GET | `/public/ticket/:token`, `/public/qr/:token` | public |
| GET | `/dashboard`, `/stats/summary`, `/stats/export.csv` | admin, superviseur, responsable |
| GET | `/audit` | admin |

`POST /tickets` renvoie `{ ticket, qr_url, print, escpos }` : `print.status` vaut `printed`
(imprimante réseau OK), `failed` (le ticket existe quand même, réimpression possible), `none`, ou
`client` (imprimante USB : l'application imprime `escpos`, le contenu ESC/POS en base64).

## Événements Socket.IO

Espace principal (jeton requis) : `ticket.created`, `ticket.called`, `ticket.recalled`,
`ticket.started`, `ticket.completed`, `ticket.absent`, `ticket.skipped`, `ticket.transferred`,
`ticket.cancelled`, `ticket.priority`, `queue.updated`, `counter.paused`, `counter.resumed`,
`counter.closed`. Espace `/public` : `queue.updated` (sans données).

## Impression

`src/escpos.ts` génère le ticket (CP858 pour les accents, QR natif `GS ( k`, coupe) pour 58 mm ou
80 mm. Les imprimantes réseau (`hôte:9100`) sont pilotées par le serveur. Pour l'USB, l'application
Windows/Android récupère les octets (`escpos`) et les envoie via son module USB natif ; la liste
d'imprimantes compatibles reste à valider sur matériel réel.

## Prochaines étapes recommandées

1. Applications Flutter (borne, agent, admin) consommant cette API ; module USB par plateforme.
2. Export PDF/Excel des rapports ; sauvegarde/restauration (`pg_dump` planifié + interface).
3. Service Windows (par ex. `node-windows`/NSSM) et installateur ; PostgreSQL embarqué ou prérequis.
4. CRUD complet dans l'interface d'administration (guichets, utilisateurs, bornes, paramètres).
5. HTTPS local si les appareils l'exigent ; tests de charge (dizaines de connexions) sur le réseau cible.
