/* Démarrage du site : session, en-tête, routes, actualisations régulières. */
import { cfg, configured, sb, state, subscribe, syncSession, refreshUnread, heartbeat, isLogged, isStaff, isManager, isPolice, authFlow, logout, notifications, markNotifications, watch } from './lib/api.js';
import { h, icon, pill, loading } from './lib/ui.js';
import { add, start, navigate, refresh } from './lib/router.js';
import { rel, initials } from './lib/format.js';

const app = document.getElementById('app');

function setup() {
  app.replaceChildren(h('div', { class: 'setup-screen' }, h('div', { class: 'card card-pad stack' },
    h('h1', {}, 'Configuration requise'),
    h('p', {}, 'Le site n\'est pas encore relié à Supabase. Ouvrez le fichier ', h('span', { class: 'kbd' }, 'js/config.js'), ' et renseignez SUPABASE_URL et SUPABASE_KEY (voir le README).'))));
}

/* ---------- Routes ---------- */
const P = (file, name = 'default') => () => import(`./pages/${file}.js`).then((m) => m[name]);
add('/', 'public', P('home'));
add('/vehicules', 'public', P('lists', 'impoundPage'));
add('/vente', 'public', P('lists', 'salePage'));
add('/connexion', 'guest', P('auth', 'login'));
add('/inscription', 'guest', P('auth', 'register'));
add('/mot-de-passe-oublie', 'guest', P('auth', 'forgot'));
add('/compte', 'auth', P('account'));
add('/messages', 'auth', P('messages'));
add('/messages/:id', 'auth', P('messages'));
add('/admin', 'staff', P('admin', 'dashboard'));
add('/admin/stats', 'staff', P('admin', 'statsPage'));
add('/admin/vehicules', 'staff', P('admin-vehicles', 'list'));
add('/admin/vehicules/:id', 'staff', P('admin-vehicles', 'detail'));
add('/admin/ventes', 'manager', P('admin-sales'));
add('/admin/personnel', 'staff', P('admin-staff'));
add('/admin/tarifs', 'manager', P('admin-settings', 'pricing'));
add('/admin/codes', 'manager', P('admin-codes'));
add('/admin/historique', 'manager', P('admin-settings', 'history'));
add('/admin/discord', 'manager', P('admin-settings', 'discord'));
add('/saisies', 'saisies', P('seizures'));

const access = (g) => {
  if (g === 'public') return 'ok';
  if (g === 'guest') return isLogged() ? 'guest' : 'ok';
  if (!isLogged()) return 'login';
  if (g === 'auth') return 'ok';
  if (g === 'staff') return isStaff() ? 'ok' : 'forbidden';
  if (g === 'manager') return isManager() ? 'ok' : 'forbidden';
  if (g === 'saisies') return (isStaff() || isPolice()) ? 'ok' : 'forbidden';
  return 'forbidden';
};

/* ---------- En-tête ---------- */
const header = h('header', { class: 'site-header' });
const view = h('main', { id: 'view', tabindex: '-1' });
let navOpen = false; let path = '/'; let popHost = null; let stopLive = null; let lastKey = null;

const isActive = (href) => (href === '/' ? path === '/' : path === href || path.startsWith(href + '/'));
const authKey = () => (isLogged() ? state.profile.id + state.profile.role : 'anon');

function renderHeader() {
  popOpen = false; document.removeEventListener('click', outside); document.removeEventListener('keydown', escPop);
  const logged = isLogged();
  const links = [['/', 'Accueil'], ['/vehicules', 'Véhicules en fourrière'], ['/vente', 'À vendre']];
  if (logged && !isPolice()) links.push(['/messages', 'Messages', 'messages']);
  if (isPolice() && !isStaff()) links.push(['/saisies', 'Saisies']);
  if (isStaff()) links.push(['/admin', 'Espace personnel']);
  const nav = h('nav', { class: `main-nav${navOpen ? ' open' : ''}`, id: 'main-nav', 'aria-label': 'Navigation principale' },
    links.map(([href, label, badge]) => h('a', { href: '#' + href, 'aria-current': isActive(href) ? 'page' : null, onClick: () => { navOpen = false; nav.classList.remove('open'); } },
      label, badge ? h('span', { dataset: { badge } }) : null)));
  const burger = h('button', { class: 'btn-icon burger', type: 'button', 'aria-label': 'Menu', 'aria-expanded': String(navOpen), 'aria-controls': 'main-nav',
    onClick: () => { navOpen = !navOpen; nav.classList.toggle('open', navOpen); burger.setAttribute('aria-expanded', String(navOpen)); } }, icon('menu'));
  popHost = h('div', { class: 'pop-wrap' });
  const bell = h('button', { class: 'btn-icon', type: 'button', 'aria-label': 'Notifications', 'aria-haspopup': 'dialog', onClick: () => togglePop() }, icon('bell'), h('span', { class: 'bell-badge', dataset: { badge: 'notifications' } }));
  const actions = h('div', { class: 'header-actions' },
    logged ? h('div', { class: 'pop-wrap' }, bell, popHost) : null,
    logged
      ? h('a', { class: 'user-chip', href: '#/compte', 'aria-label': 'Mon compte' }, h('span', { class: 'avatar' }, initials(state.profile)), h('span', { class: 'nm' }, state.profile.prenom))
      : [h('a', { class: 'btn secondary sm hide-sm', href: '#/connexion' }, 'Connexion'), h('a', { class: 'btn sm', href: '#/inscription' }, 'Inscription')],
    h('a', { class: 'btn-discord', href: cfg.DISCORD_INVITE, target: '_blank', rel: 'noopener noreferrer', 'aria-label': 'Rejoindre notre serveur Discord' }, icon('discord'), h('span', {}, 'Discord')));
  header.replaceChildren(h('div', { class: 'container header-in' },
    h('a', { class: 'brand', href: '#/', 'aria-label': `${cfg.SITE_NAME} — accueil` }, h('img', { src: 'assets/img/logo-256.png', alt: cfg.SITE_NAME })),
    nav, actions, burger));
  updateBadges();
}
function updateBadges() {
  document.querySelectorAll('[data-badge]').forEach((slot) => {
    const n = slot.dataset.badge === 'messages' ? state.unread.messages : state.unread.notifications;
    slot.replaceChildren(...(n > 0 ? [pill(n)] : []));
  });
  const n = state.unread.notifications + (state.unread.messages ? 0 : 0);
  document.title = (n > 0 ? `(${n}) ` : '') + cfg.SITE_NAME;
}

/* Notifications */
let popOpen = false;
const closePop = () => { popOpen = false; if (popHost) popHost.replaceChildren(); document.removeEventListener('click', outside); document.removeEventListener('keydown', escPop); };
const outside = (e) => { if (popHost && !popHost.parentElement.contains(e.target)) closePop(); };
const escPop = (e) => { if (e.key === 'Escape') closePop(); };
async function togglePop() {
  if (popOpen) return closePop();
  popOpen = true;
  const list = h('div', { class: 'pop-list' }, loading());
  const all = h('button', { class: 'btn sm ghost', type: 'button', onClick: async () => { await markNotifications(null); await refreshUnread(); fill(); } }, 'Tout marquer comme lu');
  popHost.replaceChildren(h('div', { class: 'card pop', role: 'dialog', 'aria-label': 'Notifications' }, h('div', { class: 'pop-head' }, 'Notifications', all), list));
  setTimeout(() => { document.addEventListener('click', outside); document.addEventListener('keydown', escPop); }, 0);
  async function fill() {
    try {
      const rows = await notifications();
      list.replaceChildren(...(rows.length ? rows.map((n) => h('button', { class: `notif${n.read_at ? '' : ' unread'}`, type: 'button', onClick: async () => {
        closePop();
        if (!n.read_at) { await markNotifications([n.id]); refreshUnread(); }
        if (n.link && n.link.startsWith('#/')) location.hash = n.link;
      } }, h('div', { class: 't' }, n.title + (n.count > 1 ? ` (${n.count})` : '')), n.body ? h('div', { class: 'b' }, n.body) : null, h('div', { class: 'd' }, rel(n.created_at))))
        : [h('div', { class: 'empty' }, 'Aucune notification')]));
    } catch (e) { list.replaceChildren(h('div', { class: 'empty' }, e.message)); }
  }
  fill();
}

/* Temps réel : compteurs de non-lus */
function live() {
  if (stopLive) { stopLive(); stopLive = null; }
  if (!isLogged()) return;
  stopLive = watch([{ table: 'notifications', filter: `user_id=eq.${state.profile.id}` }, { table: 'messages' }], refreshUnread, 300);
}

const footer = h('footer', { class: 'site-footer' }, h('div', { class: 'hazard' }), h('div', { class: 'container footer-in' },
  h('div', {}, h('strong', {}, cfg.SITE_NAME), h('div', { class: 'small' }, 'Aucun paiement réel n\'est effectué sur ce site : tous les montants sont fictifs.')),
  h('a', { href: cfg.DISCORD_INVITE, target: '_blank', rel: 'noopener noreferrer' }, 'Rejoindre le Discord')));

async function boot() {
  if (!configured) return setup();
  await syncSession();
  app.replaceChildren(header, view, footer);
  lastKey = authKey();
  renderHeader(); live();
  subscribe(() => {
    if (authKey() !== lastKey) { lastKey = authKey(); navOpen = false; renderHeader(); live(); refreshUnread(); }
    else updateBadges();
  });
  sb.auth.onAuthStateChange((event) => {
    setTimeout(async () => {
      if (authFlow.busy || event === 'INITIAL_SESSION' || event === 'TOKEN_REFRESHED') return;
      const before = isLogged();
      await syncSession();
      if (before !== isLogged()) refresh();
    }, 0);
  });
  start(view, { access, onRoute: (p) => { path = p; navOpen = false; renderHeader(); view.focus({ preventScroll: true }); } });
  refreshUnread(); heartbeat();
  setInterval(refreshUnread, 20000);
  setInterval(heartbeat, 60000);
}
boot().catch((e) => { console.error(e); app.replaceChildren(h('div', { class: 'setup-screen' }, h('div', { class: 'card card-pad' }, h('h1', {}, 'Oups'), h('p', {}, 'Le site n\'a pas pu démarrer : ' + (e.message || e))))); });
export { navigate, logout };
