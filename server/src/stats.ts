import { pool, HttpError } from './db.js';
import { config } from './config.js';

export type Period = 'today' | 'yesterday' | 'week' | 'month' | 'custom';

/** Bornes [from, to) de la période, calculées dans le fuseau de l'établissement. */
export async function range(period: Period, from?: string, to?: string): Promise<{ from: Date; to: Date }> {
  const tz = config.timezone;
  const q = async (sql: string, p: unknown[] = []) => (await pool.query(sql, [tz, ...p])).rows[0];
  switch (period) {
    case 'today': {
      const r = await q("select date_trunc('day', now() at time zone $1) at time zone $1 f, (date_trunc('day', now() at time zone $1) + interval '1 day') at time zone $1 t");
      return { from: r.f, to: r.t };
    }
    case 'yesterday': {
      const r = await q("select (date_trunc('day', now() at time zone $1) - interval '1 day') at time zone $1 f, date_trunc('day', now() at time zone $1) at time zone $1 t");
      return { from: r.f, to: r.t };
    }
    case 'week': {
      const r = await q("select date_trunc('week', now() at time zone $1) at time zone $1 f, (date_trunc('week', now() at time zone $1) + interval '7 days') at time zone $1 t");
      return { from: r.f, to: r.t };
    }
    case 'month': {
      const r = await q("select date_trunc('month', now() at time zone $1) at time zone $1 f, (date_trunc('month', now() at time zone $1) + interval '1 month') at time zone $1 t");
      return { from: r.f, to: r.t };
    }
    case 'custom': {
      if (!from || !to || isNaN(Date.parse(from)) || isNaN(Date.parse(to))) throw new HttpError(400, 'invalid_range');
      const r = await q("select ($2::date)::timestamp at time zone $1 f, (($3::date) + 1)::timestamp at time zone $1 t", [from, to]);
      return { from: r.f, to: r.t };
    }
    default:
      throw new HttpError(400, 'invalid_period');
  }
}

export async function summary(period: Period, from?: string, to?: string) {
  const r = await range(period, from, to);
  const p = [r.from, r.to];
  const totals = await pool.query(
    `select count(*)::int total,
            count(*) filter (where status='done')::int served,
            count(*) filter (where status='absent')::int absent,
            count(*) filter (where status='cancelled')::int cancelled,
            round(avg(extract(epoch from (called_at - created_at))) filter (where called_at is not null))::int avg_wait_s,
            round(avg(extract(epoch from (completed_at - coalesce(started_at, called_at)))) filter (where status='done'))::int avg_handling_s
       from tickets where created_at >= $1 and created_at < $2`, p);
  const byService = await pool.query(
    `select s.id, s.name, s.code, count(t.id)::int total,
            count(t.id) filter (where t.status='done')::int served,
            round(avg(extract(epoch from (t.called_at - t.created_at))) filter (where t.called_at is not null))::int avg_wait_s,
            round(avg(extract(epoch from (t.completed_at - coalesce(t.started_at, t.called_at)))) filter (where t.status='done'))::int avg_handling_s
       from services s left join tickets t on t.origin_service_id=s.id and t.created_at >= $1 and t.created_at < $2
      group by s.id order by s.id`, p);
  const byCounter = await pool.query(
    `select k.id, k.name, k.number, count(t.id) filter (where t.status='done')::int served,
            count(t.id) filter (where t.status='absent')::int absent,
            round(avg(extract(epoch from (t.completed_at - coalesce(t.started_at, t.called_at)))) filter (where t.status='done'))::int avg_handling_s
       from counters k left join tickets t on t.counter_id=k.id and t.created_at >= $1 and t.created_at < $2
      group by k.id order by k.number`, p);
  const byAgent = await pool.query(
    `select u.id, u.name, count(*)::int served
       from ticket_events e join users u on u.id=e.user_id
      where e.event_type='completed' and e.created_at >= $1 and e.created_at < $2
      group by u.id order by served desc`, p);
  const hours = await pool.query(
    `select extract(hour from created_at at time zone $3)::int as hour, count(*)::int as tickets
       from tickets where created_at >= $1 and created_at < $2 group by 1 order by 1`, [...p, config.timezone]);
  return { from: r.from, to: r.to, totals: totals.rows[0], by_service: byService.rows, by_counter: byCounter.rows, by_agent: byAgent.rows, by_hour: hours.rows };
}

const csvCell = (v: unknown) => {
  const s = v instanceof Date ? v.toISOString() : String(v ?? '');
  // Neutralise l'injection de formules à l'ouverture dans Excel.
  const safe = /^[=+\-@]/.test(s) ? `'${s}` : s;
  return /[",;\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
};

export async function exportCsv(period: Period, from?: string, to?: string): Promise<string> {
  const r = await range(period, from, to);
  const rows = await pool.query(
    `select t.ticket_number, s.name service, k.number counter, t.status, t.priority,
            t.created_at, t.called_at, t.started_at, t.completed_at,
            extract(epoch from (t.called_at - t.created_at))::int wait_seconds,
            extract(epoch from (t.completed_at - coalesce(t.started_at, t.called_at)))::int handling_seconds
       from tickets t join services s on s.id=t.origin_service_id left join counters k on k.id=t.counter_id
      where t.created_at >= $1 and t.created_at < $2 order by t.created_at`, [r.from, r.to]);
  const cols = ['ticket_number', 'service', 'counter', 'status', 'priority', 'created_at', 'called_at', 'started_at', 'completed_at', 'wait_seconds', 'handling_seconds'];
  return '﻿' + [cols.join(';'), ...rows.rows.map((row) => cols.map((c) => csvCell(row[c])).join(';'))].join('\r\n') + '\r\n';
}
