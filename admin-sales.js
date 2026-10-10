/* Ventes (gérants) : tarification anticipée, véhicules en attente de mise en vente, annonces en cours, ventes réalisées. */
import { h, icon, badge, loading, empty, toast, busy, btn, field, confirmDialog, openModal } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { plateEl, colorTag, photoBlock, meta, meter } from '../lib/cards.js';
import { money, dt } from '../lib/format.js';
import { saleModal, soldModal, relistModal } from '../lib/actions.js';

/* Prépare (ou modifie) le prix de vente d'un véhicule encore en fourrière : rien n'est publié
   tant que le délai de 7 jours n'est pas atteint sans réclamation. */
export function plannedModal(v, onDone) {
  const price = h('input', { class: 'input', id: 'pp-price', type: 'number', min: '1', step: '1', required: true, value: v.planned_price ? String(Math.round(v.planned_price)) : '' });
  const desc = h('textarea', { class: 'input', id: 'pp-desc', maxlength: '2000', rows: '4', placeholder: 'État, options, particularités…' }, v.planned_description || '');
  const go = btn('Enregistrer le tarif', { onClick: () => busy(go, async () => {
    const p = Number(price.value); const d = desc.value.trim();
    if (!(p > 0)) throw new Error('Indiquez un prix de vente valide.');
    if (d.length < 3) throw new Error('Ajoutez une description.');
    await api.setPlannedSale(v.id, p, d); toast('Tarif préparé.', 'ok'); m.close(); onDone();
  }) });
  const actions = [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go];
  if (v.planned_price) actions.splice(1, 0, btn('Retirer le tarif', { kind: 'ghost', onClick: () => busy(go, async () => { await api.setPlannedSale(v.id, null, null); toast('Tarif préparé retiré.', 'ok'); m.close(); onDone(); }) }));
  const m = openModal({ title: `Préparer le prix de vente · ${v.plate}`, wide: true,
    body: h('div', { class: 'stack' },
      h('p', { class: 'muted' }, 'Ce véhicule est encore en fourrière. En préparant son prix maintenant, il passera directement en vente dès que le délai sera atteint sans réclamation — sans étape manuelle.'),
      field('Prix de vente (€)', price), field('Description', desc)),
    actions });
}

export default async function sales() {
  const root = h('div', { class: 'stack-lg' }, loading());
  const el = adminLayout('sales', pageHead('Ventes', 'Préparez des tarifs à l\'avance, mettez en vente les véhicules restés sans réclamation, suivez les annonces et les ventes.'), root);
  const done = () => load().catch((e) => toast(e.message, 'error'));
  async function load() {
    const [vs, cs] = await Promise.all([api.vehicles(), api.conversations()]);
    const upcoming = vs.filter((v) => ['en_fourriere', 'reclamee'].includes(v.status));
    const waiting = vs.filter((v) => v.status === 'attente_vente'); const onSale = vs.filter((v) => v.status === 'a_vendre');
    const sold = vs.filter((v) => v.sale_status === 'vendue' && ['vendue', 'archivee'].includes(v.status));
    const open = (id) => cs.filter((c) => c.vehicle_id === id && c.type === 'vente' && c.status === 'ouverte');
    const planned = h('section', { class: 'stack' }, h('h2', {}, `Tarification anticipée (${upcoming.length})`),
      h('p', { class: 'muted' }, 'Préparez le prix d\'un véhicule dès son arrivée : dès que le délai de réclamation sera dépassé, il passera automatiquement en vente avec ce prix, sans rien faire de plus.'),
      upcoming.length ? h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' },
        h('thead', {}, h('tr', {}, ['Plaque', 'Modèle', 'Couleur', 'Jour', 'Tarif préparé', ''].map((t) => h('th', {}, t)))),
        h('tbody', {}, upcoming.map((v) => h('tr', {}, h('td', { 'data-label': 'Plaque' }, plateEl(v.plate, 'sm')), h('td', { 'data-label': 'Modèle' }, v.model), h('td', { 'data-label': 'Couleur' }, colorTag(v.color)),
          h('td', { 'data-label': 'Jour', class: 'num' }, String(v.days_in_impound)), h('td', { 'data-label': 'Tarif préparé' }, v.planned_price ? h('strong', {}, money(v.planned_price)) : h('span', { class: 'muted' }, 'Non préparé')),
          h('td', { class: 'actions', 'data-label': '' }, btn(v.planned_price ? 'Modifier' : 'Préparer un prix', { sm: true, kind: v.planned_price ? 'secondary' : '', onClick: () => plannedModal(v, done) }))))))))
        : h('div', { class: 'card' }, empty('Aucun véhicule en fourrière', 'Les véhicules fraîchement ajoutés apparaîtront ici.')));
    const wait = h('section', { class: 'stack' }, h('h2', {}, `Véhicules en attente de mise en vente (${waiting.length})`),
      h('p', { class: 'muted' }, 'Ces véhicules ont dépassé le délai sans réclamation. Ils ne sont visibles que des gérants.'),
      waiting.length ? h('div', { class: 'vgrid' }, waiting.map((v) => h('article', { class: 'card vcard' }, photoBlock(v.photos, badge(v.status)),
        h('div', { class: 'vbody' }, h('div', { class: 'vtitle' }, plateEl(v.plate)), h('h3', {}, v.model),
          meta([['Couleur', colorTag(v.color)], ['Arrivée', dt(v.created_at)], ['Jours en fourrière', String(v.days_in_impound)]]),
          meter('Ancien montant de garde', v.final_amount ?? v.current_amount),
          h('div', { class: 'row' }, btn('Mettre en vente', { kind: 'amber', ic: 'tag', onClick: () => saleModal(v, done) }), h('a', { class: 'btn secondary', href: '#/admin/vehicules/' + v.id }, 'Fiche'))))))
        : h('div', { class: 'card' }, empty('Aucun véhicule en attente', 'Les véhicules atteignant le délai sans réclamation apparaîtront ici automatiquement.')));
    const live = h('section', { class: 'stack' }, h('h2', {}, `Annonces en cours (${onSale.length})`),
      onSale.length ? h('div', { class: 'vgrid' }, onSale.map((v) => { const ic = open(v.id); return h('article', { class: 'card vcard' }, photoBlock(v.photos, badge(v.status)),
        h('div', { class: 'vbody' }, h('h3', {}, v.model), meta([['Couleur', colorTag(v.color)], ['Plaque', v.plate], ['En vente depuis', dt(v.sale_listed_at)], ['Intéressés', String(ic.length)]]),
          h('p', { class: 'vdesc' }, v.sale_description), meter('Prix de vente', v.sale_price),
          h('div', { class: 'row' }, btn('Vendu', { ic: 'check', sm: true, onClick: () => soldModal(v, ic, done) }), btn('Modifier', { sm: true, kind: 'secondary', ic: 'edit', onClick: () => saleModal(v, done, true) }),
            btn('Retirer', { sm: true, kind: 'secondary', onClick: async () => { if (await confirmDialog({ title: 'Retirer de la vente ?', message: "Le véhicule repasse en attente de mise en vente. Les conversations d'achat sont fermées.", confirmLabel: 'Retirer' })) { try { await api.withdrawSale(v.id); toast('Annonce retirée.', 'ok'); done(); } catch (e) { toast(e.message, 'error'); } } } }),
            h('a', { class: 'btn ghost sm', href: '#/admin/vehicules/' + v.id }, 'Fiche')))); }))
        : h('div', { class: 'card' }, empty('Aucune annonce', 'Mettez un véhicule en vente depuis la section ci-dessus.')));
    const hist = h('section', { class: 'stack' }, h('h2', {}, `Ventes réalisées (${sold.length})`),
      sold.length ? h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' }, h('thead', {}, h('tr', {}, ['Véhicule', 'Acheteur', 'Prix', 'Date', ''].map((t) => h('th', {}, t)))),
        h('tbody', {}, sold.map((v) => h('tr', {}, h('td', { 'data-label': 'Véhicule' }, h('strong', {}, `${v.model} · ${v.plate}`)), h('td', { 'data-label': 'Acheteur' }, v.buyer_name || '—'), h('td', { 'data-label': 'Prix', class: 'num' }, money(v.sold_price)),
          h('td', { 'data-label': 'Date' }, dt(v.sold_at)), h('td', { class: 'actions', 'data-label': '' }, h('div', { class: 'row', style: { justifyContent: 'flex-end', gap: '6px' } },
            btn('Remettre en vente', { sm: true, kind: 'secondary', onClick: () => relistModal(v, done) }), h('a', { class: 'btn secondary sm', href: '#/admin/vehicules/' + v.id }, 'Fiche')))))))))
        : h('div', { class: 'card' }, empty('Aucune vente', 'Les ventes clôturées apparaîtront ici.')));
    root.replaceChildren(planned, wait, live, hist);
  }
  await load();
  const timer = setInterval(() => load().catch(() => {}), 25000);
  return { el, destroy: () => clearInterval(timer) };
}
