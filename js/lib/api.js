/* Accès à Supabase. Aucune règle de sécurité ici : les droits sont vérifiés par la base (RLS + fonctions). */
import { debounce } from './ui.js';

export const cfg = window.BELLE_ROCHE_CONFIG || {};
export const configured = !!cfg.SUPABASE_URL && !!cfg.SUPABASE_KEY && !/votre-projet|xxxxx/i.test(cfg.SUPABASE_URL + cfg.SUPABASE_KEY);
export const sb = configured
  ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }, realtime: { params: { eventsPerSecond: 5 } } })
  : null;

/* ---------- État partagé ---------- */
export const state = { session: null, profile: null, unread: { messages: 0, notifications: 0, conversations: {} } };
const listeners = new Set();
export const subscribe = (fn) => { listeners.add(fn); return () => listeners.delete(fn); };
export const emit = () => listeners.forEach((fn) => fn(state));
export const role = () => (state.profile ? state.profile.role : null);
export const isLogged = () => !!(state.session && state.profile);
export const isStaff = () => ['employe', 'gerant', 'admin'].includes(role());
export const isPolice = () => role() === 'forces_ordre';
export const isManager = () => ['gerant', 'admin'].includes(role());
export const isAdmin = () => role() === 'admin';

/* ---------- Appels ---------- */
function friendly(m) {
  if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Connexion impossible. Vérifiez votre réseau puis réessayez.';
  if (/JWT expired/i.test(m)) return 'Votre session a expiré. Reconnectez-vous.';
  if (/permission denied|row-level security/i.test(m)) return "Vous n'avez pas le droit d'effectuer cette action.";
  return m;
}
const fail = (error) => { throw new Error(friendly(error.message || 'Erreur inconnue')); };
export async function rpc(name, args = {}) { const { data, error } = await sb.rpc(name, args); if (error) fail(error); return data; }
async function q(builder) { const { data, error } = await builder; if (error) fail(error); return data; }

/* ---------- Session ---------- */
export async function syncSession() {
  const { data } = await sb.auth.getSession();
  state.session = data.session;
  state.profile = null;
  if (data.session) {
    const { data: p } = await sb.from('profiles').select('*').eq('id', data.session.user.id).maybeSingle();
    if (p) state.profile = p;
    else { await sb.auth.signOut(); state.session = null; }
  }
  if (!state.session) state.unread = { messages: 0, notifications: 0, conversations: {} };
  emit();
}
export const authFlow = { busy: false };
const BAD = 'Nom, prénom ou mot de passe incorrect.';
async function signIn(email, password) { const { error } = await sb.auth.signInWithPassword({ email, password }); if (error) throw new Error(BAD); await syncSession(); }
export async function login(nom, prenom, password) {
  authFlow.busy = true;
  try {
    const email = await rpc('get_login_email', { p_nom: nom, p_prenom: prenom });
    if (!email) throw new Error(BAD);
    await signIn(email, password);
  } finally { authFlow.busy = false; }
}
export async function register(nom, prenom, password) {
  authFlow.busy = true;
  try {
    const r = await rpc('register_account', { p_nom: nom, p_prenom: prenom, p_password: password });
    await signIn(r.email, password);
    return r.recovery_code;
  } finally { authFlow.busy = false; }
}
export async function logout() {
  authFlow.busy = true;
  try { await sb.auth.signOut(); await syncSession(); } finally { authFlow.busy = false; }
}
export const resetPassword = (nom, prenom, code, pw) => rpc('reset_password_with_code', { p_nom: nom, p_prenom: prenom, p_code: code, p_new_password: pw });
export const changePassword = (cur, nw) => rpc('change_my_password', { p_current: cur, p_new: nw });
export const newRecoveryCode = (pw) => rpc('regenerate_recovery_code', { p_password: pw });
export const updatePhone = (p) => rpc('update_my_profile', { p_phone: p });
export const heartbeat = () => { rpc('process_auto_sale').catch(() => {}); if (isLogged()) rpc('touch_last_seen').catch(() => {}); };

/* ---------- Public ---------- */
export const pricing = () => q(sb.from('pricing_settings').select('*').eq('id', 1).maybeSingle());
export const impound = () => rpc('public_impound_vehicles');
export const forSale = () => rpc('public_sale_vehicles');

/* ---------- Réclamations et messagerie ---------- */
export const claim = (id) => rpc('claim_vehicle', { p_vehicle_id: id });
export const interest = (id) => rpc('express_interest', { p_vehicle_id: id });
export const conversations = () => q(sb.from('conversations').select('*').order('last_message_at', { ascending: false }).limit(300));
export const conversation = (id) => q(sb.from('conversations').select('*').eq('id', id).maybeSingle());
export const vehiclesByIds = (ids) => (ids.length ? q(sb.from('vehicles_ext').select('id,plate,model,color,status,photos,created_at,current_amount,days_in_impound,sale_price,sale_status,sale_promo_percent,sale_effective_price').in('id', ids)) : Promise.resolve([]));
export const messages = (id) => q(sb.from('messages').select('*').eq('conversation_id', id).order('created_at', { ascending: true }).limit(500));
export const sendMessage = (conversation_id, content) => q(sb.from('messages').insert({ conversation_id, content }));
export const closeConversation = (id) => rpc('close_conversation', { p_conversation_id: id });
export const deleteConversation = (id) => rpc('delete_conversation', { p_conversation_id: id });
export const markRead = (id) => rpc('mark_conversation_read', { p_conversation_id: id });
export const notifications = () => q(sb.from('notifications').select('*').order('created_at', { ascending: false }).limit(30));
export const markNotifications = (ids) => rpc('mark_notifications_read', { p_ids: ids || null });
export async function refreshUnread() {
  if (!isLogged()) return;
  try { state.unread = await rpc('get_unread_summary'); emit(); } catch { /* réseau : on réessaiera */ }
}

/* ---------- Véhicules (personnel) ---------- */
export const vehicles = () => q(sb.from('vehicles_ext').select('*').order('created_at', { ascending: false }).limit(1000));
export const vehicle = (id) => q(sb.from('vehicles_ext').select('*').eq('id', id).maybeSingle());
export const vehicleConversations = (id) => q(sb.from('conversations').select('*').eq('vehicle_id', id).order('created_at', { ascending: false }));
export const vehicleClaims = (id) => q(sb.from('claims').select('*').eq('vehicle_id', id).order('created_at', { ascending: false }));
export const vehicleLogs = (id) => q(sb.from('activity_logs').select('*').eq('vehicle_id', id).order('created_at', { ascending: false }).limit(100));
export const createVehicle = (a) => rpc('create_vehicle', { p_id: a.id, p_plate: a.plate, p_model: a.model, p_color: a.color, p_notes: a.notes || null, p_photo_paths: a.paths });
export const updateVehicle = (a) => rpc('update_vehicle', { p_id: a.id, p_plate: a.plate, p_model: a.model, p_color: a.color, p_notes: a.notes || null, p_handling_fee: a.fee ?? null, p_daily_rate: a.rate ?? null });
export const deleteVehicle = (id) => rpc('delete_vehicle', { p_id: id });
export const addPhotos = (id, paths) => rpc('add_vehicle_photos', { p_vehicle_id: id, p_paths: paths });
export const removePhoto = (photoId) => rpc('remove_vehicle_photo', { p_photo_id: photoId });
export const setCover = (photoId) => rpc('set_cover_photo', { p_photo_id: photoId });
export const markRecovered = (vehicleId, claimId) => rpc('mark_vehicle_recovered', { p_vehicle_id: vehicleId, p_claim_id: claimId || null });
export const archive = (id) => rpc('archive_vehicle', { p_vehicle_id: id });
export const unarchive = (id) => rpc('unarchive_vehicle', { p_vehicle_id: id });
export const listForSale = (id, price, description, paths, promoPercent) => rpc('list_vehicle_for_sale', { p_vehicle_id: id, p_price: price, p_description: description, p_new_photo_paths: paths || [], p_promo_percent: promoPercent ?? null });
export const updateSale = (id, price, description, promoPercent) => rpc('update_sale', { p_vehicle_id: id, p_price: price, p_description: description, p_promo_percent: promoPercent ?? null });
export const withdrawSale = (id) => rpc('withdraw_sale', { p_vehicle_id: id });
export const markSold = (id, convId, price, buyer, optionIds) => rpc('mark_vehicle_sold', { p_vehicle_id: id, p_conversation_id: convId || null, p_sold_price: price ?? null, p_buyer_name: buyer || null, p_option_ids: optionIds || [] });
export const stats = () => rpc('get_stats');
export const logs = (limit = 100, offset = 0) => q(sb.from('activity_logs').select('*').order('created_at', { ascending: false }).range(offset, offset + limit - 1));
export const updatePricing = (a) => rpc('update_pricing', { p_handling_fee: a.fee, p_daily_rate: a.rate, p_auto_sale_days: a.days, p_employee_delete_minutes: a.minutes, p_apply_to_current: !!a.apply });

/* ---------- Personnel ---------- */
export async function staffMembers() {
  const rows = await q(sb.from('staff').select('*').order('hired_at', { ascending: false }));
  const ids = [...new Set(rows.map((r) => r.user_id))];
  const profs = ids.length ? await q(sb.from('profiles').select('id,nom,prenom,role,last_seen_at,created_at,is_main_admin').in('id', ids)) : [];
  const by = Object.fromEntries(profs.map((p) => [p.id, p]));
  return rows.map((r) => ({ ...r, profile: by[r.user_id] || null }));
}
export async function searchClients(term) {
  const t = String(term || '').trim().replace(/[%*,()]/g, '');
  if (t.length < 2) return [];
  const [a, b] = await Promise.all([
    q(sb.from('profiles').select('id,nom,prenom,role').eq('role', 'client').ilike('nom', `%${t}%`).limit(15)),
    q(sb.from('profiles').select('id,nom,prenom,role').eq('role', 'client').ilike('prenom', `%${t}%`).limit(15)),
  ]);
  const seen = new Map(); [...a, ...b].forEach((p) => seen.set(p.id, p));
  return [...seen.values()];
}
export const staffCreate = (nom, prenom, password, roleName) => rpc('staff_create_account', { p_nom: nom, p_prenom: prenom, p_password: password, p_role: roleName });
export const staffRecruit = (id, roleName) => rpc('staff_recruit_existing', { p_user_id: id, p_role: roleName });
export const staffFire = (id, reason) => rpc('staff_fire', { p_user_id: id, p_reason: reason || null });
export const staffSetRole = (id, roleName) => rpc('staff_set_role', { p_user_id: id, p_role: roleName });
export const staffResetPassword = (id, pw) => rpc('staff_reset_password', { p_user_id: id, p_new_password: pw });

/* ---------- Codes promo ---------- */
export const applyCode = (convId, code) => rpc('apply_discount_code', { p_conversation_id: convId, p_code: code });
export const removeDiscount = (convId) => rpc('remove_conversation_discount', { p_conversation_id: convId });
export const codes = () => rpc('list_discount_codes');
export const codeUses = (id) => rpc('list_discount_redemptions', { p_code_id: id });
export const createCode = (o) => rpc('create_discount_code', { p_code: o.code, p_percent: o.percent, p_scope: o.scope, p_max_uses: o.maxUses ?? null, p_expires_at: o.expiresAt || null, p_once_per_client: o.once !== false, p_note: o.note || null });
export const toggleCode = (id, active) => rpc('set_discount_code_active', { p_id: id, p_active: active });
export const deleteCode = (id) => rpc('delete_discount_code', { p_id: id });

/* ---------- Options de vente (extras choisis à l'achat) ---------- */
export const activeSaleOptions = () => rpc('active_sale_options');
export const saleOptions = () => rpc('list_sale_options');
export const createSaleOption = (label, price) => rpc('create_sale_option', { p_label: label, p_price: price });
export const toggleSaleOption = (id, active) => rpc('set_sale_option_active', { p_id: id, p_active: active });
export const deleteSaleOption = (id) => rpc('delete_sale_option', { p_id: id });

/* ---------- Tarification anticipée et achat direct ---------- */
export const setPlannedSale = (id, price, description) => rpc('set_planned_sale', { p_vehicle_id: id, p_price: price, p_description: description });
export const buyNow = (convId, optionIds) => rpc('buy_vehicle_now', { p_conversation_id: convId, p_option_ids: optionIds || [] });
export const forceForSale = (id) => rpc('admin_force_for_sale', { p_vehicle_id: id });

/* ---------- Forces de l'ordre et saisies ---------- */
export const createPoliceAccount = (nom, prenom, password) => rpc('create_police_account', { p_nom: nom, p_prenom: prenom, p_password: password });
export const policeAccounts = () => rpc('list_police_accounts');
export const revokePolice = (id) => rpc('revoke_police_account', { p_id: id });
export const seizures = () => q(sb.from('seizures').select('*').order('created_at', { ascending: false }).limit(500));
export const createSeizure = (plate, model, color, agency) => rpc('create_seizure', { p_plate: plate, p_model: model, p_color: color, p_agency: agency });
export const recoverSeizure = (id) => rpc('mark_seizure_recovered', { p_id: id });
export const deleteSeizure = (id) => rpc('delete_seizure', { p_id: id });
export const seizureStats = () => rpc('get_seizure_stats');

/* ---------- Discord (gérants) ---------- */
export const discordSettings = () => rpc('get_discord_settings');
export const discordSave = (s) => rpc('save_discord_settings', { p_settings: s });
export const discordResync = () => rpc('discord_resync_all');
export const discordPurge = (kind) => rpc('discord_purge', { p_kind: kind || null });
export const discordTest = (slot) => rpc('discord_send_test', { p_slot: slot });
export const discordRun = () => rpc('discord_run_worker');

/* ---------- Photos (Storage) ---------- */
export const photoUrl = (path) => `${cfg.SUPABASE_URL}/storage/v1/object/public/${cfg.PHOTO_BUCKET}/${path}`;
export async function removeFromStorage(paths) { if (paths && paths.length) await sb.storage.from(cfg.PHOTO_BUCKET).remove(paths).catch(() => {}); }
export async function uploadPhotos(vehicleId, blobs, onProgress) {
  const paths = [];
  try {
    for (let i = 0; i < blobs.length; i++) {
      const path = `${vehicleId}/${crypto.randomUUID()}.jpg`;
      const { error } = await sb.storage.from(cfg.PHOTO_BUCKET).upload(path, blobs[i], { contentType: 'image/jpeg', upsert: false, cacheControl: '31536000' });
      if (error) throw new Error("L'envoi d'une photo a échoué : " + error.message);
      paths.push(path);
      if (onProgress) onProgress(i + 1, blobs.length);
    }
  } catch (e) { await removeFromStorage(paths); throw e; }
  return paths;
}

/* ---------- Temps réel (avec relève par interrogation régulière dans les pages) ---------- */
export function watch(specs, cb, wait = 400) {
  if (!sb) return () => {};
  const fire = debounce(cb, wait);
  const ch = sb.channel('w-' + Math.random().toString(36).slice(2));
  for (const s of specs) ch.on('postgres_changes', { event: '*', schema: 'public', ...s }, fire);
  ch.subscribe();
  return () => { try { sb.removeChannel(ch); } catch { /* rien */ } };
}
