import type { Server } from 'socket.io';

let io: Server | null = null;
export function setIo(s: Server) { io = s; }

// Événements temps réel (spécification §3.6). Les clients authentifiés (agents, TV, admin)
// reçoivent la charge complète ; le canal public (/public, pages QR) ne reçoit qu'un signal
// sans donnée de ticket : chaque client rafraîchit alors son propre statut via son jeton.
/** Nombre d'appareils connectés par rôle (agents, écrans, bornes). */
export async function presence(): Promise<Record<string, number>> {
  const out: Record<string, number> = {};
  if (!io) return out;
  for (const role of ['agent', 'affichage', 'borne', 'administrateur', 'superviseur']) {
    out[role] = (await io.in(`role:${role}`).fetchSockets()).length;
  }
  return out;
}

export function publish(event: string, payload: unknown, serviceId?: number) {
  if (!io) return;
  io.to('all').emit(event, payload);
  io.of('/public').emit('queue.updated', { service_id: serviceId ?? null });
}
