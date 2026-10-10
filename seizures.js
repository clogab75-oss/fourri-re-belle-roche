/* Saisies : registre partagé entre le personnel de la fourrière et les comptes forces de l'ordre.
   Le personnel peut créer une saisie ; les deux peuvent la clôturer (« Récupérée »). Statistiques
   volontairement séparées des statistiques normales de la fourrière. */
import { h, icon, badge, loading, empty, toast, busy, btn, field, confirmDialog, openModal } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { dt, rel } from '../lib/format.js';

const AGENCY = { police: 'Police', gendarmerie: 'Gendarmerie' };

function createModal(onDone) {
  const plate = h('input', { class: 'input', id: 'sz-plate', maxlength: '16', autocomplete: 'off', placeholder: 'AB-123-CD', required: true });
  const model = h('input', { class: 'input', id: 'sz-model', maxlength: '60', autocomplete: 'off', required: true });
  const color = h('input', { class: 'input', id: 'sz-color', maxlength: '40', autocomplete: 'off', required: true });
  const agency = h('select', { class: 'input', id: 'sz-agency' }, h('option', { value: 'police' }, 'Police'), h('option', { value: 'gendarmerie' }, 'Gendarmerie'));
  const go = btn('Enregistrer la saisie', { onClick: () => busy(go, async () => {
    if (plate.value.trim().length < 2) throw new Error('Le numéro de plaque est obligatoire.');
    if (!model.value.trim()) throw new Error('Le modèle est obligatoire.');
    if (!color.value.trim()) throw new Error('La couleur est obligatoire.');
    await api.createSeizure(plate.value, model.value, color.value, agency.value);
    toast('Saisie enregistrée.', 'ok'); m.close(); onDone();
  }) });
  const m = openModal({ title: 'Enregistrer une saisie', body: h('div', { class: 'stack' },
    h('div', { class: 'form-grid' }, field('Plaque', plate), field('Modèle', model), field('Couleur', color), field('Demandée par', agency))),
    actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
}

export default async function seizuresPage() {
  const staff = api.isStaff(); const police = api.isPolice();
  const statBox = h('div', { class: 'stat-grid' }, loading());
  const tableBox = h('div', {}, loading());
  const addBtn = staff ? h('button', { class: 'btn', type: 'button', onClick: () => createModal(reload) }, icon('plus'), 'Enregistrer une saisie') : null;
  const head = pageHead('Saisies', staff
    ? 'Registre des véhicules saisis par la police ou la gendarmerie.'
    : 'Consultez les véhicules saisis et marquez-les comme récupérés une fois repris.', addBtn);
  const content = h('div', { class: 'stack-lg' }, head, statBox, tableBox);
  const el = staff ? adminLayout('saisies', content) : h('div', { class: 'container page' }, content);

  async function reload() {
    const [rows, stats] = await Promise.all([api.seizures(), api.seizureStats()]);
    statBox.replaceChildren(...[
      ['En cours', stats.en_cours, 'amber'], ['Récupérées', stats.recuperees, 'green'],
      ['Demandées par la police', stats.police, 'navy'], ['Demandées par la gendarmerie', stats.gendarmerie, 'violet'],
      ["Aujourd'hui", stats.today, 'blue'], ['Total', stats.total, 'navy'],
    ].map(([l, n, tone]) => h('div', { class: `stat ${tone}` }, h('div', { class: 'n num' }, n), h('div', { class: 'l' }, l))));

    tableBox.replaceChildren(rows.length ? h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' },
      h('thead', {}, h('tr', {}, ['Plaque', 'Modèle', 'Couleur', 'Demandée par', 'Enregistrée', 'Statut', ''].map((t) => h('th', {}, t)))),
      h('tbody', {}, rows.map((s) => h('tr', {},
        h('td', { 'data-label': 'Plaque' }, h('strong', {}, s.plate)), h('td', { 'data-label': 'Modèle' }, s.model), h('td', { 'data-label': 'Couleur' }, s.color),
        h('td', { 'data-label': 'Demandée par' }, h('span', { class: `badge ${s.agency === 'police' ? 'navy' : 'violet'}` }, AGENCY[s.agency])),
        h('td', { 'data-label': 'Enregistrée' }, `${dt(s.created_at)} · ${s.created_by_name || '—'}`),
        h('td', { 'data-label': 'Statut' }, s.status === 'en_cours' ? h('span', { class: 'badge amber' }, 'En cours')
          : h('span', { class: 'badge green' }, `Récupérée${s.recovered_by_name ? ' · ' + s.recovered_by_name : ''}`)),
        h('td', { class: 'actions', 'data-label': '' }, h('div', { class: 'row', style: { justifyContent: 'flex-end', gap: '6px' } },
          s.status === 'en_cours' ? btn('Récupérée', { sm: true, ic: 'check', onClick: async () => { try { await api.recoverSeizure(s.id); toast('Saisie marquée comme récupérée.', 'ok'); await reload(); } catch (e) { toast(e.message, 'error'); } } }) : null,
          staff ? btn('', { sm: true, kind: 'ghost', ic: 'trash', title: 'Supprimer (erreur de saisie)', onClick: async () => {
            if (await confirmDialog({ title: 'Supprimer cette saisie ?', message: `${s.plate} — cette action est réservée à la correction d'une erreur.`, confirmLabel: 'Supprimer', danger: true })) {
              try { await api.deleteSeizure(s.id); toast('Saisie supprimée.', 'ok'); await reload(); } catch (e) { toast(e.message, 'error'); }
            } } }) : null)))))))) : empty('Aucune saisie enregistrée', staff ? 'Enregistrez-en une avec le bouton ci-dessus.' : 'Revenez plus tard : cette page se met à jour automatiquement.'));
  }
  await reload().catch((e) => tableBox.replaceChildren(empty('Impossible de charger les saisies', e.message)));
  const timer = setInterval(() => reload().catch(() => {}), 20000);
  const un = api.watch([{ table: 'seizures' }], () => reload().catch(() => {}), 500);
  return { el, destroy: () => { clearInterval(timer); un(); } };
}
