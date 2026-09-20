/* Composants d'affichage réutilisés par plusieurs pages. */
import { h, icon, badge, lightbox } from './ui.js';
import { photoUrl } from './api.js';
import { colorHex, money, dt, rel } from './format.js';

export const plateEl = (text, size = '') => h('span', { class: `plate ${size}`.trim() }, h('span', { class: 'txt' }, text));
export function colorTag(color) {
  const hex = colorHex(color);
  return h('span', {}, hex ? h('span', { class: 'swatch', style: { background: hex } }) : null, color);
}
/* Accepte des chemins (public) ou des objets {path} (vue vehicles_ext) */
export const pathsOf = (photos) => (photos || []).map((p) => (typeof p === 'string' ? p : p.path));
export function photoBlock(photos, statusBadge) {
  const urls = pathsOf(photos).map(photoUrl);
  const b = h('button', { class: 'vphoto', type: 'button', 'aria-label': urls.length ? 'Voir les photos' : 'Aucune photo', onClick: () => lightbox(urls, 0) },
    urls.length ? h('img', { src: urls[0], alt: '', loading: 'lazy' }) : h('div', { class: 'noimg' }, icon('image')),
    statusBadge ? h('span', { class: 'tag' }, statusBadge) : null,
    urls.length > 1 ? h('span', { class: 'cnt' }, icon('camera'), urls.length) : null);
  return b;
}
export function meta(rows) {
  return h('dl', { class: 'vmeta' }, rows.filter(Boolean).map(([k, v]) => h('div', {}, h('dt', {}, k), h('dd', {}, v))));
}
export function meter(label, amount) {
  return h('div', { class: 'meter' }, h('span', { class: 'lbl' }, label), h('span', { class: 'amt num' }, money(amount)));
}
export const arrival = (d) => `${dt(d)} (${rel(d)})`;
export { badge };
