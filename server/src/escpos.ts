import net from 'node:net';

// Générateur ESC/POS (58 mm / 80 mm). Page de codes CP858 pour les accents français.
const CP858: Record<string, number> = {
  'é': 0x82, 'è': 0x8a, 'ê': 0x88, 'ë': 0x89, 'à': 0x85, 'â': 0x83, 'ä': 0x84, 'ç': 0x87,
  'ô': 0x93, 'ö': 0x94, 'û': 0x96, 'ù': 0x97, 'ü': 0x81, 'î': 0x8c, 'ï': 0x8b,
  'É': 0x90, 'È': 0xd4, 'Ê': 0xd2, 'À': 0xb7, 'Â': 0xb6, 'Ç': 0x80, 'Ô': 0xe2, 'Î': 0xd7, 'Û': 0xea,
  '€': 0xd5, '°': 0xf8, '’': 0x27,
};

function enc(text: string): Buffer {
  const out: number[] = [];
  for (const ch of text) {
    const code = ch.codePointAt(0)!;
    if (code < 0x80) out.push(code);
    else out.push(CP858[ch] ?? 0x3f);
  }
  return Buffer.from(out);
}

const ESC = 0x1b, GS = 0x1d;

export interface TicketPrint {
  org: string; service: string; number: string; date: string;
  ahead: number; estimate_minutes: number | null; message: string; qr_url: string;
}

export function buildTicket(t: TicketPrint, width: 58 | 80 = 80): Buffer {
  const cols = width === 58 ? 32 : 48;
  const parts: Buffer[] = [];
  const raw = (...b: number[]) => parts.push(Buffer.from(b));
  const line = (s = '') => parts.push(enc(s), Buffer.from([0x0a]));
  const center = (on: boolean) => raw(ESC, 0x61, on ? 1 : 0);
  const size = (w: number, h: number) => raw(GS, 0x21, ((w - 1) << 4) | (h - 1));
  const bold = (on: boolean) => raw(ESC, 0x45, on ? 1 : 0);

  raw(ESC, 0x40);        // initialisation
  raw(ESC, 0x74, 19);    // CP858
  center(true);
  bold(true); line(t.org); bold(false);
  line('-'.repeat(cols));
  line(t.service);
  size(3, 3); bold(true); line(t.number); bold(false); size(1, 1);
  line();
  line(t.date);
  line(t.ahead === 0 ? 'Vous etes le prochain' : `Personnes devant vous : ${t.ahead}`);
  if (t.estimate_minutes != null) line(`Attente estimee : ~${t.estimate_minutes} min`);
  line();
  // QR Code natif (GS ( k) : modèle 2, module 6, correction L
  const data = Buffer.from(t.qr_url, 'utf8');
  raw(GS, 0x28, 0x6b, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00);
  raw(GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x43, width === 58 ? 5 : 6);
  raw(GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x45, 0x30);
  const len = data.length + 3;
  raw(GS, 0x28, 0x6b, len & 0xff, len >> 8, 0x31, 0x50, 0x30);
  parts.push(data);
  raw(GS, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x51, 0x30);
  line();
  line('Scannez pour suivre votre attente');
  line(t.message);
  line(); line(); line();
  raw(GS, 0x56, 0x41, 0x10); // coupe partielle
  return Buffer.concat(parts);
}

/** Envoi direct à une imprimante réseau (port 9100). */
export function sendToNetworkPrinter(address: string, data: Buffer, timeoutMs = 4000): Promise<void> {
  const [host, port] = address.split(':');
  return new Promise((resolve, reject) => {
    const s = net.createConnection({ host, port: Number(port ?? 9100) });
    const fail = (e: Error) => { s.destroy(); reject(e); };
    s.setTimeout(timeoutMs, () => fail(new Error('printer_timeout')));
    s.once('error', fail);
    s.once('connect', () => s.end(data, () => resolve()));
  });
}
