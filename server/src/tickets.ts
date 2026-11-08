import { randomBytes } from 'node:crypto';
import type pg from 'pg';
import { pool, tx, HttpError } from './db.js';
import { config } from './config.js';
import { getSetting } from './settings.js';
import { publish } from './realtime.js';

export type Status = 'waiting' | 'called' | 'serving' | 'done' | 'absent' | 'cancelled';

export interface TicketRow {
  id: number; ticket_number: string; service_id: number; origin_service_id: number;
  counter_id: number | null; status: Status; priority: number; access_token: string;
  created_at: Date; queue_at: Date; called_at: Date | null; started_at: Date | null;
  completed_at: Date | null; reprint_count: number; terminal_id: number | null;
}

async function logEvent(c: pg.PoolClient, ticketId: number, type: string, userId: number | null, details?: unknown) {
  await c.query('insert into ticket_events(ticket_id,event_type,user_id,details) values ($1,$2,$3,$4)', [
    ticketId, type, userId, details ? JSON.stringify(details) : null,
  ]);
}

export async function audit(userId: number | null, action: string, details?: unknown) {
  await pool.query('insert into audit_logs(user_id,action,details) values ($1,$2,$3)', [
    userId, action, details ? JSON.stringify(details) : null,
  ]);
}

/** Périmètre de numérotation : jour (quotidien) ou époque (session/manuel, incrémentée à la remise à zéro). */
async function scopeKey(c: pg.PoolClient): Promise<string> {
  const mode = await getSetting('reset_mode', c);
  if (mode === 'daily') {
    const r = await c.query("select to_char(now() at time zone $1,'YYYY-MM-DD') d", [config.timezone]);
    return `d:${r.rows[0].d}`;
  }
  return `e:${await getSetting('counter_epoch', c)}`;
}

function formatNumber(code: string, seq: number) {
  return `${code}${String(seq).padStart(3, '0')}`;
}

/** Création d'un ticket. Le UPSERT sur ticket_counters prend un verrou de ligne : deux bornes
 *  simultanées sont sérialisées et ne peuvent jamais recevoir le même numéro. */
export async function createTicket(opts: { serviceId: number; priority?: number; terminalId?: number | null; userId?: number | null }) {
  const ticket = await tx(async (c) => {
    const s = await c.query(
      `select id, code, active, open_time, close_time,
              (open_time is null or close_time is null
               or case when open_time <= close_time
                       then (now() at time zone $2)::time between open_time and close_time
                       else (now() at time zone $2)::time >= open_time or (now() at time zone $2)::time <= close_time
                  end) as is_open
         from services where id=$1`,
      [opts.serviceId, config.timezone],
    );
    const svc = s.rows[0];
    if (!svc) throw new HttpError(404, 'service_not_found');
    if (!svc.active) throw new HttpError(409, 'service_inactive');
    if (!svc.is_open) throw new HttpError(409, 'service_closed');

    const scope = await scopeKey(c);
    const n = await c.query(
      `insert into ticket_counters(service_id, scope_key, last_number) values ($1,$2,1)
       on conflict (service_id, scope_key) do update set last_number = ticket_counters.last_number + 1
       returning last_number`,
      [opts.serviceId, scope],
    );
    const seq: number = n.rows[0].last_number;
    const r = await c.query<TicketRow>(
      `insert into tickets(ticket_number, origin_service_id, service_id, scope_key, seq, priority, access_token, terminal_id)
       values ($1,$2,$2,$3,$4,$5,$6,$7) returning *`,
      [formatNumber(svc.code, seq), opts.serviceId, scope, seq, opts.priority ?? 0,
        randomBytes(16).toString('hex'), opts.terminalId ?? null],
    );
    await logEvent(c, r.rows[0].id, 'created', opts.userId ?? null, { terminal_id: opts.terminalId ?? null });
    return r.rows[0];
  });
  const snap = await snapshot(ticket.id);
  publish('ticket.created', snap, ticket.service_id);
  await publishQueue(ticket.service_id);
  return snap;
}

/** Ticket enrichi : service, guichet, position, personnes devant, estimation. */
export async function snapshot(ticketId: number, c: { query: pg.Pool['query'] } = pool) {
  const r = await c.query(
    `select t.*, s.name service_name, s.code service_code, s.color service_color,
            k.number counter_number, k.name counter_name
       from tickets t join services s on s.id=t.service_id
       left join counters k on k.id=t.counter_id where t.id=$1`,
    [ticketId],
  );
  if (!r.rows[0]) throw new HttpError(404, 'ticket_not_found');
  const t = r.rows[0];
  let ahead = 0;
  let estimate_minutes: number | null = null;
  if (t.status === 'waiting') {
    const a = await c.query(
      `select count(*)::int n from tickets
        where service_id=$1 and status='waiting' and id<>$4
          and (priority > $2 or (priority=$2 and (queue_at < $3 or (queue_at=$3 and id < $4))))`,
      [t.service_id, t.priority, t.queue_at, t.id],
    );
    ahead = a.rows[0].n;
    estimate_minutes = await estimateMinutes(t.service_id, ahead);
  }
  return { ...t, ahead, position: t.status === 'waiting' ? ahead + 1 : null, estimate_minutes };
}

async function estimateMinutes(serviceId: number, ahead: number): Promise<number> {
  const avg = await pool.query(
    `select avg(extract(epoch from (completed_at - coalesce(started_at, called_at)))) s
       from tickets where service_id=$1 and status='done' and completed_at > now() - interval '7 days'
        and completed_at > coalesce(started_at, called_at)`,
    [serviceId],
  );
  const perTicket = avg.rows[0].s ? Number(avg.rows[0].s) / 60 : Number(await getSetting('default_service_minutes'));
  const open = await pool.query(
    "select count(*)::int n from counters k join counter_services cs on cs.counter_id=k.id where cs.service_id=$1 and k.status='open'",
    [serviceId],
  );
  return Math.max(1, Math.round((ahead + 1) * perTicket / Math.max(open.rows[0].n, 1)));
}

/** Statut affiché sur la page QR (spécification §2.5). */
export function publicStatus(t: { status: Status; ahead: number }) {
  switch (t.status) {
    case 'waiting': return t.ahead <= 2 ? 'soon' : 'waiting';
    case 'called': return 'called';
    case 'serving': return 'serving';
    case 'done': return 'done';
    default: return 'cancelled'; // annulé ou absent
  }
}

export async function queueCounts() {
  const r = await pool.query(
    `select s.id service_id, s.name, s.code, s.color,
            count(t.id) filter (where t.status='waiting')::int waiting
       from services s left join tickets t on t.service_id=s.id and t.status='waiting'
      where s.active group by s.id order by s.id`,
  );
  return r.rows;
}

async function publishQueue(serviceId: number) {
  publish('queue.updated', { service_id: serviceId, services: await queueCounts() }, serviceId);
}

// ---------------------------------------------------------------- Guichets

async function lockCounter(c: pg.PoolClient, counterId: number) {
  const r = await c.query('select * from counters where id=$1 for update', [counterId]);
  if (!r.rows[0]) throw new HttpError(404, 'counter_not_found');
  return r.rows[0] as { id: number; number: number; status: 'open' | 'paused' | 'closed' };
}

export async function setCounterStatus(counterId: number, status: 'open' | 'paused' | 'closed', userId: number | null) {
  await tx(async (c) => {
    const k = await lockCounter(c, counterId);
    if (status !== 'open' && (await activeTicket(c, counterId)) && status === 'closed') {
      throw new HttpError(409, 'ticket_in_progress');
    }
    await c.query('update counters set status=$2 where id=$1', [counterId, status]);
    await c.query('insert into audit_logs(user_id,action,details) values ($1,$2,$3)', [
      userId, `counter.${status}`, JSON.stringify({ counter_id: counterId, number: k.number }),
    ]);
  });
  publish(status === 'paused' ? 'counter.paused' : status === 'open' ? 'counter.resumed' : 'counter.closed', { counter_id: counterId, status });
}

async function activeTicket(c: pg.PoolClient, counterId: number) {
  const r = await c.query<TicketRow>(
    "select * from tickets where counter_id=$1 and status in ('called','serving') order by called_at desc limit 1 for update",
    [counterId],
  );
  return r.rows[0] ?? null;
}

/** Appelle le prochain ticket : priorité du ticket, puis du service, puis ancienneté.
 *  SKIP LOCKED : deux guichets ne peuvent pas prendre le même ticket. */
export async function callNext(counterId: number, userId: number | null) {
  const id = await tx(async (c) => {
    const k = await lockCounter(c, counterId);
    if (k.status !== 'open') throw new HttpError(409, k.status === 'paused' ? 'counter_paused' : 'counter_closed');
    if (await activeTicket(c, counterId)) throw new HttpError(409, 'ticket_in_progress');
    const n = await c.query<TicketRow>(
      `select t.* from tickets t
         join counter_services cs on cs.service_id=t.service_id and cs.counter_id=$1
         join services s on s.id=t.service_id
        where t.status='waiting'
        order by t.priority desc, s.priority desc, t.queue_at, t.id
        limit 1 for update of t skip locked`,
      [counterId],
    );
    const t = n.rows[0];
    if (!t) throw new HttpError(404, 'queue_empty');
    await c.query("update tickets set status='called', counter_id=$2, called_at=now() where id=$1", [t.id, counterId]);
    await logEvent(c, t.id, 'called', userId, { counter_id: counterId });
    return t.id;
  });
  return emitTicket('ticket.called', id);
}

async function mustOwn(c: pg.PoolClient, ticketId: number, counterId: number, allowed: Status[]) {
  const r = await c.query<TicketRow>('select * from tickets where id=$1 for update', [ticketId]);
  const t = r.rows[0];
  if (!t) throw new HttpError(404, 'ticket_not_found');
  if (t.counter_id !== counterId) throw new HttpError(403, 'not_your_ticket');
  if (!allowed.includes(t.status)) throw new HttpError(409, `invalid_state:${t.status}`);
  return t;
}

async function emitTicket(event: string, ticketId: number) {
  const snap = await snapshot(ticketId);
  publish(event, snap, snap.service_id);
  await publishQueue(snap.service_id);
  return snap;
}

export async function recall(ticketId: number, counterId: number, userId: number | null) {
  await tx(async (c) => {
    await mustOwn(c, ticketId, counterId, ['called', 'serving']);
    await c.query('update tickets set called_at=now() where id=$1', [ticketId]);
    await logEvent(c, ticketId, 'recalled', userId);
  });
  return emitTicket('ticket.recalled', ticketId);
}

export async function start(ticketId: number, counterId: number, userId: number | null) {
  await tx(async (c) => {
    await mustOwn(c, ticketId, counterId, ['called']);
    await c.query("update tickets set status='serving', started_at=now() where id=$1", [ticketId]);
    await logEvent(c, ticketId, 'started', userId);
  });
  return emitTicket('ticket.started', ticketId);
}

export async function complete(ticketId: number, counterId: number, userId: number | null) {
  await tx(async (c) => {
    await mustOwn(c, ticketId, counterId, ['called', 'serving']);
    await c.query("update tickets set status='done', completed_at=now() where id=$1", [ticketId]);
    await logEvent(c, ticketId, 'completed', userId);
  });
  return emitTicket('ticket.completed', ticketId);
}

export async function markAbsent(ticketId: number, counterId: number, userId: number | null) {
  await tx(async (c) => {
    await mustOwn(c, ticketId, counterId, ['called']);
    await c.query("update tickets set status='absent', completed_at=now() where id=$1", [ticketId]);
    await logEvent(c, ticketId, 'absent', userId);
  });
  return emitTicket('ticket.absent', ticketId);
}

/** « Ignorer » : le ticket appelé retourne en file, derrière les autres de même priorité. */
export async function skip(ticketId: number, counterId: number, userId: number | null) {
  await tx(async (c) => {
    await mustOwn(c, ticketId, counterId, ['called']);
    await c.query("update tickets set status='waiting', counter_id=null, queue_at=now(), called_at=null where id=$1", [ticketId]);
    await logEvent(c, ticketId, 'skipped', userId);
  });
  return emitTicket('ticket.skipped', ticketId);
}

export async function transfer(ticketId: number, counterId: number, toServiceId: number, userId: number | null) {
  await tx(async (c) => {
    const t = await mustOwn(c, ticketId, counterId, ['called', 'serving']);
    const s = await c.query('select id, active from services where id=$1', [toServiceId]);
    if (!s.rows[0]?.active) throw new HttpError(404, 'service_not_found');
    await c.query(
      "update tickets set status='waiting', service_id=$2, counter_id=null, queue_at=now(), called_at=null, started_at=null where id=$1",
      [ticketId, toServiceId],
    );
    await logEvent(c, ticketId, 'transferred', userId, { from_service: t.service_id, to_service: toServiceId });
  });
  const snap = await emitTicket('ticket.transferred', ticketId);
  return snap;
}

export async function cancel(ticketId: number, userId: number | null) {
  await tx(async (c) => {
    const r = await c.query<TicketRow>('select * from tickets where id=$1 for update', [ticketId]);
    const t = r.rows[0];
    if (!t) throw new HttpError(404, 'ticket_not_found');
    if (!['waiting', 'called'].includes(t.status)) throw new HttpError(409, `invalid_state:${t.status}`);
    await c.query("update tickets set status='cancelled', completed_at=now() where id=$1", [ticketId]);
    await logEvent(c, ticketId, 'cancelled', userId);
  });
  return emitTicket('ticket.cancelled', ticketId);
}

export async function setPriority(ticketId: number, priority: number, userId: number | null) {
  await tx(async (c) => {
    const r = await c.query<TicketRow>('select * from tickets where id=$1 for update', [ticketId]);
    const t = r.rows[0];
    if (!t) throw new HttpError(404, 'ticket_not_found');
    if (t.status !== 'waiting') throw new HttpError(409, `invalid_state:${t.status}`);
    await c.query('update tickets set priority=$2 where id=$1', [ticketId, priority]);
    await logEvent(c, ticketId, 'priority_changed', userId, { from: t.priority, to: priority });
  });
  return emitTicket('ticket.priority', ticketId);
}

/** Réimpression : même numéro, compteur de réimpressions + trace. */
export async function noteReprint(ticketId: number, userId: number | null) {
  await tx(async (c) => {
    const r = await c.query('update tickets set reprint_count=reprint_count+1 where id=$1 returning id', [ticketId]);
    if (!r.rows[0]) throw new HttpError(404, 'ticket_not_found');
    await logEvent(c, ticketId, 'reprinted', userId);
  });
}

export async function noteEvent(ticketId: number, type: string, userId: number | null, details?: unknown) {
  await tx((c) => logEvent(c, ticketId, type, userId, details));
}

/** Remise à zéro manuelle : nouvelle époque, les numéros repartent à 001. */
export async function resetNumbering(userId: number | null) {
  const epoch = String(Number(await getSetting('counter_epoch')) + 1);
  await pool.query(
    `insert into settings(setting_key,setting_value) values ('counter_epoch',$1)
     on conflict (setting_key) do update set setting_value=excluded.setting_value`, [epoch]);
  await audit(userId, 'numbering.reset', { epoch });
  return epoch;
}

export async function agentState(counterId: number) {
  const k = await pool.query('select * from counters where id=$1', [counterId]);
  if (!k.rows[0]) throw new HttpError(404, 'counter_not_found');
  const cur = await pool.query(
    "select id from tickets where counter_id=$1 and status in ('called','serving') order by called_at desc limit 1", [counterId]);
  const stats = await pool.query(
    `select count(*) filter (where status='done')::int served,
            avg(extract(epoch from (completed_at - coalesce(started_at, called_at)))) filter (where status='done') avg_s
       from tickets where counter_id=$1 and created_at >= date_trunc('day', now() at time zone $2) at time zone $2`,
    [counterId, config.timezone]);
  const waiting = await pool.query(
    `select count(*)::int n from tickets t join counter_services cs on cs.service_id=t.service_id and cs.counter_id=$1
      where t.status='waiting'`, [counterId]);
  return {
    counter: k.rows[0],
    current: cur.rows[0] ? await snapshot(cur.rows[0].id) : null,
    waiting: waiting.rows[0].n,
    served: stats.rows[0].served,
    avg_handling_seconds: stats.rows[0].avg_s ? Math.round(Number(stats.rows[0].avg_s)) : null,
  };
}
