/* Routeur à base de « # » (compatible GitHub Pages : aucune configuration serveur). */
import { h, loading } from './ui.js';
const routes = [];
let view, hooks, token = 0, current = null;

export const add = (pattern, guard, load) => {
  const keys = [];
  const re = new RegExp('^' + pattern.replace(/:[^/]+/g, (m) => { keys.push(m.slice(1)); return '([^/]+)'; }) + '/?$');
  routes.push({ pattern, re, keys, guard, load });
};
export function parse() {
  const raw = location.hash.replace(/^#/, '') || '/';
  const i = raw.indexOf('?');
  return { path: (i < 0 ? raw : raw.slice(0, i)) || '/', query: Object.fromEntries(new URLSearchParams(i < 0 ? '' : raw.slice(i + 1))), full: raw };
}
export function navigate(path, replace = false) {
  if (replace) location.replace('#' + path); else location.hash = '#' + path;
}
export const refresh = () => resolve();

function show(out) {
  if (current && current.destroy) { try { current.destroy(); } catch { /* rien */ } }
  const el = out instanceof Node ? out : out.el;
  current = out instanceof Node ? null : out;
  view.replaceChildren(el);
}
const message = (title, text, actions) => h('div', { class: 'container page' }, h('div', { class: 'empty' }, h('h2', {}, title), h('p', { style: { margin: '8px 0 16px' } }, text), actions));

async function resolve() {
  const my = ++token;
  const { path, query, full } = parse();
  if (current && current.destroy) { try { current.destroy(); } catch { /* rien */ } current = null; }
  const r = routes.find((x) => x.re.test(path));
  if (!r) { show(message('Page introuvable', "Cette page n'existe pas.", h('a', { class: 'btn', href: '#/' }, "Retour à l'accueil"))); hooks.onRoute(path); return; }
  const m = path.match(r.re);
  const params = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])]));
  const access = hooks.access(r.guard);
  if (access === 'login') return navigate('/connexion?next=' + encodeURIComponent(full), true);
  if (access === 'guest') return navigate('/', true);
  if (access === 'forbidden') { show(message('Accès refusé', "Vous n'avez pas les droits pour voir cette page.", h('a', { class: 'btn', href: '#/' }, "Retour à l'accueil"))); hooks.onRoute(path); return; }
  view.replaceChildren(loading());
  try {
    const page = await r.load();
    const out = await page({ params, query, path, navigate, refresh });
    if (my !== token) { if (out && out.destroy) out.destroy(); return; }
    show(out);
    window.scrollTo(0, 0);
  } catch (e) {
    if (my !== token) return;
    console.error(e);
    show(message('Un problème est survenu', e.message || 'Impossible de charger la page.', h('button', { class: 'btn', onClick: resolve }, 'Réessayer')));
  }
  hooks.onRoute(path);
}
export function start(container, h2) { view = container; hooks = h2; window.addEventListener('hashchange', resolve); resolve(); }
