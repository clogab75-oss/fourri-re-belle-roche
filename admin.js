/* Tableau de bord et statistiques (données réelles, calculées par la base). */
import { h, icon, badge, loading, empty } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { adminLayout, pageHead } from '../lib/layout.js';
import { money, rel, dt, STATUS } from '../lib/format.js';
import { plateEl } from '../lib/cards.js';

let chartP;
export function loadChart() {
  if (window.Chart) return Promise.resolve(window.Chart);
  if (!chartP) chartP = new Promise((ok, ko) => { const s = document.createElement('script'); s.src = 'assets/vendor/chart.umd.js'; s.onload = () => ok(window.Chart); s.onerror = () => { chartP = null; ko(new Error('Graphiques indisponibles.')); }; document.head.append(s); });
  return chartP;
}
const C = { blue: '#0f5aa6', green: '#1a7f4f', amber: '#f5b400', violet: '#6247c2', navy: '#173a55', gray: '#8a949e', red: '#c2342a', teal: '#1a9c8e' };
const STATUS_COLOR = { en_fourriere: C.blue, reclamee: C.amber, recuperee: C.green, attente_vente: C.violet, a_vendre: C.teal, vendue: C.gray, archivee: '#c9d2da' };
const day = (s) => { const [, m, d] = s.split('-'); return `${d}/${m}`; };

async function charts(box, s) {
  const Chart = await loadChart();
  Chart.defaults.font.family = "'Barlow', system-ui, sans-serif"; Chart.defaults.color = '#55687a';
  const mk = (cfg) => { const c = h('canvas', {}); box.append(c); return new Chart(c, cfg); };
  return [mk({ type: 'line', data: { labels: s.daily.map((d) => day(d.day)), datasets: [
    { label: 'Entrés', data: s.daily.map((d) => d.entered), borderColor: C.blue, backgroundColor: C.blue + '22', fill: true, tension: .3, pointRadius: 2 },
    { label: 'Récupérés', data: s.daily.map((d) => d.recovered), borderColor: C.green, tension: .3, pointRadius: 2 },
    { label: 'Vendus', data: s.daily.map((d) => d.sold), borderColor: C.amber, tension: .3, pointRadius: 2 }] },
  options: { responsive: true, maintainAspectRatio: false, interaction: { mode: 'index', intersect: false }, scales: { y: { beginAtZero: true, ticks: { precision: 0 } }, x: { ticks: { maxTicksLimit: 8 } } }, plugins: { legend: { position: 'bottom' } } } })];
}

function cards(s, manager, withMoney = true) {
  const t = s.totals; const m = withMoney ? s.money : null;
  const items = [
    ['En fourrière', t.in_impound, 'blue', '#/admin/vehicules?status=en_fourriere'], ['Réclamées', t.claimed_now, 'amber', '#/admin/vehicules?status=reclamee'],
    ['Conversations ouvertes', t.open_conversations, 'blue', '#/messages'],
    manager && ['En attente de vente', t.awaiting_sale, 'violet', '#/admin/ventes'], ['À vendre', t.for_sale, 'green', manager ? '#/admin/ventes' : '#/admin/vehicules?status=a_vendre'],
    ['Récupérés', t.recovered, 'green', '#/admin/vehicules?status=recuperee'], ['Vendus', t.sold, 'navy', '#/admin/vehicules?status=vendue'], ['Total entrés', t.entered, 'navy', '#/admin/vehicules'],
    m && ['Frais encaissés', money(m.fees_collected), 'amber'], m && ['Ventes totales', money(m.sales_total), 'green'],
  ].filter(Boolean);
  return h('div', { class: 'stat-grid' }, items.map(([l, n, tone, href]) => h(href ? 'a' : 'div', { class: `stat ${tone}`, href }, h('div', { class: 'n num' }, n), h('div', { class: 'l' }, l))));
}

export async function dashboard() {
  const manager = api.isManager(); const me = api.state.profile;
  const body = h('div', { class: 'stack-lg' }, loading());
  const el = adminLayout('dash', pageHead(`Bonjour ${me.prenom}`, 'Voici l\'activité de la fourrière.', h('a', { class: 'btn', href: '#/admin/vehicules?add=1' }, icon('plus'), 'Ajouter un véhicule')), body);
  let inst = [];
  async function load() {
    const [s, vs, cs] = await Promise.all([api.stats(), api.vehicles(), api.conversations()]);
    const unread = api.state.unread.conversations || {}; const vmap = Object.fromEntries(vs.map((v) => [v.id, v]));
    const open = cs.filter((c) => c.status === 'ouverte').sort((a, b) => (unread[b.id] || 0) - (unread[a.id] || 0) || new Date(b.last_message_at) - new Date(a.last_message_at)).slice(0, 6);
    const waiting = vs.filter((v) => v.status === 'attente_vente').slice(0, 5);
    const chartBox = h('div', { class: 'chart-box' });
    inst.forEach((c) => c.destroy()); inst = [];
    body.replaceChildren(cards(s, manager),
      manager && waiting.length ? h('div', { class: 'banner' }, icon('alert'), h('div', {}, h('strong', {}, `${s.totals.awaiting_sale} véhicule(s) en attente de mise en vente. `), h('a', { href: '#/admin/ventes' }, 'Les mettre en vente'))) : null,
      h('div', { class: 'two-col' },
        h('section', { class: 'card card-pad' }, h('h2', { class: 'card-title', style: { marginBottom: '8px' } }, 'À traiter'),
          open.length ? h('ul', { class: 'list-plain' }, open.map((c) => { const v = vmap[c.vehicle_id]; const n = unread[c.id] || 0;
            return h('li', {}, h('a', { class: 'row-link', href: '#/messages/' + c.id }, h('div', { class: 'grow' }, h('strong', {}, c.client_name), h('div', { class: 'small muted' }, `${v ? v.plate + ' · ' + v.model : 'Véhicule'} — ${c.last_message_preview || ''}`)), n ? h('span', { class: 'count-pill' }, n) : null, h('span', { class: 'small muted nowrap' }, rel(c.last_message_at)))); }))
            : empty('Rien à traiter', 'Aucune conversation ouverte.')),
        h('section', { class: 'card card-pad' }, h('h2', { class: 'card-title', style: { marginBottom: '8px' } }, 'Derniers véhicules'),
          vs.length ? h('ul', { class: 'list-plain' }, vs.slice(0, 6).map((v) => h('li', {}, h('a', { class: 'row-link', href: '#/admin/vehicules/' + v.id }, plateEl(v.plate, 'sm'), h('div', { class: 'grow' }, h('strong', {}, v.model), h('div', { class: 'small muted' }, dt(v.created_at))), badge(v.status)))))
            : empty('Aucun véhicule', 'Ajoutez le premier véhicule.'))),
      h('section', { class: 'card card-pad' }, h('h2', { class: 'card-title', style: { marginBottom: '10px' } }, '30 derniers jours'), chartBox));
    charts(chartBox, s).then((c) => { inst = c; }).catch((e) => chartBox.replaceChildren(h('p', { class: 'muted' }, e.message)));
  }
  await load();
  const timer = setInterval(() => load().catch(() => {}), 30000);
  const un = api.watch([{ table: 'vehicles' }, { table: 'conversations' }, { table: 'claims' }], () => load().catch(() => {}), 800);
  return { el, destroy: () => { clearInterval(timer); un(); inst.forEach((c) => c.destroy()); } };
}

export async function statsPage() {
  const manager = api.isManager(); const s = await api.stats(); const t = s.totals;
  const dayBox = h('div', { class: 'chart-box' }); const stBox = h('div', { class: 'chart-box' }); const staffBox = h('div', { class: 'chart-box' });
  const rows = [['Véhicules entrés (archivés inclus)', t.entered], ['Actuellement en fourrière', t.in_impound], ['Actuellement réclamés', t.claimed_now], ['Véhicules ayant reçu une demande', t.claimed_vehicles],
    ['Demandes de récupération (total)', t.claims], ['Véhicules récupérés', t.recovered], ['Passés automatiquement en attente de vente', t.auto_flagged], ['En attente de mise en vente', t.awaiting_sale],
    ['À vendre', t.for_sale], ['Vendus', t.sold], ['Archivés', t.archived], ['Conversations (total)', t.conversations], ['Conversations ouvertes', t.open_conversations], ['Marques d\'intérêt pour un achat', t.interests], ['Codes promo utilisés', t.discounts_used]];
  const m = s.money;
  const el = adminLayout('stats', pageHead('Statistiques', manager ? 'Chiffres réels de la fourrière, y compris les données financières.' : 'Chiffres réels de la fourrière. Les données financières sont réservées aux gérants.'),
    h('div', { class: 'stack-lg' }, cards(s, manager, false),
      m ? h('div', { class: 'stat-grid' }, [['Frais de fourrière encaissés', m.fees_collected, 'amber'], ['Frais en cours (véhicules présents)', m.fees_pending, 'blue'], ['Montant total des ventes', m.sales_total, 'green'], ['Prix de vente moyen', m.sales_average, 'green'], ['Valeur des véhicules à vendre', m.for_sale_value, 'violet'], ['Réductions accordées (codes promo)', m.discounts_total, 'amber']]
        .map(([l, n, tone]) => h('div', { class: `stat ${tone}` }, h('div', { class: 'n num' }, money(n)), h('div', { class: 'l' }, l)))) : null,
      h('div', { class: 'two-col' }, h('section', { class: 'card card-pad' }, h('h2', { class: 'card-title', style: { marginBottom: '10px' } }, '30 derniers jours'), dayBox),
        h('section', { class: 'card card-pad' }, h('h2', { class: 'card-title', style: { marginBottom: '10px' } }, 'Répartition par statut'), stBox)),
      manager && s.by_staff && s.by_staff.length ? h('section', { class: 'card card-pad' }, h('h2', { class: 'card-title', style: { marginBottom: '10px' } }, 'Véhicules ajoutés par membre'), staffBox) : null,
      h('section', { class: 'card' }, h('div', { class: 'table-wrap' }, h('table', { class: 'table' }, h('tbody', {}, rows.map(([l, n]) => h('tr', {}, h('td', {}, l), h('td', { class: 'num', style: { textAlign: 'right', fontWeight: '700' } }, n)))))))));
  const inst = [];
  loadChart().then(async (Chart) => {
    Chart.defaults.font.family = "'Barlow', system-ui, sans-serif"; Chart.defaults.color = '#55687a';
    (await charts(dayBox, s)).forEach((c) => inst.push(c));
    const ent = Object.entries(s.status_breakdown);
    const c1 = h('canvas', {}); stBox.append(c1);
    inst.push(new Chart(c1, { type: 'doughnut', data: { labels: ent.map(([k]) => (STATUS[k] || [k])[0]), datasets: [{ data: ent.map(([, n]) => n), backgroundColor: ent.map(([k]) => STATUS_COLOR[k] || C.gray), borderWidth: 2 }] }, options: { responsive: true, maintainAspectRatio: false, plugins: { legend: { position: 'right' } } } }));
    if (manager && s.by_staff && s.by_staff.length) {
      const c2 = h('canvas', {}); staffBox.append(c2);
      inst.push(new Chart(c2, { type: 'bar', data: { labels: s.by_staff.map((x) => x.name), datasets: [{ label: 'Véhicules ajoutés', data: s.by_staff.map((x) => x.count), backgroundColor: C.blue, borderRadius: 6 }] }, options: { indexAxis: 'y', responsive: true, maintainAspectRatio: false, scales: { x: { beginAtZero: true, ticks: { precision: 0 } } }, plugins: { legend: { display: false } } } }));
    }
  }).catch((e) => dayBox.replaceChildren(h('p', { class: 'muted' }, e.message)));
  return { el, destroy: () => inst.forEach((c) => c.destroy()) };
}
