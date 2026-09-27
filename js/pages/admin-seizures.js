/* Registre et statistiques des véhicules saisis par la police ou la gendarmerie. */
import { h, loading, empty, toast, busy, btn, field, confirmDialog } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { dt } from '../lib/format.js';

const REQUESTERS = { police: 'Police', gendarmerie: 'Gendarmerie' };

export default async function seizuresPage() {
  const law = api.isLawEnforcement();
  const root = h('div', { class: 'stack-lg' }, loading());
  const form = law ? seizureForm() : null;
  const el = adminLayout('seizures', pageHead('Saisies', 'Registre partagé des véhicules saisis par les forces de l’ordre.'), h('div', { class: 'stack-lg' }, form, root));

  async function load() {
    const rows = await api.seizures();
    root.replaceChildren(rows.length ? h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' },
      h('thead', {}, h('tr', {}, ['Plaque', 'Modèle', 'Couleur', 'Demandé par', 'État', 'Saisie le', 'Récupérée le', ''].map((x) => h('th', {}, x)))),
      h('tbody', {}, rows.map((r) => h('tr', {},
        h('td', { 'data-label': 'Plaque' }, h('strong', {}, r.plate)),
        h('td', { 'data-label': 'Modèle' }, r.model), h('td', { 'data-label': 'Couleur' }, r.color),
        h('td', { 'data-label': 'Demandé par' }, REQUESTERS[r.requested_by]),
        h('td', { 'data-label': 'État' }, h('span', { class: `badge ${r.status === 'active' ? 'amber' : 'green'}` }, r.status === 'active' ? 'À récupérer' : 'Récupérée')),
        h('td', { 'data-label': 'Saisie le' }, dt(r.created_at)),
        h('td', { 'data-label': 'Récupérée le' }, r.recovered_at ? `${dt(r.recovered_at)} · ${r.recovered_by_name || ''}` : '—'),
        h('td', { class: 'actions', 'data-label': '' }, law && r.status === 'active' ? btn('Récupérer', { sm: true, ic: 'check', onClick: async () => {
          if (!await confirmDialog({ title: 'Confirmer la récupération ?', message: `La saisie du véhicule ${r.plate} sera clôturée.`, confirmLabel: 'Récupérer' })) return;
          try { await api.recoverSeizure(r.id); toast('Saisie clôturée.', 'ok'); await load(); } catch (e) { toast(e.message, 'error'); }
        } }) : null)))))) : empty('Aucune saisie', 'Les véhicules saisis apparaîtront ici.'));
  }

  function seizureForm() {
    const plate = h('input', { class: 'input', maxlength: '16', required: true });
    const model = h('input', { class: 'input', maxlength: '60', required: true });
    const color = h('input', { class: 'input', maxlength: '40', required: true });
    const requester = h('select', { class: 'input' }, Object.entries(REQUESTERS).map(([value, label]) => h('option', { value }, label)));
    const save = btn('Enregistrer la saisie', { ic: 'plus', onClick: () => busy(save, async () => {
      await api.createSeizure({ plate: plate.value, model: model.value, color: color.value, requestedBy: requester.value });
      plate.value = ''; model.value = ''; color.value = ''; toast('Saisie enregistrée.', 'ok'); await load();
    }) });
    return h('section', { class: 'card card-pad stack' }, h('h2', { class: 'card-title' }, 'Nouvelle saisie'),
      h('div', { class: 'form-grid' }, field('Plaque', plate), field('Modèle', model), field('Couleur', color), field('Service demandeur', requester)), save);
  }

  await load();
  const timer = setInterval(() => load().catch(() => {}), 15000);
  return { el, destroy: () => clearInterval(timer) };
}

export async function statsPage() {
  const stats = await api.seizureStats();
  const items = [['Saisies enregistrées', stats.total, 'navy'], ['À récupérer', stats.active, 'amber'],
    ['Récupérées', stats.recovered, 'green'], ['Demandées par la Police', stats.police, 'blue'],
    ['Demandées par la Gendarmerie', stats.gendarmerie, 'teal'], ['Saisies déclarées par mon compte', stats.mine, 'navy']];
  return adminLayout('seizure-stats', pageHead('Statistiques des saisies', 'Indicateurs du registre Police et Gendarmerie.'),
    h('div', { class: 'stat-grid' }, items.map(([label, value, tone]) => h('div', { class: `stat ${tone}` }, h('div', { class: 'n num' }, value), h('div', { class: 'l' }, label))));
}