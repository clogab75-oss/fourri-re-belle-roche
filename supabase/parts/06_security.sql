-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 6/7 : sécurité (Row Level Security), droits et vue
--
--  Principe : le navigateur ne peut QUE lire (selon son rôle) et envoyer
--  des messages. Toute autre écriture passe par les fonctions du fichier
--  2 et 3, qui vérifient les permissions dans la base.
-- =====================================================================

-- Fonctions utilisables dans les règles RLS et la vue (sans danger)
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_staff() to anon, authenticated;
grant execute on function private.is_manager() to anon, authenticated;
grant execute on function private.billing_days(timestamptz, timestamptz) to anon, authenticated;
grant execute on function private.billing_amount(numeric, numeric, timestamptz, timestamptz) to anon, authenticated;

-- ---------------------------------------------------------------------
--  Activation de la RLS sur toutes les tables
-- ---------------------------------------------------------------------
alter table public.profiles                  enable row level security;
alter table public.staff                     enable row level security;
alter table public.pricing_settings          enable row level security;
alter table public.vehicles                  enable row level security;
alter table public.vehicle_photos            enable row level security;
alter table public.vehicle_sales             enable row level security;
alter table public.claims                    enable row level security;
alter table public.conversations             enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.messages                  enable row level security;
alter table public.notifications             enable row level security;
alter table public.activity_logs             enable row level security;
alter table public.discount_codes            enable row level security;
alter table public.discount_redemptions      enable row level security;
alter table private.discount_attempts        enable row level security;

-- ---------------------------------------------------------------------
--  Règles de lecture / écriture
-- ---------------------------------------------------------------------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or private.is_staff());

drop policy if exists staff_select on public.staff;
create policy staff_select on public.staff for select to authenticated
  using (private.is_staff());

drop policy if exists pricing_select on public.pricing_settings;
create policy pricing_select on public.pricing_settings for select to anon, authenticated
  using (true);

-- Un véhicule "en attente de mise en vente" n'est visible que des gérants et de l'administrateur.
drop policy if exists vehicles_select on public.vehicles;
create policy vehicles_select on public.vehicles for select to authenticated
  using (private.is_manager()
         or (private.is_staff() and status <> 'attente_vente')
         or exists (select 1 from public.conversations c
                     where c.vehicle_id = vehicles.id and c.client_id = (select auth.uid())));

-- Photos et ventes héritent de la visibilité du véhicule (la RLS de "vehicles" s'applique dans la sous-requête).
drop policy if exists vehicle_photos_select on public.vehicle_photos;
create policy vehicle_photos_select on public.vehicle_photos for select to authenticated
  using (exists (select 1 from public.vehicles v where v.id = vehicle_photos.vehicle_id));

drop policy if exists vehicle_sales_select on public.vehicle_sales;
create policy vehicle_sales_select on public.vehicle_sales for select to authenticated
  using (exists (select 1 from public.vehicles v where v.id = vehicle_sales.vehicle_id));

drop policy if exists claims_select on public.claims;
create policy claims_select on public.claims for select to authenticated
  using (client_id = (select auth.uid()) or private.is_staff());

drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations for select to authenticated
  using (client_id = (select auth.uid()) or private.is_staff());

drop policy if exists participants_select on public.conversation_participants;
create policy participants_select on public.conversation_participants for select to authenticated
  using (user_id = (select auth.uid()) or private.is_staff());

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (private.is_staff()
         or exists (select 1 from public.conversations c
                     where c.id = messages.conversation_id and c.client_id = (select auth.uid())));

-- Envoi d'un message : seul le contenu est fourni par le navigateur.
-- L'auteur, son rôle et la date sont imposés par un trigger côté base.
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (sender_id = (select auth.uid()) and kind = 'text'
              and exists (select 1 from public.conversations c
                           where c.id = conversation_id and c.status = 'ouverte'
                             and (c.client_id = (select auth.uid()) or private.is_staff())));

drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists notifications_delete on public.notifications;
create policy notifications_delete on public.notifications for delete to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists logs_select on public.activity_logs;
create policy logs_select on public.activity_logs for select to authenticated
  using (private.is_manager()
         or (private.is_staff() and vehicle_id is not null
             and exists (select 1 from public.vehicles v where v.id = activity_logs.vehicle_id)));

-- ---------------------------------------------------------------------
--  Vue des véhicules avec calculs côté serveur (jours, montant, photos…)
--  security_invoker : la vue applique les règles RLS de l'utilisateur.
-- ---------------------------------------------------------------------
create or replace view public.vehicles_ext with (security_invoker = true) as
select
  v.id, v.plate, v.plate_key, v.model, v.color, v.notes, v.status, v.status_changed_at,
  v.created_at, v.created_by,
  case when private.is_staff() then v.created_by_name end as created_by_name,
  v.handling_fee, v.daily_rate, v.billing_end_at, v.final_amount,
  v.recovered_at, v.recovered_by_name, v.auto_flagged_at, v.updated_at,
  case when private.is_staff() then v.updated_by_name end as updated_by_name,
  private.billing_days(v.created_at, v.billing_end_at) as days_in_impound,
  coalesce(v.final_amount, private.billing_amount(v.handling_fee, v.daily_rate, v.created_at, v.billing_end_at)) as current_amount,
  coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'path', p.storage_path, 'position', p.position)
                             order by p.position, p.created_at)
              from public.vehicle_photos p where p.vehicle_id = v.id), '[]'::jsonb) as photos,
  (select count(*) from public.conversations c
    where c.vehicle_id = v.id and c.type = 'claim' and c.status = 'ouverte') as open_claims,
  s.id as sale_id, s.status as sale_status, s.price as sale_price, s.description as sale_description,
  s.listed_at as sale_listed_at, s.sold_at, s.sold_price, s.buyer_name,
  v.discount_code, v.discount_percent, v.original_amount,
  s.discount_code as sale_discount_code, s.discount_percent as sale_discount_percent, s.selected_options
from public.vehicles v
left join lateral (select * from public.vehicle_sales x where x.vehicle_id = v.id
                    order by x.listed_at desc limit 1) s on true;

-- ---------------------------------------------------------------------
--  Droits sur les tables : lecture seule + envoi de message
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles', 'staff', 'pricing_settings', 'vehicles', 'vehicle_photos',
                           'vehicle_sales', 'claims', 'conversations', 'conversation_participants',
                           'messages', 'notifications', 'activity_logs', 'vehicles_ext', 'discount_codes', 'discount_redemptions'] loop
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

grant select on public.pricing_settings to anon, authenticated;
grant select on public.profiles, public.staff, public.vehicles, public.vehicle_photos,
                public.vehicle_sales, public.claims, public.conversations,
                public.conversation_participants, public.messages, public.notifications,
                public.activity_logs, public.vehicles_ext to authenticated;
grant insert (conversation_id, content) on public.messages to authenticated;
grant delete on public.notifications to authenticated;

-- ---------------------------------------------------------------------
--  Droits sur les fonctions (RPC) : rien n'est ouvert par défaut
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  fn_anon constant text[] := array['register_account', 'get_login_email', 'reset_password_with_code',
                                   'public_impound_vehicles', 'public_sale_vehicles', 'process_auto_sale'];
  fn_auth constant text[] := array['change_my_password', 'regenerate_recovery_code', 'update_my_profile',
    'touch_last_seen', 'staff_create_account', 'staff_recruit_existing', 'staff_fire', 'staff_set_role',
    'staff_reset_password', 'create_vehicle', 'update_vehicle', 'delete_vehicle', 'add_vehicle_photos',
    'remove_vehicle_photo', 'set_cover_photo', 'mark_vehicle_recovered', 'archive_vehicle', 'unarchive_vehicle',
    'list_vehicle_for_sale', 'update_sale', 'withdraw_sale', 'mark_vehicle_sold', 'claim_vehicle',
    'express_interest', 'close_conversation', 'delete_conversation', 'mark_conversation_read',
    'mark_notifications_read', 'get_unread_summary', 'update_pricing', 'get_stats',
    'get_discord_settings', 'save_discord_settings', 'discord_resync_all', 'discord_purge',
    'discord_send_test', 'discord_run_worker',
    'create_discount_code', 'set_discount_code_active', 'delete_discount_code', 'apply_discount_code',
    'remove_conversation_discount', 'list_discount_codes', 'list_discount_redemptions'];
begin
  for r in select p.oid::regprocedure as sig, p.proname
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname = any (fn_anon || fn_auth || array['bootstrap_main_admin']) loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    if r.proname = any (fn_anon) then
      execute format('grant execute on function %s to anon, authenticated', r.sig);
    elsif r.proname = any (fn_auth) then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;  -- bootstrap_main_admin : aucun droit (SQL Editor uniquement)
  end loop;
end $$;
