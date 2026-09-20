/* Petits utilitaires d'interface. Le texte est TOUJOURS inséré comme texte (jamais en HTML) : pas de faille XSS. */
import { icon } from './icons.js';
import { STATUS } from './format.js';
export { icon };

export function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'style' && typeof v === 'object') { for (const [a, b] of Object.entries(v)) { if (a.startsWith('--')) el.style.setProperty(a, b); else el.style[a] = b; } }
      else if (k === 'dataset') Object.assign(el.dataset, v);
      else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2).toLowerCase(), v);
      else if (v === true) el.setAttribute(k, '');
      else el.setAttribute(k, String(v));
    }
  }
  add(el, kids);
  return el;
}
function add(el, kids) {
  for (const k of kids.flat(Infinity)) {
    if (k == null || k === false) continue;
    el.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
}
/* replaceChildren tolérant : ignore null/false et aplatit les listes (le natif écrirait « null » à l'écran). */
const nativeReplace = Element.prototype.replaceChildren;
Element.prototype.replaceChildren = function replaceChildren(...kids) {
  return nativeReplace.apply(this, kids.flat(Infinity).filter((k) => k != null && k !== false));
};
export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
export const clear = (el) => { el.replaceChildren(); return el; };
export function debounce(fn, ms = 250) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }

export function toast(msg, type = 'info', ms = 4800) {
  const box = document.getElementById('toasts');
  if (!box) return;
  const t = h('div', { class: `toast ${type}`, role: type === 'error' ? 'alert' : 'status' }, h('div', {}, msg));
  box.append(t);
  setTimeout(() => t.remove(), ms);
}

export function badge(status) {
  const [label, tone] = STATUS[status] || [status, 'gray'];
  return h('span', { class: `badge ${tone}` }, label);
}
export const pill = (n) => (n > 0 ? h('span', { class: 'count-pill', 'aria-label': `${n} non lu(s)` }, n > 99 ? '99+' : n) : null);

export function loading(text = '') { return h('div', { class: 'loading-center', role: 'status' }, h('div', { class: 'spinner' }), text ? h('p', { class: 'muted small' }, text) : null); }
export function empty(title, text, action) {
  return h('div', { class: 'empty' }, icon('car', 'icon'), h('h3', {}, title), text ? h('p', {}, text) : null, action ? h('div', { style: { marginTop: '14px' } }, action) : null);
}
export function field(label, input, hint) {
  const id = input.id || (input.id = 'f' + Math.random().toString(36).slice(2, 8));
  return h('div', { class: 'field' }, h('label', { for: id }, label), input, hint ? h('span', { class: 'hint' }, hint) : null);
}
export const btn = (label, { kind = '', onClick, type = 'button', ic, sm, disabled, title } = {}) =>
  h('button', { class: `btn ${kind} ${sm ? 'sm' : ''}`.trim(), type, onClick, disabled, title }, ic ? icon(ic) : null, label);

/* Empêche le double clic et affiche l'erreur */
export async function busy(button, fn) {
  if (button.disabled) return undefined;
  button.disabled = true; button.setAttribute('aria-busy', 'true');
  try { return await fn(); }
  catch (e) { toast(e.message || 'Une erreur est survenue.', 'error'); return undefined; }
  finally { button.disabled = false; button.removeAttribute('aria-busy'); }
}

export function openModal({ title, body, actions = [], wide = false, persistent = false, onClose } = {}) {
  const prev = document.activeElement;
  const tid = 'm' + Math.random().toString(36).slice(2, 8);
  let closed = false;
  const onKey = (e) => { if (e.key === 'Escape' && !persistent) close(); };
  const close = (result) => {
    if (closed) return; closed = true;
    document.removeEventListener('keydown', onKey); ov.remove(); document.body.style.overflow = '';
    if (prev && prev.focus) prev.focus();
    if (onClose) onClose(result);
  };
  const dlg = h('div', { class: `dialog${wide ? ' wide' : ''}`, role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': tid },
    h('div', { class: 'dialog-head' }, h('h3', { id: tid }, title), h('button', { class: 'btn-icon', type: 'button', 'aria-label': 'Fermer', onClick: () => close() }, icon('x'))),
    h('div', { class: 'dialog-body' }, body),
    actions.length ? h('div', { class: 'dialog-foot' }, actions) : null);
  const ov = h('div', { class: 'overlay', onMousedown: (e) => { if (e.target === ov && !persistent) close(); } }, dlg);
  document.body.append(ov); document.body.style.overflow = 'hidden';
  document.addEventListener('keydown', onKey);
  const first = dlg.querySelector('input:not([type=hidden]),textarea,select'); if (first) first.focus();
  return { close, el: dlg };
}

export function confirmDialog({ title, message, confirmLabel = 'Confirmer', danger = false, body }) {
  return new Promise((resolve) => {
    let m; let done = false;
    const finish = (v) => { if (done) return; done = true; resolve(v); m.close(); };
    const ok = btn(confirmLabel, { kind: danger ? 'danger' : '', onClick: () => finish(true) });
    const no = btn('Annuler', { kind: 'secondary', onClick: () => finish(false) });
    m = openModal({ title, body: h('div', { class: 'stack' }, message ? h('p', {}, message) : null, body), actions: [no, ok], onClose: () => { if (!done) { done = true; resolve(false); } } });
    ok.focus();
  });
}

export function lightbox(urls, start = 0) {
  if (!urls.length) return;
  let i = start;
  const prev = document.activeElement;
  const img = h('img', { alt: '' });
  const count = h('span', {});
  const thumbs = h('div', { class: 'lightbox-thumbs' }, urls.map((u, n) => h('button', { type: 'button', 'aria-label': `Photo ${n + 1}`, onClick: () => show(n) }, h('img', { src: u, alt: '' }))));
  const show = (n) => { i = (n + urls.length) % urls.length; img.src = urls[i]; count.textContent = `${i + 1} / ${urls.length}`; [...thumbs.children].forEach((b, k) => b.setAttribute('aria-current', String(k === i))); };
  const onKey = (e) => { if (e.key === 'Escape') close(); if (e.key === 'ArrowLeft') show(i - 1); if (e.key === 'ArrowRight') show(i + 1); };
  const close = () => { document.removeEventListener('keydown', onKey); box.remove(); document.body.style.overflow = ''; if (prev && prev.focus) prev.focus(); };
  const box = h('div', { class: 'lightbox', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Photos du véhicule' },
    h('div', { class: 'lightbox-top' }, count, h('button', { class: 'btn-icon', style: { color: '#fff' }, type: 'button', 'aria-label': 'Fermer', onClick: close }, icon('x'))),
    h('div', { class: 'lightbox-stage', onClick: (e) => { if (e.target === e.currentTarget) close(); } }, img,
      urls.length > 1 ? h('button', { class: 'nav prev', type: 'button', 'aria-label': 'Photo précédente', onClick: () => show(i - 1) }, icon('left')) : null,
      urls.length > 1 ? h('button', { class: 'nav next', type: 'button', 'aria-label': 'Photo suivante', onClick: () => show(i + 1) }, icon('right')) : null),
    urls.length > 1 ? thumbs : h('div', {}));
  document.body.append(box); document.body.style.overflow = 'hidden'; document.addEventListener('keydown', onKey); show(start);
  box.querySelector('.btn-icon').focus();
}
