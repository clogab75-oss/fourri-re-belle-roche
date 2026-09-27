/* Messagerie : un fil par demande, en temps réel (avec relève régulière si le temps réel est indisponible). */
import { h, icon, badge, loading, empty, toast, busy, confirmDialog, btn, debounce, openModal, field } from '../lib/ui.js';
import * as api from '../lib/api.js';
import { plateEl } from '../lib/cards.js';
import { rel, dt, dayLabel, timeOnly, ROLE, norm, money } from '../lib/format.js';
import { confirmRecovered, soldModal } from '../lib/actions.js';

export default async function messagesPage(ctx) {
  const me = api.state.profile; const staff = api.isStaff(); const manager = api.isManager();
  let convs = []; const vmap = new Map(); let filter = 'ouvertes'; let term = ''; let selected = ctx.params.id || null;
  let conv = null; let msgs = []; let lastSig = ''; let firstPaint = true; let stop = () => {};

  const chat = h('div', { class: 'chat', 'data-mode': selected ? 'thread' : 'list' });
  const items = h('div', { class: 'items' }, loading());
  const search = h('input', { class: 'input', type: 'search', placeholder: staff ? 'Client, plaque, modèle…' : 'Rechercher…', 'aria-label': 'Rechercher une conversation' });
  search.addEventListener('input', debounce(() => { term = search.value; paintList(); }, 120));
  const chips = h('div', { class: 'chips' }, [['ouvertes', 'Ouvertes'], ['fermees', 'Fermées'], ['toutes', 'Toutes']].map(([k, l]) =>
    h('button', { class: 'chip', type: 'button', 'aria-pressed': String(k === filter), dataset: { k }, onClick: () => { filter = k; [...chips.children].forEach((c) => c.setAttribute('aria-pressed', String(c.dataset.k === k))); paintList(); } }, l)));
  const thread = h('div', { class: 'thread' });
  chat.append(h('div', { class: 'chat-list' }, h('div', { class: 'top' }, search, chips), items), thread);

  const vOf = (c) => vmap.get(c.vehicle_id);
  const label = (c) => { const v = vOf(c); return v ? (c.type === 'claim' || staff ? `${v.plate} · ${v.model}` : v.model) : 'Véhicule indisponible'; };

  async function loadList() {
    convs = await api.conversations();
    const ids = [...new Set(convs.map((c) => c.vehicle_id))];
    (await api.vehiclesByIds(ids)).forEach((v) => vmap.set(v.id, v));
  }
  function paintList() {
    const nt = norm(term);
    const list = convs.filter((c) => (filter === 'toutes' || (filter === 'ouvertes') === (c.status === 'ouverte')) && (!nt || norm(`${c.client_name} ${label(c)}`).includes(nt)));
    const unread = api.state.unread.conversations || {};
    items.replaceChildren(...(list.length ? list.map((c) => {
      const v = vOf(c); const n = unread[c.id] || 0; const img = v && v.photos && v.photos[0] ? api.photoUrl(v.photos[0].path) : null;
      return h('a', { class: `conv${n ? ' unread' : ''}`, href: '#/messages/' + c.id, 'aria-current': String(c.id === selected), onClick: (e) => { e.preventDefault(); select(c.id); } },
        img ? h('img', { class: 'ph', src: img, alt: '', loading: 'lazy' }) : h('span', { class: 'ph' }),
        h('div', { class: 'grow' },
          h('div', { class: 'l1' }, h('span', { class: 'nm' }, staff ? c.client_name : label(c)), h('span', { class: 'tm' }, rel(c.last_message_at))),
          h('span', { class: 'pv' }, staff ? label(c) : (c.last_message_preview || '')),
          h('div', { class: 'l3' }, h('span', { class: `badge plain ${c.type === 'claim' ? '' : 'green'}` }, c.type === 'claim' ? 'Récupération' : 'Achat'),
            c.status === 'fermee' ? h('span', { class: 'badge plain gray' }, 'Fermée') : null, c.status === 'ouverte' && c.discount_percent ? h('span', { class: 'badge plain amber' }, `−${c.discount_percent} %`) : null, n ? h('span', { class: 'count-pill' }, n) : null)));
    }) : [empty(convs.length ? 'Aucune conversation ici' : 'Aucune conversation', convs.length ? 'Changez de filtre.' : (staff ? 'Elles apparaîtront quand un client fera une demande.' : "Cliquez sur « C'est ma voiture » depuis la liste des véhicules pour contacter l'équipe."))]));
  }

  /* ----- Fil de discussion ----- */
  const msgsBox = h('div', { class: 'msgs', role: 'log', 'aria-live': 'polite', 'aria-label': 'Messages' });
  const ta = h('textarea', { class: 'input', rows: '1', maxlength: '2000', placeholder: 'Écrivez votre message…', 'aria-label': 'Votre message' });
  const sendBtn = h('button', { class: 'btn', type: 'button', 'aria-label': 'Envoyer' }, icon('send'), h('span', { class: 'hide-sm' }, 'Envoyer'));
  const head = h('div', { class: 'thread-head' });
  const promo = h('div', {});
  const foot = h('div', {});
  const grow = () => { ta.style.height = 'auto'; ta.style.height = Math.min(ta.scrollHeight, 140) + 'px'; };
  ta.addEventListener('input', grow);
  ta.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
  sendBtn.addEventListener('click', send);
  async function send() {
    const text = ta.value.trim(); if (!text || !conv || conv.status !== 'ouverte') return;
    const cmd = /^\/code(?:\s+(.*))?$/i.exec(text);   // « /code MONCODE » : saisie d'un code promo directement dans le chat
    if (cmd) {
      ta.value = ''; grow();
      if (cmd[1] && cmd[1].trim()) await busy(sendBtn, async () => { const r = await api.applyCode(conv.id, cmd[1]); if (r.ok) { toast(`Code appliqué : −${r.percent} %`, 'ok'); await refreshAll(true); } else toast(r.message, 'warn'); });
      else openCodeModal();
      return;
    }
    await busy(sendBtn, async () => { await api.sendMessage(conv.id, text); ta.value = ''; grow(); await refreshThread(true); });
    ta.focus();
  }
  function openCodeModal() {
    const input = h('input', { class: 'input code-input', id: 'promo-code', type: 'text', maxlength: '40', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', placeholder: 'Ex. PROMO50' });
    const err = h('div', { class: 'form-error', role: 'alert', hidden: true });
    const go = btn('Appliquer le code', { onClick: () => busy(go, async () => {
      err.hidden = true; const r = await api.applyCode(conv.id, input.value);
      if (!r.ok) { err.textContent = r.message; err.hidden = false; input.focus(); return; }
      toast(`Code appliqué : −${r.percent} %`, 'ok'); m.close(); await refreshAll(true);
    }) });
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); go.click(); } });
    const m = openModal({ title: 'Code promo', body: h('div', { class: 'stack' },
      h('p', { class: 'muted' }, conv.type === 'claim' ? 'Saisissez le code pour réduire le montant à régler afin de récupérer le véhicule.' : "Saisissez le code pour réduire le prix d'achat du véhicule."),
      field('Code', input, 'Astuce : vous pouvez aussi taper /code SONCODE dans la conversation.'), err),
      actions: [btn('Annuler', { kind: 'secondary', onClick: () => m.close() }), go] });
  }

  function paintPromo() {
    if (!conv.discount_code) { promo.className = ''; promo.replaceChildren(); return; }
    const v = vOf(conv); const pct = conv.discount_percent; promo.className = 'promo';
    let amounts = null;
    if (conv.status === 'ouverte' && v) {
      const base = Number(conv.type === 'claim' ? v.current_amount : v.sale_price);
      if (base) amounts = [conv.type === 'claim' ? ' · montant actuel ' : ' · prix ', h('s', { class: 'strike' }, money(base)), ' → ', h('strong', {}, money(Math.round(base * (100 - pct) / 100)))];
    }
    promo.replaceChildren(icon('ticket'), h('div', { class: 'grow' }, h('strong', {}, `Code ${conv.discount_code}`), ` : −${pct} %`, amounts, conv.status === 'fermee' ? ' · utilisé pour cette transaction' : null),
      manager && conv.status === 'ouverte' ? btn('Retirer', { sm: true, kind: 'ghost', onClick: async () => {
        if (await confirmDialog({ title: 'Retirer le code promo ?', message: 'La réduction ne s\'appliquera plus. Le code redevient disponible.', confirmLabel: 'Retirer' })) {
          try { await api.removeDiscount(conv.id); toast('Code retiré.', 'ok'); await refreshAll(true); } catch (e) { toast(e.message, 'error'); } } } }) : null);
  }
  function paintHead() {
    const v = vOf(conv);
    const canCode = conv.status === 'ouverte' && !conv.discount_redemption_id && v && (conv.type === 'claim' ? ['en_fourriere', 'reclamee'].includes(v.status) : v.status === 'a_vendre');
    ta.placeholder = canCode ? 'Écrivez votre message… (astuce : /code VOTRECODE)' : 'Écrivez votre message…';
    head.replaceChildren(
      h('button', { class: 'btn-icon back', type: 'button', 'aria-label': 'Retour à la liste', onClick: () => select(null) }, icon('left')),
      v && v.photos && v.photos[0] ? h('img', { class: 'thumb', src: api.photoUrl(v.photos[0].path), alt: '' }) : null,
      h('div', { class: 'grow' },
        h('div', { class: 'row', style: { gap: '8px' } }, v && (conv.type === 'claim' || staff) ? plateEl(v.plate, 'sm') : null, h('strong', {}, v ? v.model : 'Véhicule indisponible'),
          h('span', { class: `badge plain ${conv.status === 'ouverte' ? 'green' : 'gray'}` }, conv.status === 'ouverte' ? 'Ouverte' : 'Fermée')),
        h('div', { class: 'small muted' }, `${conv.type === 'claim' ? 'Demande de récupération' : 'Intérêt pour l\'achat'}${staff ? ' · ' + conv.client_name : ''} · ouverte ${rel(conv.created_at)}`)),
      h('div', { class: 'row', style: { gap: '6px' } },
        staff && v ? h('a', { class: 'btn secondary sm', href: '#/admin/vehicules/' + conv.vehicle_id }, 'Fiche') : null,
        conv.status === 'ouverte' && staff && conv.type === 'claim' && v && v.status === 'reclamee' ? btn('Récupéré', { sm: true, ic: 'check', onClick: async () => { if (await confirmRecovered(v, conv.claim_id, conv.client_name, conv.discount_percent)) await refreshAll(); } }) : null,
        conv.status === 'ouverte' && manager && conv.type === 'vente' && v && v.status === 'a_vendre' ? btn('Vendu', { sm: true, ic: 'check', onClick: () => soldModal(v, [conv], refreshAll) }) : null,
        canCode ? btn('Code promo', { sm: true, kind: 'secondary', ic: 'ticket', onClick: openCodeModal }) : null,
        conv.status === 'ouverte' ? btn('Fermer', { sm: true, kind: 'secondary', onClick: async () => {
          if (await confirmDialog({ title: 'Fermer la conversation ?', message: 'Elle sera conservée et consultable, mais plus personne ne pourra écrire.', confirmLabel: 'Fermer' })) {
            try { await api.closeConversation(conv.id); toast('Conversation fermée.', 'ok'); await refreshAll(); } catch (e) { toast(e.message, 'error'); }
          } } }) : null,
        manager ? btn('', { sm: true, kind: 'secondary', ic: 'trash', title: 'Supprimer définitivement', onClick: async () => {
          if (await confirmDialog({ title: 'Supprimer définitivement ?', message: 'La conversation et tous ses messages seront effacés. Cette action est irréversible.', confirmLabel: 'Supprimer', danger: true })) {
            try { await api.deleteConversation(conv.id); toast('Conversation supprimée.', 'ok'); selected = null; conv = null; history.pushState(null, '', '#/messages'); await refreshAll(); } catch (e) { toast(e.message, 'error'); }
          } } }) : null));
    foot.replaceChildren(conv.status === 'ouverte'
      ? h('div', { class: 'composer' }, ta, sendBtn)
      : h('div', { class: 'closed-note' }, `Conversation fermée ${conv.closed_by_name ? 'par ' + conv.closed_by_name + ' ' : ''}${rel(conv.closed_at)}. Elle reste consultable.`));
  }
  function paintMsgs(forceBottom) {
    const sig = msgs.length + ':' + (msgs.length ? msgs[msgs.length - 1].id : '');
    if (sig === lastSig && !forceBottom) return;
    lastSig = sig;
    const near = msgsBox.scrollHeight - msgsBox.scrollTop - msgsBox.clientHeight < 140;
    let day = ''; const out = [];
    for (const m of msgs) {
      const d = dayLabel(m.created_at); if (d !== day) { day = d; out.push(h('div', { class: 'day' }, d)); }
      if (m.kind === 'system') { out.push(h('div', { class: 'bubble sys' }, m.content)); continue; }
      const mine = m.sender_id === me.id;
      out.push(h('div', { class: `bubble${mine ? ' mine' : ''}` },
        h('div', { class: 'who' }, mine ? 'Vous' : m.sender_name, m.sender_role !== 'client' ? h('span', { class: 'role' }, ROLE[m.sender_role] || m.sender_role) : null),
        m.content, h('div', { class: 'tm' }, timeOnly(m.created_at))));
    }
    msgsBox.replaceChildren(...out);
    if (firstPaint || forceBottom || near) msgsBox.scrollTop = msgsBox.scrollHeight;
    firstPaint = false;
  }
  const markReadSoon = debounce(async () => { if (selected && document.visibilityState === 'visible') { await api.markRead(selected).catch(() => {}); api.refreshUnread(); } }, 300);
  async function refreshThread(force) {
    if (!selected) return;
    conv = convs.find((c) => c.id === selected) || await api.conversation(selected);
    if (!conv) { thread.replaceChildren(h('div', { class: 'chat-empty' }, h('div', {}, h('h3', {}, 'Conversation introuvable'), h('p', { class: 'muted' }, 'Elle a peut-être été supprimée.')))); return; }
    if (!vmap.has(conv.vehicle_id)) (await api.vehiclesByIds([conv.vehicle_id])).forEach((v) => vmap.set(v.id, v));
    msgs = await api.messages(selected);
    if (!thread.contains(msgsBox)) { thread.replaceChildren(head, promo, msgsBox, foot); lastSig = ''; firstPaint = true; }
    paintHead(); paintPromo(); paintMsgs(force);
    if (msgs.some((m) => m.sender_id !== me.id && m.kind === 'text')) markReadSoon();
  }
  function select(id) {
    selected = id;
    history.pushState(null, '', id ? '#/messages/' + id : '#/messages');
    chat.dataset.mode = id ? 'thread' : 'list'; lastSig = ''; firstPaint = true;
    if (!id) { conv = null; thread.replaceChildren(placeholder()); paintList(); return; }
    thread.replaceChildren(loading()); paintList();
    refreshThread(true).then(paintList).catch((e) => toast(e.message, 'error'));
  }
  const placeholder = () => h('div', { class: 'chat-empty' }, h('div', {}, icon('message', 'icon'), h('h3', {}, 'Sélectionnez une conversation'), h('p', { class: 'muted' }, 'Vos échanges apparaissent ici en temps réel.')));
  async function refreshAll(force) { await loadList(); paintList(); if (selected) await refreshThread(force); }

  await loadList(); paintList();
  if (selected) await refreshThread(true).catch((e) => thread.replaceChildren(h('div', { class: 'chat-empty' }, e.message))); else thread.replaceChildren(placeholder());
  paintList();
  const tick = () => refreshAll().catch(() => {});
  const timer = setInterval(tick, 5000);
  const unwatch = api.watch([{ table: 'messages' }, { table: 'conversations' }], tick, 250);
  const unsub = api.subscribe(() => paintList());
  stop = () => { clearInterval(timer); unwatch(); unsub(); };
  return { el: h('div', { class: 'container page', style: { paddingTop: '20px', paddingBottom: '20px' } }, chat), destroy: () => stop() };
}
