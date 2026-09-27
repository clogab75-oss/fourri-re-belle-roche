/* Codes promo (gérants) : création, suivi des utilisations, activation / désactivation. */
import { h, icon, loading, empty, toast, busy, btn, openModal, confirmDialog } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { money, dt } from '../lib/format.js';

const ALPHA = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const generate = () => 'PROMO-' + Array.from(crypto.getRandomValues(new Uint32Array(5)), (n) => ALPHA[n % ALPHA.length]).join('');
const SCOPE = { tous: 'Fourrière et voitures', fourriere: 'Fourrière uniquement', vente: 'Achat de voiture uniquement' };
const STATE = { actif: ['Actif', 'green'], desactive: ['Désactivé', 'gray'], expire: ['Expiré', 'red'], epuise: ['Épuisé', 'amber'] };
const RSTATE = { appliquee: ['En cours', 'amber'], utilisee: ['Utilisé', 'green'], annulee: ['Annulé', 'gray'] };

function usesModal(c) {
  const body = h('div', {}, loading());
  const m = openModal({ title: `Utilisations de ${c.code}`, wide: true, body, actions: [btn('Fermer', { onClick: () => m.close() })] });
  api.codeUses(c.id).then((rows) => body.replaceChildren(rows.length
    ? h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' }, h('thead', {}, h('tr', {}, ['Client', 'Saisi par', 'Pour', 'Statut', 'Montant', 'Date'].map((t) => h('th', {}, t)))),
      h('tbody', {}, rows.map((r) => h('tr', {}, h('td', { 'data-label': 'Client' }, h('strong', {}, r.client_name)), h('td', { 'data-label': 'Saisi par' }, r.applied_by_name || '—'),
        h('td', { 'data-label': 'Pour' }, `${r.kind === 'vente' ? 'Achat' : 'Récupération'}${r.vehicle_label ? ' · ' + r.vehicle_label : ''}`),
        h('td', { 'data-label': 'Statut' }, h('span', { class: `badge ${RSTATE[r.status][1]}` }, RSTATE[r.status][0])),
        h('td', { 'data-label': 'Montant', class: 'num' }, r.final_amount != null ? `${money(r.original_amount)} → ${money(r.final_amount)}` : (r.original_amount != null ? `${money(r.original_amount)} (à ce jour)` : '—')),
        h('td', { 'data-label': 'Date' }, dt(r.applied_at)))))))
    : empty('Aucune utilisation', "Ce code n'a pas encore été saisi.")))
    .catch((e) => body.replaceChildren(h('p', { class: 'muted' }, e.message)));
}

export default async function codesPage() {
  const tableBox = h('div', {}, loading());
  const code = h('input', { class: 'input code-input', id: 'c-code', maxlength: '24', autocomplete: 'off', spellcheck: 'false', placeholder: 'Ex. NOEL50', required: true });
  const pct = h('input', { class: 'input', id: 'c-pct', type: 'number', min: '1', max: '100', step: '1', value: '50', required: true });
  const scope = h('select', { class: 'input', id: 'c-scope' }, Object.entries(SCOPE).map(([k, l]) => h('option', { value: k }, l)));
  const max = h('input', { class: 'input', id: 'c-max', type: 'number', min: '1', step: '1', placeholder: 'Illimité' });
  const exp = h('input', { class: 'input', id: 'c-exp', type: 'datetime-local' });
  const once = h('input', { id: 'c-once', type: 'checkbox', checked: true });
  const note = h('input', { class: 'input', id: 'c-note', maxlength: '200', placeholder: 'Facultatif (ex. offre d\'ouverture)' });
  const submit = h('button', { class: 'btn', type: 'submit' }, icon('plus'), 'Créer le code');
  const f = (label, id, ...c) => h('div', { class: 'field' }, h('label', { for: id }, label), ...c);
  const form = h('form', { class: 'card card-pad stack', onSubmit: (e) => { e.preventDefault(); busy(submit, async () => {
    await api.createCode({ code: code.value, percent: Number(pct.value), scope: scope.value, maxUses: max.value ? Number(max.value) : null, expiresAt: exp.value ? new Date(exp.value).toISOString() : null, once: once.checked, note: note.value });
    toast(`Code ${code.value.trim().toUpperCase()} créé.`, 'ok'); code.value = ''; max.value = ''; exp.value = ''; note.value = ''; await load();
  }); } },
    h('h2', { class: 'card-title' }, 'Créer un code'),
    h('div', { class: 'form-grid' },
      f('Code', 'c-code', h('div', { class: 'row', style: { flexWrap: 'nowrap', gap: '8px' } }, code, btn('Générer', { kind: 'secondary', ic: 'refresh', onClick: () => { code.value = generate(); } })), h('span', { class: 'hint' }, 'Lettres, chiffres et tirets (3 à 24 caractères). Les clients peuvent l\'écrire en minuscules.')),
      f('Réduction (%)', 'c-pct', pct, h('div', { class: 'pct-chips' }, [10, 25, 50, 75, 100].map((n) => h('button', { class: 'chip', type: 'button', onClick: () => { pct.value = String(n); } }, `−${n} %`)))),
      f('Valable sur', 'c-scope', scope), f('Nombre d\'utilisations maximum', 'c-max', max, h('span', { class: 'hint' }, 'Vide = illimité. Une utilisation abandonnée est rendue.')),
      f('Fin de validité', 'c-exp', exp, h('span', { class: 'hint' }, 'Vide = sans limite de date.')), f('Note interne', 'c-note', note)),
    h('label', { class: 'check' }, once, h('span', {}, h('strong', {}, 'Une seule fois par personne'), h('div', { class: 'hint' }, 'Décochez pour qu\'un même client puisse réutiliser le code sur plusieurs véhicules.'))),
    h('div', {}, submit));
  const help = h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Comment ça marche ?'),
    h('ol', { style: { margin: 0, paddingLeft: '20px', display: 'grid', gap: '6px' } }, [
      'Créez un code et donnez-le à un client (ou à un employé).',
      'Dans la conversation, la personne clique sur « Code promo » ou tape /code SONCODE.',
      'La réduction s\'affiche dans le chat. Elle s\'applique au montant de fourrière ou au prix de la voiture quand le gérant confirme l\'achat.',
      'Un gérant peut retirer un code non utilisé depuis la conversation.'].map((t) => h('li', {}, t))));
  const el = adminLayout('codes', pageHead('Codes promo', 'Des réductions en pourcentage, applicables à la fourrière et à la vente de véhicules.'), h('div', { class: 'stack-lg' }, form, tableBox, help));

  async function load() {
    const list = await api.codes();
    tableBox.replaceChildren(list.length ? h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' },
      h('thead', {}, h('tr', {}, ['Code', 'Réduction', 'Portée', 'Utilisations', 'Fin', 'État', ''].map((t) => h('th', {}, t)))),
      h('tbody', {}, list.map((c) => h('tr', { dataset: { code: c.code } },
        h('td', { 'data-label': 'Code' }, h('span', { class: 'code-chip' }, c.code, h('button', { class: 'btn-icon', type: 'button', 'aria-label': `Copier ${c.code}`, onClick: async () => { try { await navigator.clipboard.writeText(c.code); toast('Code copié.', 'ok'); } catch { toast('Sélectionnez le code pour le copier.', 'warn'); } } }, icon('copy'))), c.note ? h('div', { class: 'small muted', style: { marginTop: '4px', maxWidth: '260px', overflowWrap: 'anywhere' } }, c.note) : null),
        h('td', { 'data-label': 'Réduction', class: 'nowrap' }, h('strong', {}, `−${c.percent} %`)), h('td', { 'data-label': 'Portée' }, SCOPE[c.scope]),
        h('td', { 'data-label': 'Utilisations', class: 'num' }, `${c.uses} / ${c.max_uses ?? '∞'}`, c.once_per_client ? h('div', { class: 'small muted' }, '1 par personne') : null),
        h('td', { 'data-label': 'Fin' }, c.expires_at ? dt(c.expires_at) : '—'), h('td', { 'data-label': 'État' }, h('span', { class: `badge ${STATE[c.state][1]}` }, STATE[c.state][0])),
        h('td', { class: 'actions', 'data-label': '' }, h('div', { class: 'row', style: { justifyContent: 'flex-end', gap: '6px' } },
          btn('Utilisations', { sm: true, kind: 'secondary', onClick: () => usesModal(c) }),
          btn(c.active ? 'Désactiver' : 'Activer', { sm: true, kind: 'secondary', onClick: async () => { try { await api.toggleCode(c.id, !c.active); toast(c.active ? 'Code désactivé.' : 'Code activé.', 'ok'); await load(); } catch (e) { toast(e.message, 'error'); } } }),
          btn('', { sm: true, kind: 'ghost', ic: 'trash', title: c.uses ? 'Déjà utilisé : désactivez-le' : 'Supprimer', disabled: c.uses > 0, onClick: async () => {
            if (await confirmDialog({ title: `Supprimer ${c.code} ?`, message: 'Le code sera supprimé définitivement.', confirmLabel: 'Supprimer', danger: true })) { try { await api.deleteCode(c.id); toast('Code supprimé.', 'ok'); await load(); } catch (e) { toast(e.message, 'error'); } } } })))))))))
      : h('section', { class: 'card' }, empty('Aucun code pour le moment', 'Créez votre premier code avec le formulaire ci-dessus.')));
  }
  await load();
  const timer = setInterval(() => load().catch(() => {}), 20000);
  return { el, destroy: () => clearInterval(timer) };
}
