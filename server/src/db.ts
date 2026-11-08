import pg from 'pg';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { config } from './config.js';

// int8 (ids de tickets) lus comme nombres.
pg.types.setTypeParser(20, (v) => Number(v));

export let pool = new pg.Pool({ connectionString: config.databaseUrl, max: 20 });

export function useDatabase(url: string) {
  pool = new pg.Pool({ connectionString: url, max: 20 });
  return pool;
}

export async function tx<T>(fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const c = await pool.connect();
  try {
    await c.query('begin');
    const r = await fn(c);
    await c.query('commit');
    return r;
  } catch (e) {
    await c.query('rollback').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

export async function migrate() {
  const sql = readFileSync(fileURLToPath(new URL('../db/schema.sql', import.meta.url)), 'utf8');
  await pool.query(sql);
}

export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}
