// Tests d'intégration (spécification §8) sur une vraie base PostgreSQL : queue_test.
process.env.DATABASE_URL = process.env.TEST_DATABASE_URL ?? 'postgres://queue:queue@localhost:5432/queue_test';
process.env.JWT_SECRET = 'test-secret';

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { io as ioClient } from 'socket.io-client';

const { migrate, pool } = await import('../src/db.js');
const { hashPassword } = await import('../src/auth.js');
const { buildServer } = await import('../src/app.js');

let base = '';
let server: ReturnType<typeof buildServer>['server'];
const tokens: Record<string, string> = {};
const svc: Record<string, number> = {};
const ctr: Record<number, number> = {};

async function api(method: string, path: string, body?: unknown, who?: string) {
  const r = await fetch(base + path, {
    method,
    headers: { 'content-type': 'application/json', ...(who ? { authorization: `Bearer ${tokens[who]}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  let json: any = null;
  try { json = JSON.parse(text); } catch { /* csv / svg */ }
  return { status: r.status, json, text };
}

async function login(username: string) {
  const r = await api('POST', '/api/auth/login', { username, password: 'password-123' });
  assert.equal(r.status, 200, `login ${username}`);
  tokens[username] = r.json.token;
}

before(async () => {
  await migrate();
  await pool.query(`truncate tickets, ticket_counters, ticket_events, counter_services, agents, counters, services, terminals,
                    users, settings, audit_logs, organizations restart identity cascade`);
  await pool.query("insert into organizations(id,name) values (1,'Test')");
  for (const [code, name, prio] of [['A', 'Accueil', 0], ['B', 'Caisse', 0], ['C', 'Consultation', 1]] as const) {
    svc[code] = (await pool.query('insert into services(name,code,priority) values ($1,$2,$3) returning id', [name, code, prio])).rows[0].id;
  }
  for (const n of [1, 2, 3]) ctr[n] = (await pool.query('insert into counters(name,number) values ($1,$2) returning id', [`G${n}`, n])).rows[0].id;
  // G1 et G2 servent tous deux A ; G2 sert aussi B ; G3 sert C
  for (const [n, codes] of [[1, ['A']], [2, ['A', 'B']], [3, ['C']]] as const) {
    for (const c of codes) await pool.query('insert into counter_services values ($1,$2)', [ctr[n], svc[c]]);
  }
  const hash = await hashPassword('password-123');
  const mk = async (username: string, role: string, counter?: number) => {
    const id = (await pool.query('insert into users(name,username,password_hash,role) values ($1,$1,$2,$3) returning id', [username, hash, role])).rows[0].id;
    if (counter) await pool.query('insert into agents(user_id,counter_id) values ($1,$2)', [id, ctr[counter]]);
  };
  await mk('admin', 'administrateur'); await mk('resp', 'responsable'); await mk('borne1', 'borne'); await mk('borne2', 'borne');
  await mk('tv', 'affichage'); await mk('ag1', 'agent', 1); await mk('ag2', 'agent', 2); await mk('ag3', 'agent', 3);

  const s = buildServer();
  server = s.server;
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  for (const u of ['admin', 'resp', 'borne1', 'borne2', 'tv', 'ag1', 'ag2', 'ag3']) await login(u);
  for (const a of ['ag1', 'ag2', 'ag3']) assert.equal((await api('POST', '/api/agent/counter/open', {}, a)).status, 200);
});

after(async () => {
  server.closeAllConnections();
  await new Promise((r) => server.close(r));
  await pool.end();
});

const newTicket = (service: string, who = 'borne1') => api('POST', '/api/tickets', { service_id: svc[service] }, who);

test('sécurité : routes protégées et rôles', async () => {
  assert.equal((await api('POST', '/api/tickets', { service_id: svc.A })).status, 401);
  assert.equal((await api('POST', '/api/agent/call-next', {}, 'borne1')).status, 403);
  assert.equal((await api('GET', '/api/stats/summary', undefined, 'borne1')).status, 403);
  assert.equal((await api('GET', '/api/stats/summary', undefined, 'resp')).status, 200);
  assert.equal((await api('POST', '/api/auth/login', { username: 'admin', password: 'mauvais' })).status, 401);
  const hash = (await pool.query("select password_hash from users where username='admin'")).rows[0].password_hash;
  assert.ok(hash.startsWith('scrypt$') && !hash.includes('password-123'));
});

test('deux bornes demandent un ticket simultanément : aucun doublon (60 requêtes parallèles)', async () => {
  const results = await Promise.all(
    Array.from({ length: 60 }, (_, i) => newTicket('A', i % 2 ? 'borne1' : 'borne2')));
  assert.ok(results.every((r) => r.status === 201));
  const numbers = results.map((r) => r.json.ticket.ticket_number as string).sort();
  assert.equal(new Set(numbers).size, 60);
  assert.deepEqual(numbers, Array.from({ length: 60 }, (_, i) => `A${String(i + 1).padStart(3, '0')}`));
});

test('100 tickets distribués : numérotation correcte, files indépendantes par service', async () => {
  const results = await Promise.all(Array.from({ length: 100 }, () => newTicket('B')));
  const n = results.map((r) => r.json.ticket.ticket_number as string).sort();
  assert.equal(n[0], 'B001');
  assert.equal(n[99], 'B100');
  assert.equal(new Set(n).size, 100);
  const c = await newTicket('C');
  assert.equal(c.json.ticket.ticket_number, 'C001'); // pas influencé par A et B
});

test('service inactif ou hors horaires : refusé ; borne ne choisit pas la priorité', async () => {
  await pool.query("update services set active=false where code='C'");
  assert.equal((await newTicket('C')).json.error, 'service_inactive');
  const tz = 'Africa/Ouagadougou';
  const win = (from: string, to: string) => pool.query(
    `update services set active=true,
       open_time=((now() at time zone '${tz}') + interval '${from}')::time,
       close_time=((now() at time zone '${tz}') + interval '${to}')::time where code='C'`);
  await win('1 hour', '2 hours'); // fenêtre future (y compris si elle franchit minuit) : fermé
  assert.equal((await newTicket('C')).json.error, 'service_closed');
  await win('-1 hour', '1 hour'); // fenêtre contenant l'instant présent : ouvert
  assert.equal((await newTicket('C')).status, 201);
  await pool.query("update services set open_time='22:00', close_time='06:00' where code='C'"); // plage de nuit
  const night = await pool.query("select (now() at time zone $1)::time >= '22:00' or (now() at time zone $1)::time <= '06:00' as open", [tz]);
  assert.equal((await newTicket('C')).status, night.rows[0].open ? 201 : 409);
  await pool.query("update services set open_time=null, close_time=null where code='C'");
  const p = await api('POST', '/api/tickets', { service_id: svc.A, priority: 5 }, 'borne1');
  assert.equal(p.json.ticket.priority, 0);
});

test('appel : priorité > ancienneté, jamais le même ticket pour deux guichets', async () => {
  await pool.query("update tickets set status='cancelled' where status='waiting'");
  const t1 = (await newTicket('A')).json.ticket;
  const t2 = (await newTicket('A')).json.ticket;
  const t3 = (await newTicket('A')).json.ticket;
  // t3 devient prioritaire (personne âgée) : tracé dans l'historique
  assert.equal((await api('POST', `/api/tickets/${t3.id}/priority`, { priority: 2 }, 'admin')).status, 200);
  const [c1, c2] = await Promise.all([
    api('POST', '/api/agent/call-next', {}, 'ag1'),
    api('POST', '/api/agent/call-next', {}, 'ag2'),
  ]);
  assert.equal(c1.status, 200); assert.equal(c2.status, 200);
  const called = [c1.json.id, c2.json.id].sort();
  assert.notEqual(c1.json.id, c2.json.id);
  assert.ok(called.includes(t3.id), 'le ticket prioritaire est appelé en premier');
  assert.ok(called.includes(t1.id) && !called.includes(t2.id));
  const hist = await api('GET', `/api/tickets/${t3.id}/history`, undefined, 'admin');
  assert.ok(hist.json.some((e: any) => e.event_type === 'priority_changed' && e.details.to === 2));
  // un agent ne peut pas appeler tant que son ticket n'est pas terminé
  assert.equal((await api('POST', '/api/agent/call-next', {}, 'ag1')).json.error, 'ticket_in_progress');
  // nettoyage
  await api('POST', `/api/agent/tickets/${c1.json.id}/complete`, {}, 'ag1');
  await api('POST', `/api/agent/tickets/${c2.json.id}/complete`, {}, 'ag2');
  await api('POST', `/api/tickets/${t2.id}/cancel`, {}, 'admin');
});

test('cycle agent : rappeler, démarrer, absent, ignorer, transférer, terminer, pause', async () => {
  await pool.query("update tickets set status='cancelled' where status='waiting'");
  const a = (await newTicket('A')).json.ticket;
  const b = (await newTicket('A')).json.ticket;
  const called = await api('POST', '/api/agent/call-next', {}, 'ag1');
  assert.equal(called.json.id, a.id);
  assert.equal(called.json.status, 'called');
  const rc = await api('POST', `/api/agent/tickets/${a.id}/recall`, {}, 'ag1');
  assert.equal(rc.status, 200);
  // le guichet 2 ne peut pas agir sur le ticket du guichet 1
  assert.equal((await api('POST', `/api/agent/tickets/${a.id}/complete`, {}, 'ag2')).status, 403);
  // ignorer : retourne derrière b
  assert.equal((await api('POST', `/api/agent/tickets/${a.id}/skip`, {}, 'ag1')).json.status, 'waiting');
  const next = await api('POST', '/api/agent/call-next', {}, 'ag1');
  assert.equal(next.json.id, b.id);
  assert.equal((await api('POST', `/api/agent/tickets/${b.id}/start`, {}, 'ag1')).json.status, 'serving');
  // transfert vers le service B
  const tr = await api('POST', `/api/agent/tickets/${b.id}/transfer`, { service_id: svc.B }, 'ag1');
  assert.equal(tr.json.status, 'waiting'); assert.equal(tr.json.service_id, svc.B);
  assert.equal(tr.json.ticket_number, b.ticket_number, 'le numéro est conservé');
  // absent
  const again = await api('POST', '/api/agent/call-next', {}, 'ag1');
  assert.equal(again.json.id, a.id);
  assert.equal((await api('POST', `/api/agent/tickets/${a.id}/absent`, {}, 'ag1')).json.status, 'absent');
  // pause : plus d'appel possible
  await newTicket('A');
  assert.equal((await api('POST', '/api/agent/counter/pause', {}, 'ag1')).json.counter.status, 'paused');
  assert.equal((await api('POST', '/api/agent/call-next', {}, 'ag1')).json.error, 'counter_paused');
  assert.equal((await api('POST', '/api/agent/counter/resume', {}, 'ag1')).json.counter.status, 'open');
  const last = await api('POST', '/api/agent/call-next', {}, 'ag1');
  assert.equal((await api('POST', `/api/agent/tickets/${last.json.id}/complete`, {}, 'ag1')).json.status, 'done');
});

test('QR Code : statut, position et aucune donnée sensible', async () => {
  await pool.query("update tickets set status='cancelled' where status='waiting'");
  const ts = [];
  for (let i = 0; i < 4; i++) ts.push((await newTicket('A')).json);
  const last = ts[3];
  const token = last.ticket.access_token;
  assert.match(last.qr_url, new RegExp(`/t/${token}$`));
  assert.ok(!last.qr_url.includes(String(last.ticket.id)) || token.length === 32);
  let p = await api('GET', `/api/public/ticket/${token}`);
  assert.equal(p.json.status, 'waiting'); assert.equal(p.json.ahead, 3); assert.equal(p.json.position, 4);
  assert.deepEqual(Object.keys(p.json).sort(),
    ['ahead', 'color', 'counter', 'estimate_minutes', 'org', 'position', 'service', 'status', 'ticket_number']);
  const c = await api('POST', '/api/agent/call-next', {}, 'ag1');
  await api('POST', `/api/agent/tickets/${c.json.id}/complete`, {}, 'ag1');
  p = await api('GET', `/api/public/ticket/${token}`);
  assert.equal(p.json.ahead, 2); assert.equal(p.json.status, 'soon');
  assert.equal((await api('GET', '/api/public/ticket/deadbeef')).status, 404);
  const svg = await api('GET', `/api/public/qr/${token}`);
  assert.match(svg.text, /<svg/);
});

test('réimpression : même numéro, pas de nouveau ticket ; échec d\'impression réseau tracé', async () => {
  const term = (await api('POST', '/api/terminals', { name: 'T-net', printer_type: 'network', printer_address: '127.0.0.1:1' }, 'admin')).json;
  const before = (await pool.query('select count(*)::int n from tickets')).rows[0].n;
  const r = await api('POST', '/api/tickets', { service_id: svc.B, terminal_id: term.id }, 'borne1');
  assert.equal(r.status, 201, 'le ticket est créé même si l\'imprimante est en panne');
  assert.equal(r.json.print.status, 'failed');
  const rp = await api('POST', `/api/tickets/${r.json.ticket.id}/reprint`, {}, 'borne1');
  assert.equal(rp.status, 200);
  assert.equal(rp.json.reprint_count, 1);
  assert.equal((await pool.query('select count(*)::int n from tickets')).rows[0].n, before + 1);
  const bytes = Buffer.from(rp.json.escpos, 'base64');
  assert.equal(bytes[0], 0x1b); assert.equal(bytes[1], 0x40); // ESC @
  assert.ok(bytes.includes(Buffer.from(r.json.ticket.ticket_number)));
});

test('impression réseau : les octets ESC/POS arrivent à l\'imprimante (port TCP simulé)', async () => {
  const net = await import('node:net');
  const chunks: Buffer[] = [];
  const srv = net.createServer((s) => s.on('data', (d) => chunks.push(d)));
  await new Promise<void>((r) => srv.listen(0, '127.0.0.1', r));
  const port = (srv.address() as AddressInfo).port;
  const term = (await api('POST', '/api/terminals', { name: 'T-ok', printer_type: 'network', printer_address: `127.0.0.1:${port}`, paper_width: 58 }, 'admin')).json;
  const r = await api('POST', '/api/tickets', { service_id: svc.B, terminal_id: term.id }, 'borne1');
  assert.equal(r.json.print.status, 'printed');
  await new Promise((res) => setTimeout(res, 100));
  const got = Buffer.concat(chunks);
  assert.ok(got.includes(Buffer.from(r.json.ticket.ticket_number)));
  assert.ok(got.includes(Buffer.from(`/t/${r.json.ticket.access_token}`)), 'le QR contient l\'URL de suivi');
  srv.close();
});

test('temps réel : l\'appel est diffusé aux écrans, signal public pour les pages QR', async () => {
  await pool.query("update tickets set status='cancelled' where status='waiting'");
  const tv = ioClient(base, { auth: { token: tokens.tv } });
  const visitor = ioClient(`${base}/public`);
  await Promise.all([new Promise((r) => tv.on('connect', () => r(0))), new Promise((r) => visitor.on('connect', () => r(0)))]);
  const gotCalled = new Promise<any>((r) => tv.once('ticket.called', r));
  const gotSignal = new Promise<any>((r) => visitor.once('queue.updated', r));
  const t = (await newTicket('A')).json.ticket;
  const c = await api('POST', '/api/agent/call-next', {}, 'ag1');
  const ev = await gotCalled;
  assert.equal(ev.ticket_number, t.ticket_number); assert.equal(ev.counter_number, 1);
  assert.deepEqual(Object.keys(await gotSignal), ['service_id']); // aucun détail de ticket côté public
  const state = await api('GET', '/api/display/state', undefined, 'tv');
  assert.equal(state.json.current[0].ticket_number, t.ticket_number);
  await api('POST', `/api/agent/tickets/${c.json.id}/complete`, {}, 'ag1');
  tv.close(); visitor.close();
  // un socket non authentifié est refusé sur l'espace principal
  const bad = ioClient(base, { auth: { token: 'x' } });
  const err = await new Promise<Error>((r) => bad.on('connect_error', r));
  assert.equal(err.message, 'unauthorized');
  bad.close();
});

test('numérotation : remise à zéro manuelle et mode de réinitialisation', async () => {
  await api('PUT', '/api/settings', { reset_mode: 'manual' }, 'admin');
  const x = await newTicket('A');
  const reset = await api('POST', '/api/admin/reset-numbering', {}, 'admin');
  assert.equal(reset.status, 200);
  const y = await newTicket('A');
  assert.equal(y.json.ticket.ticket_number, 'A001');
  assert.notEqual(x.json.ticket.ticket_number, undefined);
  await api('PUT', '/api/settings', { reset_mode: 'daily' }, 'admin');
});

test('statistiques et export CSV', async () => {
  const s = await api('GET', '/api/stats/summary?period=today', undefined, 'resp');
  assert.equal(s.status, 200);
  const t = s.json.totals;
  assert.ok(t.total > 100 && t.served >= 1 && t.absent >= 1 && t.cancelled >= 1);
  assert.equal(s.json.by_service.length, 3);
  assert.ok(s.json.by_hour.length >= 1);
  assert.ok(s.json.by_agent.length >= 1);
  assert.equal((await api('GET', '/api/stats/summary?period=custom&from=2020-01-01&to=2020-01-02', undefined, 'resp')).json.totals.total, 0);
  assert.equal((await api('GET', '/api/stats/summary?period=custom&from=x&to=y', undefined, 'resp')).status, 400);
  const csv = await api('GET', '/api/stats/export.csv?period=today', undefined, 'resp');
  assert.equal(csv.status, 200);
  assert.ok(csv.text.split('\r\n')[0].includes('ticket_number;service'));
  assert.ok(csv.text.split('\r\n').length > 100);
  const dash = await api('GET', '/api/dashboard', undefined, 'resp');
  assert.equal(dash.json.open_counters, 3);
});

test('données conservées après redémarrage du serveur', async () => {
  const before = (await pool.query('select count(*)::int n from tickets')).rows[0].n;
  server.closeAllConnections();
  await new Promise((r) => server.close(r));
  const s = buildServer();
  server = s.server;
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  assert.equal((await pool.query('select count(*)::int n from tickets')).rows[0].n, before);
  assert.equal((await api('GET', '/api/health')).status, 200);
  // la sessions existantes (JWT) restent valides : le secret est stable
  assert.equal((await api('GET', '/api/auth/me', undefined, 'admin')).status, 200);
});
