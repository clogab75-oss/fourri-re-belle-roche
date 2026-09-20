/* Mise en page de l'espace personnel : menu latéral + contenu. */
import { h, icon, pill } from './ui.js';
import { state, isManager, isAdmin } from './api.js';
import { ROLE } from './format.js';

export function adminLayout(active, ...content) {
  const items = [
    ['/admin', 'dashboard', 'Tableau de bord', 'dash'],
    ['/admin/vehicules', 'car', 'Véhicules', 'veh'],
    ['/messages', 'message', 'Messages', 'msg', state.unread.messages],
    isManager() && ['/admin/ventes', 'tag', 'Ventes', 'sales'],
    ['/admin/personnel', 'users', 'Personnel', 'staff'],
    ['/admin/stats', 'chart', 'Statistiques', 'stats'],
    isManager() && ['/admin/tarifs', 'euro', 'Tarifs', 'pricing'],
    isManager() && ['/admin/historique', 'history', 'Historique', 'history'],
    isManager() && ['/admin/discord', 'discord', 'Discord', 'discord'],
  ].filter(Boolean);
  const p = state.profile;
  const nav = h('nav', { class: 'side', 'aria-label': 'Espace personnel' },
    h('div', { class: 'me' }, h('div', { class: 'n' }, `${p.prenom} ${p.nom}`), h('div', { class: 'small' }, ROLE[p.role] + (isAdmin() ? ' principal' : ''))),
    h('h4', {}, 'Gestion'),
    items.map(([href, ic, label, key, n]) => h('a', { href: '#' + href, 'aria-current': key === active ? 'page' : null }, icon(ic), label, key === 'msg' ? h('span', { dataset: { badge: 'messages' } }, pill(n)) : null)),
    h('h4', {}, 'Site'),
    h('a', { href: '#/vehicules' }, icon('search'), 'Page publique'));
  return h('div', { class: 'admin' }, nav, h('div', { class: 'admin-main' }, content));
}
export const pageHead = (title, sub, ...actions) => h('div', { class: 'page-head' }, h('div', {}, h('h1', { style: { fontSize: 'clamp(1.8rem,4vw,2.4rem)' } }, title), sub ? h('p', {}, sub) : null), actions.length ? h('div', { class: 'row' }, actions) : null);
