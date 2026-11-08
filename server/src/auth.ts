import { randomBytes, scrypt as _scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import jwt from 'jsonwebtoken';
import type { Request, Response, NextFunction } from 'express';
import { pool, HttpError } from './db.js';

const scrypt = promisify(_scrypt) as (p: string, s: Buffer, n: number) => Promise<Buffer>;

export type Role = 'administrateur' | 'superviseur' | 'agent' | 'responsable' | 'borne' | 'affichage';
export interface AuthUser { id: number; username: string; name: string; role: Role }

export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  const h = await scrypt(pw, salt, 64);
  return `scrypt$${salt.toString('hex')}$${h.toString('hex')}`;
}

export async function verifyPassword(pw: string, stored: string): Promise<boolean> {
  const [alg, saltHex, hashHex] = stored.split('$');
  if (alg !== 'scrypt' || !saltHex || !hashHex) return false;
  const h = await scrypt(pw, Buffer.from(saltHex, 'hex'), 64);
  const expected = Buffer.from(hashHex, 'hex');
  return h.length === expected.length && timingSafeEqual(h, expected);
}

// Secret JWT : variable d'environnement, sinon généré une fois et conservé en base.
let secret: string | null = null;
export async function jwtSecret(): Promise<string> {
  if (secret) return secret;
  if (process.env.JWT_SECRET) return (secret = process.env.JWT_SECRET);
  await pool.query(
    "insert into settings(setting_key, setting_value) values ('jwt_secret',$1) on conflict (setting_key) do nothing",
    [randomBytes(32).toString('hex')],
  );
  const r = await pool.query("select setting_value from settings where setting_key='jwt_secret'");
  return (secret = r.rows[0].setting_value);
}

// Bornes et écrans sont des appareils fixes : jeton longue durée. Les personnes : 12 h.
export async function signToken(u: AuthUser): Promise<string> {
  const device = u.role === 'borne' || u.role === 'affichage';
  return jwt.sign(u, await jwtSecret(), { expiresIn: device ? '365d' : '12h' });
}

export async function verifyToken(token: string): Promise<AuthUser> {
  try {
    const p = jwt.verify(token, await jwtSecret()) as AuthUser;
    const r = await pool.query('select status from users where id=$1', [p.id]);
    if (r.rows[0]?.status !== 'active') throw new Error('disabled');
    return { id: p.id, username: p.username, name: p.name, role: p.role };
  } catch {
    throw new HttpError(401, 'unauthorized');
  }
}

declare module 'express-serve-static-core' {
  interface Request { user?: AuthUser }
}

export function requireAuth(...roles: Role[]) {
  return async (req: Request, _res: Response, next: NextFunction) => {
    try {
      const h = req.headers.authorization;
      if (!h?.startsWith('Bearer ')) throw new HttpError(401, 'unauthorized');
      const user = await verifyToken(h.slice(7));
      if (roles.length && !roles.includes(user.role)) throw new HttpError(403, 'forbidden');
      req.user = user;
      next();
    } catch (e) {
      next(e);
    }
  };
}

// Limitation simple des tentatives de connexion (par nom d'utilisateur + IP).
const attempts = new Map<string, { n: number; until: number }>();
export function checkLoginThrottle(key: string) {
  const a = attempts.get(key);
  if (a && a.n >= 5 && Date.now() < a.until) throw new HttpError(429, 'too_many_attempts');
}
export function noteLogin(key: string, ok: boolean) {
  if (ok) {
    attempts.delete(key);
    return;
  }
  const a = attempts.get(key) ?? { n: 0, until: 0 };
  a.n += 1;
  a.until = Date.now() + 60_000;
  attempts.set(key, a);
}
