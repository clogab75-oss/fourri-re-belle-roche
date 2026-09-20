/* Pages publiques : véhicules en fourrière et véhicules à vendre (recherche en direct). */
import { h, icon, badge, empty, loading, toast, busy, debounce } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { plateEl, colorTag, photoBlock, meta, meter } from '../lib/cards.js';
import { dt, norm, plateKey, money } from '../lib/format.js';

export const impoundPage = (ctx) => listPage(ctx, false);
export const salePage = (ctx) => listPage(ctx, true);

async function listPage(ctx, sale) {
  let items = []; let mine = new Map(); let q = ctx.query.q || ''; let sort = 'recent'; let ready = false;
  const grid = h('div', { class: 'vgrid' }, [1, 2, 3].map(() => h('div', { class: 'skeleton', style: { height: '420px' } })));
  const count = h('span', { class: 'result-count', 'aria-live': 'polite' });
  const search = h('input', { class: 'input', type: 'search', value: q, placeholder: sale ? 'Rechercher un modèle ou une couleur' : 'Rechercher par plaque, modèle ou couleur', 'aria-label': 'Rechercher', autocomplete: 'off' });
  const sorter = h('select', { class: 'input', 'aria-label': 'Trier', style: { width: 'auto' }, onChange: () => { sort = sorter.value; render(); } },
    h('option', { value: 'recent' }, 'Plus récents'), h('option', { value: 'old' }, 'Plus anciens'), h('option', { value: 'amount' }, 'Montant décroissant'));
  search.addEventListener('input', debounce(() => { q = search.value; render(); }, 120));

  const match = (v) => {
    const nq = norm(q).trim(); if (!nq) return true;
    const pk = plateKey(q);
    return (!sale && pk.length > 0 && plateKey(v.plate).includes(pk)) || norm(v.model).includes(nq) || norm(v.color).includes(nq) || (sale && norm(v.description).includes(nq));
  };
  const amount = (v) => Number(sale ? v.price : v.total_amount);

  function card(v, i) {
    const existing = mine.get(v.id);
    const button = existing
      ? h('a', { class: 'btn secondary block', href: `#/messages/${existing}` }, icon('message'), 'Voir ma demande')
      : h('button', { class: 'btn block', type: 'button', onClick: () => act(v, button) }, sale ? 'Je suis intéressé' : "C'est ma voiture");
    return h('article', { class: 'card vcard', style: { '--i': Math.min(i, 12) } },
      photoBlock(v.photos, badge(sale ? 'a_vendre' : 'en_fourriere')),
      h('div', { class: 'vbody' },
        h('div', { class: 'vtitle' }, sale ? h('h3', {}, v.model) : plateEl(v.plate)),
        sale ? null : h('h3', {}, v.model),
        meta(sale
          ? [['Couleur', colorTag(v.color)], ['En vente depuis', dt(v.listed_at)]]
          : [['Couleur', colorTag(v.color)], ['Arrivée', dt(v.created_at)], ['Jours en fourrière', String(v.days_in_impound)]]),
        sale ? h('p', { class: 'vdesc' }, v.description) : null,
        meter(sale ? 'Prix de vente' : `Montant à régler · jour ${v.days_in_impound}`, sale ? v.price : v.total_amount),
        button));
  }
  function render() {
    if (!ready) return;
    let list = items.filter(match);
    list.sort((a, b) => (sort === 'amount' ? amount(b) - amount(a) : (new Date(a.created_at || a.listed_at) - new Date(b.created_at || b.listed_at)) * (sort === 'old' ? 1 : -1)));
    count.textContent = `${list.length} résultat${list.length > 1 ? 's' : ''}`;
    grid.replaceChildren(...(list.length ? list.map(card) : [h('div', { style: { gridColumn: '1 / -1' } },
      empty(items.length ? 'Aucun résultat' : (sale ? 'Aucun véhicule à vendre pour le moment' : 'Aucun véhicule en fourrière'),
        items.length ? 'Essayez une autre plaque, un autre modèle ou une autre couleur.' : 'Revenez plus tard : la liste se met à jour toute seule.'))]));
  }
  async function act(v, button) {
    if (!api.isLogged()) return ctx.navigate('/connexion?next=' + encodeURIComponent(location.hash.slice(1)));
    await busy(button, async () => {
      const id = await (sale ? api.interest(v.id) : api.claim(v.id));
      toast("Demande envoyée : une conversation est ouverte avec l'équipe.", 'ok');
      ctx.navigate('/messages/' + id);
    });
  }
  async function load() {
    const [list, convs] = await Promise.all([sale ? api.forSale() : api.impound(), api.isLogged() ? api.conversations().catch(() => []) : []]);
    items = list; ready = true;
    mine = new Map(convs.filter((c) => c.status === 'ouverte' && c.type === (sale ? 'vente' : 'claim')).map((c) => [c.vehicle_id, c.id]));
    render();
  }
  const el = h('div', { class: 'container page' },
    h('div', { class: 'page-head' }, h('div', {}, h('h1', {}, sale ? 'Véhicules à vendre' : 'Véhicules en fourrière'),
      h('p', {}, sale ? 'Découvrez les véhicules proposés à la vente et contactez directement l\'équipe.' : 'Retrouvez votre véhicule et cliquez sur « C\'est ma voiture » : une conversation s\'ouvre avec un employé.'))),
    h('div', { class: 'toolbar' }, h('div', { class: 'searchbox' }, icon('search'), search), sorter, count),
    grid);
  await load().catch((e) => { grid.replaceChildren(h('div', { style: { gridColumn: '1 / -1' } }, empty('Chargement impossible', e.message))); });
  const timer = setInterval(() => load().catch(() => {}), 30000);
  return { el, destroy: () => clearInterval(timer) };
}
