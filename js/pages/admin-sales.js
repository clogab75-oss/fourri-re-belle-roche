/* Ventes (gérants) : véhicules en attente de mise en vente, annonces en cours, ventes réalisées. */
import { h, icon, badge, loading, empty, toast, btn, field, confirmDialog } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { plateEl, colorTag, photoBlock, meta, meter } from '../lib/cards.js';
import { money, dt } from '../lib/format.js';
import { saleModal, soldModal } from '../lib/actions.js';

export default async function sales() {
  const root = h('div', { class: 'stack-lg' }, loading());
  const el = adminLayout('sales', pageHead('Ventes', 'Préparez les prix à l’avance, suivez les annonces et les ventes.'), root);
  const done = () => load().catch((e) => toast(e.message, 'error'));
  async function load() {
    const [vs, cs, queue] = await Promise.all([api.vehicles(), api.conversations(), api.saleQueue()]);
    const waiting = vs.filter((v) => v.status === 'attente_vente'); const onSale = vs.filter((v) => v.status === 'a_vendre');
    const sold = vs.filter((v) => v.sale_status === 'vendue' && ['vendue', 'archivee'].includes(v.status));
    const open = (id) => cs.filter((c) => c.vehicle_id === id && c.type === 'vente' && c.status === 'ouverte');
    const prep = h('section', { class: 'stack' }, h('h2', {}, `Préparer les prix (${queue.length})`),
      h('p', { class: 'muted' }, 'Les véhicules ajoutés apparaissent ici immédiatement. Un prix préparé est publié automatiquement au délai défini dans les tarifs.'),
      queue.length ? h('div', { class: 'vgrid' }, queue.map((v) => {
        const price = h('input', { class: 'input', type: 'number', min: '1', step: '1', value: v.prepared_price == null ? '' : String(v.prepared_price), placeholder: 'Prix de vente (€)' });
        const desc = h('textarea', { class: 'input', rows: '2', maxlength: '2000', placeholder: 'Description de l’annonce' }, v.prepared_description || '');
        return h('article', { class: 'card vcard' }, photoBlock(v.photos, badge(v.status)), h('div', { class: 'vbody' },
          h('div', { class: 'vtitle' }, plateEl(v.plate)), h('h3', {}, v.model), meta([['Couleur', colorTag(v.color)], ['Arrivée', dt(v.created_at)], ['Jours', String(v.days_in_impound)]]),
          field('Prix préparé (€)', price), field('Description', desc),
          h('div', { class: 'row' }, btn('Enregistrer le prix', { sm: true, ic: 'check', onClick: async () => {
            try { await api.saveSaleDraft(v.id, price.value ? Number(price.value) : null, desc.value); toast(price.value ? 'Annonce préparée.' : 'Prix effacé.', 'ok'); done(); } catch (e) { toast(e.message, 'error'); }
          } }),
          v.status === 'en_fourriere' ? btn('Mettre en vente maintenant', { sm: true, kind: 'amber', ic: 'tag', onClick: async () => {
            if (!await confirmDialog({ title: 'Accélérer la mise en vente ?', message: `La date d’entrée de ${v.plate} sera recalée au délai automatique configuré. Une réclamation ouverte empêche cette action.`, confirmLabel: 'Mettre en vente' })) return;
            try { await api.forceSaleReady(v.id); toast('Délai atteint. Le véhicule est en vente ou en attente de son prix.', 'ok'); done(); } catch (e) { toast(e.message, 'error'); }
          } }) : null)));
      })) : h('div', { class: 'card' }, empty('Aucun véhicule à préparer', 'Les véhicules en vente ou déjà traités ne sont plus dans cette file.')));
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
      sold.length ? h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table stackable' }, h('thead', {}, h('tr', {}, ['Véhicule', 'Acheteur', 'Prix', 'Options', 'Date', ''].map((t) => h('th', {}, t)))),
        h('tbody', {}, sold.map((v) => h('tr', {}, h('td', { 'data-label': 'Véhicule' }, h('strong', {}, `${v.model} · ${v.plate}`)), h('td', { 'data-label': 'Acheteur' }, v.buyer_name || '—'), h('td', { 'data-label': 'Prix', class: 'num' }, money(v.sold_price)),
          h('td', { 'data-label': 'Options' }, (v.selected_options || []).map((o) => `${o.label} · ${money(o.price)}`).join(', ') || '—'),
          h('td', { 'data-label': 'Date' }, dt(v.sold_at)), h('td', { class: 'actions', 'data-label': '' }, h('a', { class: 'btn secondary sm', href: '#/admin/vehicules/' + v.id }, 'Fiche'))))))))
        : h('div', { class: 'card' }, empty('Aucune vente', 'Les ventes clôturées apparaîtront ici.')));
    root.replaceChildren(prep, wait, live, hist);
  }
  await load();
  const timer = setInterval(() => load().catch(() => {}), 25000);
  return { el, destroy: () => clearInterval(timer) };
}
