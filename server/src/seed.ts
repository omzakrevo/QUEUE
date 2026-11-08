import { migrate, pool } from './db.js';
import { hashPassword } from './auth.js';

// Jeu de données de démonstration. Les mots de passe ci-dessous sont des mots de passe de
// démonstration : à changer avant toute mise en production.
const DEMO_PASSWORD = process.env.DEMO_PASSWORD ?? 'demo1234';

await migrate();
await pool.query(
  `insert into organizations(id,name,address,phone) values (1,'Établissement de démonstration','Ouagadougou, Burkina Faso','+226 00 00 00 00')
   on conflict (id) do nothing`);

const services: [string, string, string, number][] = [
  ['A', 'Accueil', '#1e88e5', 0], ['B', 'Caisse', '#43a047', 0], ['C', 'Consultation', '#e53935', 1],
  ['D', 'Informations', '#8e24aa', 0], ['E', 'Retrait', '#fb8c00', 0], ['F', 'Dépôt', '#00897b', 0],
];
for (const [code, name, color, priority] of services) {
  await pool.query(
    `insert into services(organization_id,name,code,color,priority) values (1,$1,$2,$3,$4) on conflict (code) do nothing`,
    [name, code, color, priority]);
}
for (const n of [1, 2, 3]) {
  await pool.query('insert into counters(name,number) values ($1,$2) on conflict (number) do nothing', [`Guichet ${n}`, n]);
}
// Guichet 1 : Accueil+Informations ; 2 : Caisse+Retrait+Dépôt ; 3 : Consultation
const map: Record<number, string[]> = { 1: ['A', 'D'], 2: ['B', 'E', 'F'], 3: ['C'] };
for (const [num, codes] of Object.entries(map)) {
  for (const code of codes) {
    await pool.query(
      `insert into counter_services(counter_id,service_id)
       select k.id, s.id from counters k, services s where k.number=$1 and s.code=$2 on conflict do nothing`, [Number(num), code]);
  }
}
const users: [string, string, string][] = [
  ['Administrateur', 'admin', 'administrateur'], ['Superviseur', 'superviseur', 'superviseur'],
  ['Responsable', 'responsable', 'responsable'], ['Agent 1', 'agent1', 'agent'], ['Agent 2', 'agent2', 'agent'],
  ['Borne 1', 'borne1', 'borne'], ['Écran TV 1', 'tv1', 'affichage'],
];
const hash = await hashPassword(DEMO_PASSWORD);
for (const [name, username, role] of users) {
  await pool.query('insert into users(name,username,password_hash,role) values ($1,$2,$3,$4) on conflict (username) do nothing',
    [name, username, hash, role]);
}
await pool.query(
  `insert into agents(user_id,counter_id,service_id)
   select u.id, k.id, null from users u join counters k on k.number = case u.username when 'agent1' then 1 when 'agent2' then 2 end
    where u.username in ('agent1','agent2') on conflict (user_id) do nothing`);
await pool.query(
  `insert into terminals(name,device_type,printer_type,paper_width) select 'Borne 1','windows','none',80
    where not exists (select 1 from terminals)`);
await pool.query(
  `insert into settings(setting_key,setting_value) values ('org_name','Établissement de démonstration')
   on conflict (setting_key) do nothing`);
console.log(`Données de démonstration créées (mot de passe de démo : ${DEMO_PASSWORD}).`);
await pool.end();
