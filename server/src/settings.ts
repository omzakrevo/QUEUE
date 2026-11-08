import { pool } from './db.js';

export const DEFAULTS: Record<string, string> = {
  reset_mode: 'daily',          // daily | session | manual
  counter_epoch: '0',           // incrémenté par la remise à zéro manuelle / de session
  default_service_minutes: '5', // durée moyenne supposée tant qu'il n'y a pas d'historique
  ticket_message: 'Merci de votre patience.',
  public_base_url: '',          // ex. http://192.168.1.10:3000 (sinon déduit de la requête)
  voice_enabled: 'true',
  voice_repeat: '1',
  voice_volume: '1',
  announce_template: 'Numéro {ticket}, veuillez vous présenter au guichet numéro {counter}.',
  ticker_message: 'Bienvenue',
  org_name: 'OMZA QUEUE',
};

type Q = { query: (sql: string, p?: unknown[]) => Promise<{ rows: any[] }> };

/** `db` : passer la connexion de la transaction en cours pour ne jamais réclamer une 2e connexion du pool. */
export async function getSetting(key: string, db: Q = pool): Promise<string> {
  const r = await db.query('select setting_value from settings where setting_key=$1', [key]);
  return r.rows[0]?.setting_value ?? DEFAULTS[key] ?? '';
}

export async function setSetting(key: string, value: string) {
  await pool.query(
    `insert into settings(setting_key, setting_value) values ($1,$2)
     on conflict (setting_key) do update set setting_value = excluded.setting_value`,
    [key, value],
  );
}

export async function allSettings(): Promise<Record<string, string>> {
  const r = await pool.query("select setting_key k, setting_value v from settings where setting_key <> 'jwt_secret'");
  const out = { ...DEFAULTS };
  for (const row of r.rows) out[row.k] = row.v;
  return out;
}
