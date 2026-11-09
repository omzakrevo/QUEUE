// Outils communs : session, appels API, connexion Socket.IO (tout est servi localement).
window.Q = (() => {
  const KEY = 'omza_queue_token';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const store = { get: () => { try { return localStorage.getItem(KEY); } catch { return null; } },
                  set: (v) => { try { v ? localStorage.setItem(KEY, v) : localStorage.removeItem(KEY); } catch {} } };
  async function api(path, opts = {}) {
    const r = await fetch(path, {
      method: opts.method || (opts.body ? 'POST' : 'GET'),
      headers: { 'content-type': 'application/json', ...(store.get() ? { authorization: 'Bearer ' + store.get() } : {}) },
      body: opts.body ? JSON.stringify(opts.body) : undefined,
    });
    if (r.status === 401) { store.set(null); location.reload(); throw new Error('unauthorized'); }
    const ct = r.headers.get('content-type') || '';
    const data = ct.includes('json') ? await r.json() : await r.text();
    if (!r.ok) throw Object.assign(new Error(data.error || r.statusText), { code: data.error });
    return data;
  }
  // roles : rôles autorisés sur cette page. Affiche un formulaire de connexion si nécessaire.
  async function start(roles, onReady) {
    document.body.insertAdjacentHTML('beforeend',
      `<div id="login"><form class="card"><h1>OMZA QUEUE</h1><input name="u" placeholder="Identifiant" autocomplete="username" required>
       <input name="p" type="password" placeholder="Mot de passe" autocomplete="current-password" required>
       <div class="err" id="loginErr"></div><button>Se connecter</button></form></div>`);
    const box = document.getElementById('login');
    const show = (msg) => { box.style.display = 'flex'; document.getElementById('loginErr').textContent = msg || ''; };
    box.querySelector('form').onsubmit = async (e) => {
      e.preventDefault();
      const f = e.target;
      try {
        const r = await api('/api/auth/login', { body: { username: f.u.value, password: f.p.value } });
        store.set(r.token); location.reload();
      } catch (err) { show(err.code === 'too_many_attempts' ? 'Trop d’essais, patientez 1 minute.' : 'Identifiants incorrects.'); }
    };
    if (!store.get()) return show();
    let me;
    try { me = await api('/api/auth/me'); } catch { return show(); }
    if (roles && !roles.includes(me.role)) { store.set(null); return show('Ce compte n’a pas accès à cette page.'); }
    onReady(me);
  }
  const socket = () => io({ auth: { token: store.get() } });
  const logout = () => { store.set(null); location.reload(); };
  const fmtSec = (s) => s == null ? '—' : s < 60 ? s + ' s' : Math.round(s / 60) + ' min';
  return { api, start, socket, logout, esc, fmtSec };
})();
