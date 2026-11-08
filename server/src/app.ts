import http from 'node:http';
import { fileURLToPath } from 'node:url';
import express, { type Request, type Response, type NextFunction } from 'express';
import { Server } from 'socket.io';
import QRCode from 'qrcode';
import { pool, HttpError } from './db.js';
import {
  requireAuth, signToken, verifyToken, verifyPassword, hashPassword,
  checkLoginThrottle, noteLogin, type Role,
} from './auth.js';
import { allSettings, getSetting, setSetting, DEFAULTS } from './settings.js';
import { setIo, presence } from './realtime.js';
import * as T from './tickets.js';
import { buildTicket, sendToNetworkPrinter } from './escpos.js';
import { summary, exportCsv, type Period } from './stats.js';

const ROLES: Role[] = ['administrateur', 'superviseur', 'agent', 'responsable', 'borne', 'affichage'];
const ADMIN: Role[] = ['administrateur'];
const MANAGE: Role[] = ['administrateur', 'superviseur'];
const READ_STATS: Role[] = ['administrateur', 'superviseur', 'responsable'];

const h = (fn: (req: Request, res: Response) => Promise<unknown>) =>
  (req: Request, res: Response, next: NextFunction) => { fn(req, res).catch(next); };

function int(v: unknown, name: string): number {
  const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
  if (typeof n !== 'number' || !Number.isInteger(n)) throw new HttpError(400, `invalid_${name}`);
  return n;
}
function str(v: unknown, name: string, max = 200): string {
  if (typeof v !== 'string' || !v.trim() || v.length > max) throw new HttpError(400, `invalid_${name}`);
  return v.trim();
}

async function publicBase(req: Request): Promise<string> {
  const configured = await getSetting('public_base_url');
  return (configured || `${req.protocol}://${req.get('host')}`).replace(/\/$/, '');
}

/** Guichet de l'agent connecté ; administrateur/superviseur peuvent cibler un guichet via counter_id. */
async function counterFor(req: Request): Promise<number> {
  const u = req.user!;
  if (u.role === 'agent') {
    const r = await pool.query('select counter_id from agents where user_id=$1', [u.id]);
    if (!r.rows[0]?.counter_id) throw new HttpError(409, 'no_counter_assigned');
    return r.rows[0].counter_id;
  }
  return int(req.body?.counter_id ?? req.query.counter_id, 'counter_id');
}

export function buildServer() {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '100kb' }));
  const pub = fileURLToPath(new URL('../public', import.meta.url));

  // --------------------------------------------------------------- Pages (statiques, sans Internet)
  app.use(express.static(pub, { index: false, redirect: false }));
  const page = (p: string, file: string) => app.get(p, (_q, r) => r.sendFile(`${pub}/${file}`));
  page('/', 'index.html');
  page('/tv', 'tv/index.html');
  page('/kiosk', 'kiosk/index.html');
  page('/agent', 'agent/index.html');
  page('/admin', 'admin/index.html');
  app.get('/t/:token', (_q, r) => r.sendFile(`${pub}/ticket/index.html`));

  // --------------------------------------------------------------- Auth
  app.post('/api/auth/login', h(async (req, res) => {
    const username = str(req.body?.username, 'username', 64);
    const password = str(req.body?.password, 'password', 200);
    const key = `${req.ip}:${username}`;
    checkLoginThrottle(key);
    const r = await pool.query('select * from users where username=$1', [username]);
    const u = r.rows[0];
    const ok = !!u && u.status === 'active' && await verifyPassword(password, u.password_hash);
    noteLogin(key, ok);
    if (!ok) throw new HttpError(401, 'bad_credentials');
    const user = { id: u.id, username: u.username, name: u.name, role: u.role as Role };
    await T.audit(u.id, 'login', { ip: req.ip });
    res.json({ token: await signToken(user), user });
  }));
  app.get('/api/auth/me', requireAuth(), h(async (req, res) => { res.json(req.user); }));

  // --------------------------------------------------------------- Référentiels
  const any = requireAuth();
  app.get('/api/organization', any, h(async (_q, res) => {
    res.json((await pool.query('select * from organizations order by id limit 1')).rows[0] ?? null);
  }));
  app.put('/api/organization', requireAuth(...ADMIN), h(async (req, res) => {
    const b = req.body ?? {};
    const r = await pool.query(
      `insert into organizations(id,name,logo,address,phone) values (1,$1,$2,$3,$4)
       on conflict (id) do update set name=$1, logo=$2, address=$3, phone=$4 returning *`,
      [str(b.name, 'name'), b.logo ?? null, b.address ?? null, b.phone ?? null]);
    await T.audit(req.user!.id, 'organization.update');
    res.json(r.rows[0]);
  }));

  app.get('/api/services', any, h(async (_q, res) => {
    res.json((await pool.query('select * from services order by priority desc, id')).rows);
  }));
  const serviceFields = (b: Record<string, unknown>) => [
    str(b.name, 'name'), str(b.code, 'code', 4).toUpperCase(), b.description ?? null,
    typeof b.color === 'string' && /^#[0-9a-fA-F]{6}$/.test(b.color) ? b.color : '#1e88e5',
    b.priority == null ? 0 : int(b.priority, 'priority'), b.open_time || null, b.close_time || null,
    b.active == null ? true : !!b.active,
  ];
  app.post('/api/services', requireAuth(...MANAGE), h(async (req, res) => {
    const r = await pool.query(
      `insert into services(name,code,description,color,priority,open_time,close_time,active,organization_id)
       values ($1,$2,$3,$4,$5,$6,$7,$8,(select id from organizations order by id limit 1)) returning *`,
      serviceFields(req.body ?? {}));
    await T.audit(req.user!.id, 'service.create', { id: r.rows[0].id });
    res.status(201).json(r.rows[0]);
  }));
  app.put('/api/services/:id', requireAuth(...MANAGE), h(async (req, res) => {
    const r = await pool.query(
      `update services set name=$2, code=$3, description=$4, color=$5, priority=$6, open_time=$7, close_time=$8, active=$9
        where id=$1 returning *`, [int(req.params.id, 'id'), ...serviceFields(req.body ?? {})]);
    if (!r.rows[0]) throw new HttpError(404, 'service_not_found');
    await T.audit(req.user!.id, 'service.update', { id: r.rows[0].id });
    res.json(r.rows[0]);
  }));

  app.get('/api/counters', any, h(async (_q, res) => {
    res.json((await pool.query(
      `select k.*, coalesce(array_agg(cs.service_id) filter (where cs.service_id is not null), '{}') service_ids
         from counters k left join counter_services cs on cs.counter_id=k.id group by k.id order by k.number`)).rows);
  }));
  app.post('/api/counters', requireAuth(...MANAGE), h(async (req, res) => {
    const r = await pool.query('insert into counters(name,number) values ($1,$2) returning *',
      [str(req.body?.name, 'name'), int(req.body?.number, 'number')]);
    await T.audit(req.user!.id, 'counter.create', { id: r.rows[0].id });
    res.status(201).json(r.rows[0]);
  }));
  app.put('/api/counters/:id/services', requireAuth(...MANAGE), h(async (req, res) => {
    const id = int(req.params.id, 'id');
    const ids: number[] = (Array.isArray(req.body?.service_ids) ? req.body.service_ids : []).map((x: unknown) => int(x, 'service_id'));
    await pool.query('delete from counter_services where counter_id=$1', [id]);
    for (const s of ids) await pool.query('insert into counter_services(counter_id,service_id) values ($1,$2)', [id, s]);
    await T.audit(req.user!.id, 'counter.services', { id, ids });
    res.json({ counter_id: id, service_ids: ids });
  }));

  app.get('/api/users', requireAuth(...MANAGE), h(async (_q, res) => {
    res.json((await pool.query(
      `select u.id,u.name,u.username,u.role,u.status,a.counter_id,a.service_id
         from users u left join agents a on a.user_id=u.id order by u.id`)).rows);
  }));
  app.post('/api/users', requireAuth(...ADMIN), h(async (req, res) => {
    const b = req.body ?? {};
    if (!ROLES.includes(b.role)) throw new HttpError(400, 'invalid_role');
    const pw = str(b.password, 'password');
    if (pw.length < 8) throw new HttpError(400, 'password_too_short');
    const r = await pool.query(
      'insert into users(name,username,password_hash,role) values ($1,$2,$3,$4) returning id,name,username,role,status',
      [str(b.name, 'name'), str(b.username, 'username', 64), await hashPassword(pw), b.role]);
    if (b.role === 'agent') {
      await pool.query('insert into agents(user_id,counter_id,service_id) values ($1,$2,$3)',
        [r.rows[0].id, b.counter_id ?? null, b.service_id ?? null]);
    }
    await T.audit(req.user!.id, 'user.create', { id: r.rows[0].id, role: b.role });
    res.status(201).json(r.rows[0]);
  }));
  app.put('/api/users/:id', requireAuth(...ADMIN), h(async (req, res) => {
    const id = int(req.params.id, 'id');
    const b = req.body ?? {};
    if (b.status && !['active', 'disabled'].includes(b.status)) throw new HttpError(400, 'invalid_status');
    if (b.password) {
      if (String(b.password).length < 8) throw new HttpError(400, 'password_too_short');
      await pool.query('update users set password_hash=$2 where id=$1', [id, await hashPassword(String(b.password))]);
    }
    if (b.status) await pool.query('update users set status=$2 where id=$1', [id, b.status]);
    if ('counter_id' in b || 'service_id' in b) {
      await pool.query(
        `insert into agents(user_id,counter_id,service_id) values ($1,$2,$3)
         on conflict (user_id) do update set counter_id=$2, service_id=$3`, [id, b.counter_id ?? null, b.service_id ?? null]);
    }
    await T.audit(req.user!.id, 'user.update', { id, fields: Object.keys(b).filter((k) => k !== 'password') });
    res.json({ id });
  }));

  app.get('/api/terminals', requireAuth(...MANAGE), h(async (_q, res) => {
    res.json((await pool.query('select * from terminals order by id')).rows);
  }));
  app.post('/api/terminals', requireAuth(...MANAGE), h(async (req, res) => {
    const b = req.body ?? {};
    const r = await pool.query(
      'insert into terminals(name,device_type,printer_type,printer_address,paper_width) values ($1,$2,$3,$4,$5) returning *',
      [str(b.name, 'name'), b.device_type ?? 'windows', b.printer_type ?? 'none', b.printer_address ?? null, b.paper_width ?? 80]);
    await T.audit(req.user!.id, 'terminal.create', { id: r.rows[0].id });
    res.status(201).json(r.rows[0]);
  }));

  app.get('/api/settings', any, h(async (_q, res) => { res.json(await allSettings()); }));
  app.put('/api/settings', requireAuth(...ADMIN), h(async (req, res) => {
    const b = req.body ?? {};
    for (const [k, v] of Object.entries(b)) {
      if (!(k in DEFAULTS) || k === 'counter_epoch') throw new HttpError(400, `unknown_setting:${k}`);
      await setSetting(k, String(v));
    }
    await T.audit(req.user!.id, 'settings.update', Object.keys(b));
    res.json(await allSettings());
  }));

  // --------------------------------------------------------------- Tickets (bornes)
  async function printTicket(req: Request, ticketId: number, terminalId: number | null) {
    const t = await T.snapshot(ticketId);
    const org = await getSetting('org_name');
    const term = terminalId ? (await pool.query('select * from terminals where id=$1', [terminalId])).rows[0] : null;
    const width = (term?.paper_width === 58 ? 58 : 80) as 58 | 80;
    const data = buildTicket({
      org, service: t.service_name, number: t.ticket_number,
      date: new Date(t.created_at).toLocaleString('fr-FR', { timeZone: process.env.QUEUE_TZ ?? 'Africa/Ouagadougou' }),
      ahead: t.ahead, estimate_minutes: t.estimate_minutes, message: await getSetting('ticket_message'),
      qr_url: `${await publicBase(req)}/t/${t.access_token}`,
    }, width);
    return { data, term };
  }

  app.post('/api/tickets', requireAuth('borne', ...MANAGE), h(async (req, res) => {
    const u = req.user!;
    const terminalId = req.body?.terminal_id == null ? null : int(req.body.terminal_id, 'terminal_id');
    // Une borne ne choisit pas la priorité : elle est attribuée par un agent/superviseur.
    const priority = u.role === 'borne' ? 0 : int(req.body?.priority ?? 0, 'priority');
    const t = await T.createTicket({ serviceId: int(req.body?.service_id, 'service_id'), priority, terminalId, userId: u.id });
    const qr_url = `${await publicBase(req)}/t/${t.access_token}`;
    const { data, term } = await printTicket(req, t.id, terminalId);
    let print: { status: string; error?: string } = { status: 'client' }; // USB : imprimé par l'application
    if (term?.printer_type === 'none') print = { status: 'none' };
    if (term?.printer_type === 'network' && term.printer_address) {
      try {
        await sendToNetworkPrinter(term.printer_address, data);
        print = { status: 'printed' };
      } catch (e) {
        print = { status: 'failed', error: (e as Error).message };
        await T.noteEvent(t.id, 'print_failed', u.id, { error: print.error });
      }
    }
    res.status(201).json({ ticket: t, qr_url, print, escpos: data.toString('base64') });
  }));

  // Réimpression contrôlée : même numéro, aucune nouvelle génération.
  app.post('/api/tickets/:id/reprint', requireAuth('borne', 'agent', ...MANAGE), h(async (req, res) => {
    const id = int(req.params.id, 'id');
    const cur = await T.snapshot(id);
    if (!['waiting', 'called', 'serving'].includes(cur.status)) throw new HttpError(409, `invalid_state:${cur.status}`);
    await T.noteReprint(id, req.user!.id);
    const terminalId = req.body?.terminal_id == null ? cur.terminal_id : int(req.body.terminal_id, 'terminal_id');
    const { data, term } = await printTicket(req, id, terminalId);
    let print: { status: string; error?: string } = { status: 'client' };
    if (term?.printer_type === 'network' && term.printer_address) {
      try { await sendToNetworkPrinter(term.printer_address, data); print = { status: 'printed' }; }
      catch (e) { print = { status: 'failed', error: (e as Error).message }; }
    }
    res.json({ print, escpos: data.toString('base64'), reprint_count: cur.reprint_count + 1 });
  }));

  app.get('/api/tickets', requireAuth(...MANAGE), h(async (req, res) => {
    const limit = Math.min(Number(req.query.limit ?? 100) || 100, 500);
    const r = await pool.query(
      `select t.id, t.ticket_number, t.status, t.priority, t.created_at, t.called_at, t.completed_at, s.name service, k.number counter
         from tickets t join services s on s.id=t.service_id left join counters k on k.id=t.counter_id
        where ($1::text is null or t.status=$1) order by t.id desc limit $2`,
      [req.query.status ?? null, limit]);
    res.json(r.rows);
  }));
  app.get('/api/tickets/:id/history', requireAuth(...MANAGE), h(async (req, res) => {
    res.json((await pool.query(
      `select e.*, u.name user_name from ticket_events e left join users u on u.id=e.user_id where ticket_id=$1 order by e.id`,
      [int(req.params.id, 'id')])).rows);
  }));
  app.post('/api/tickets/:id/priority', requireAuth('agent', ...MANAGE), h(async (req, res) => {
    res.json(await T.setPriority(int(req.params.id, 'id'), int(req.body?.priority, 'priority'), req.user!.id));
  }));
  app.post('/api/tickets/:id/cancel', requireAuth(...MANAGE), h(async (req, res) => {
    res.json(await T.cancel(int(req.params.id, 'id'), req.user!.id));
  }));
  app.post('/api/admin/reset-numbering', requireAuth(...ADMIN), h(async (req, res) => {
    res.json({ epoch: await T.resetNumbering(req.user!.id) });
  }));

  // --------------------------------------------------------------- Agent
  const agent = requireAuth('agent', ...MANAGE);
  app.get('/api/agent/state', agent, h(async (req, res) => { res.json(await T.agentState(await counterFor(req))); }));
  const counterAction = (name: string, status: 'open' | 'paused' | 'closed') =>
    app.post(`/api/agent/counter/${name}`, agent, h(async (req, res) => {
      const id = await counterFor(req);
      await T.setCounterStatus(id, status, req.user!.id);
      res.json(await T.agentState(id));
    }));
  counterAction('open', 'open'); counterAction('pause', 'paused'); counterAction('resume', 'open'); counterAction('close', 'closed');

  app.post('/api/agent/call-next', agent, h(async (req, res) => {
    res.json(await T.callNext(await counterFor(req), req.user!.id));
  }));
  const ticketAction = (name: string, fn: (t: number, c: number, u: number) => Promise<unknown>) =>
    app.post(`/api/agent/tickets/:id/${name}`, agent, h(async (req, res) => {
      res.json(await fn(int(req.params.id, 'id'), await counterFor(req), req.user!.id));
    }));
  ticketAction('recall', T.recall);
  ticketAction('start', T.start);
  ticketAction('complete', T.complete);
  ticketAction('absent', T.markAbsent);
  ticketAction('skip', T.skip);
  app.post('/api/agent/tickets/:id/transfer', agent, h(async (req, res) => {
    res.json(await T.transfer(int(req.params.id, 'id'), await counterFor(req), int(req.body?.service_id, 'service_id'), req.user!.id));
  }));

  // --------------------------------------------------------------- Affichage TV
  app.get('/api/display/state', requireAuth('affichage', ...MANAGE), h(async (req, res) => {
    const ids = typeof req.query.services === 'string' && req.query.services
      ? req.query.services.split(',').map((x) => int(x, 'service')) : null;
    const rows = await pool.query(
      `select t.id, t.ticket_number, t.status, t.called_at, s.name service_name, s.color service_color, k.number counter_number
         from tickets t join services s on s.id=t.service_id join counters k on k.id=t.counter_id
        where t.called_at is not null and t.status in ('called','serving')
          and ($1::int[] is null or t.service_id = any($1)) order by t.called_at desc`, [ids]);
    const recent = await pool.query(
      `select t.id, t.ticket_number, t.called_at, s.color service_color, k.number counter_number
         from tickets t join services s on s.id=t.service_id join counters k on k.id=t.counter_id
        where t.called_at is not null and t.called_at > now() - interval '3 hours'
          and ($1::int[] is null or t.service_id = any($1)) order by t.called_at desc limit 8`, [ids]);
    const counts = (await T.queueCounts()).filter((s) => !ids || ids.includes(s.service_id));
    res.json({ current: rows.rows, recent: recent.rows, services: counts, settings: await allSettings() });
  }));

  // --------------------------------------------------------------- Suivi QR (public, par jeton)
  app.get('/api/public/ticket/:token', h(async (req, res) => {
    const token = String(req.params.token);
    if (!/^[0-9a-f]{32}$/.test(token)) throw new HttpError(404, 'ticket_not_found');
    const r = await pool.query('select id from tickets where access_token=$1', [token]);
    if (!r.rows[0]) throw new HttpError(404, 'ticket_not_found');
    const t = await T.snapshot(r.rows[0].id);
    res.json({
      ticket_number: t.ticket_number, service: t.service_name, color: t.service_color,
      status: T.publicStatus(t), position: t.position, ahead: t.ahead, estimate_minutes: t.estimate_minutes,
      counter: t.counter_number, org: await getSetting('org_name'),
    });
  }));
  app.get('/api/public/qr/:token', h(async (req, res) => {
    const token = String(req.params.token);
    if (!/^[0-9a-f]{32}$/.test(token)) throw new HttpError(404, 'ticket_not_found');
    const svg = await QRCode.toString(`${await publicBase(req)}/t/${token}`, { type: 'svg', margin: 1 });
    res.type('image/svg+xml').send(svg);
  }));

  // --------------------------------------------------------------- Statistiques et tableau de bord
  app.get('/api/dashboard', requireAuth(...READ_STATS), h(async (_q, res) => {
    const q = async (sql: string) => (await pool.query(sql)).rows[0];
    const [svc, ctr, tk] = await Promise.all([
      q('select count(*)::int n from services where active'),
      q("select count(*) filter (where status='open')::int open, count(*) filter (where status='paused')::int paused from counters"),
      q(`select count(*) filter (where status='waiting')::int waiting,
                count(*) filter (where status in ('called','serving'))::int in_progress,
                count(*) filter (where status='done' and completed_at >= date_trunc('day', now()))::int done_today from tickets`),
    ]);
    res.json({
      active_services: svc.n, open_counters: ctr.open, paused_counters: ctr.paused,
      tickets_waiting: tk.waiting, tickets_called: tk.in_progress, tickets_done_today: tk.done_today,
      connected: await presence(), services: await T.queueCounts(),
    });
  }));
  const periodArgs = (req: Request) => ({
    period: (String(req.query.period ?? 'today')) as Period,
    from: req.query.from as string | undefined, to: req.query.to as string | undefined,
  });
  app.get('/api/stats/summary', requireAuth(...READ_STATS), h(async (req, res) => {
    const { period, from, to } = periodArgs(req);
    res.json(await summary(period, from, to));
  }));
  app.get('/api/stats/export.csv', requireAuth(...READ_STATS), h(async (req, res) => {
    const { period, from, to } = periodArgs(req);
    res.type('text/csv; charset=utf-8').attachment(`omza-queue-${period}.csv`).send(await exportCsv(period, from, to));
  }));
  app.get('/api/audit', requireAuth(...ADMIN), h(async (req, res) => {
    const limit = Math.min(Number(req.query.limit ?? 100) || 100, 500);
    res.json((await pool.query(
      'select a.*, u.username from audit_logs a left join users u on u.id=a.user_id order by a.id desc limit $1', [limit])).rows);
  }));

  app.get('/api/health', h(async (_q, res) => {
    await pool.query('select 1');
    res.json({ ok: true });
  }));

  app.use('/api', (_q, _r, next) => next(new HttpError(404, 'not_found')));
  app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    if (err instanceof HttpError) return void res.status(err.status).json({ error: err.code });
    const e = err as { code?: string; message?: string };
    if (e?.code === '23505') return void res.status(409).json({ error: 'already_exists' });
    if (e?.code === '23503' || e?.code === '22P02' || e?.code === '23514') return void res.status(400).json({ error: 'invalid_reference' });
    if ((err as { type?: string })?.type === 'entity.parse.failed') return void res.status(400).json({ error: 'invalid_json' });
    console.error(err);
    res.status(500).json({ error: 'internal_error' });
  });

  // --------------------------------------------------------------- Socket.IO
  const server = http.createServer(app);
  const io = new Server(server, { serveClient: true });
  setIo(io);
  // Espace principal : authentifié (agents, TV, admin). Salons par rôle pour la présence.
  io.use(async (socket, next) => {
    try {
      const user = await verifyToken(String(socket.handshake.auth?.token ?? ''));
      socket.data.user = user;
      next();
    } catch { next(new Error('unauthorized')); }
  });
  io.on('connection', (socket) => {
    socket.join('all');
    socket.join(`role:${socket.data.user.role}`);
  });
  // Espace public : pages QR des visiteurs, sans authentification, uniquement des signaux.
  io.of('/public');

  return { app, server, io };
}
