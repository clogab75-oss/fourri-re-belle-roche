-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 5/8 : options de vente, tarification anticipée, achat direct,
--                comptes des forces de l'ordre, saisies
--
--  • Options de vente : le gérant crée des extras à prix fixe (« Réservoir
--    plein », « Moteur réparé »…) que l'acheteur coche au moment d'acheter.
--  • Tarification anticipée : un gérant peut préparer le prix de vente
--    d'un véhicule dès son arrivée, sans attendre le délai de 7 jours.
--    Si un prix est prêt au moment du passage automatique, le véhicule
--    part directement en vente ; sinon il rejoint l'attente habituelle.
--  • Achat direct : depuis sa conversation, un client peut acheter le
--    véhicule tout de suite (le prix — annonce, promotion, code, options —
--    est toujours calculé par le serveur, jamais fourni par le client).
--  • Forces de l'ordre : rôle séparé, sans aucun accès à la fourrière,
--    limité à la consultation des saisies et à leur clôture.
-- =====================================================================

-- ---------------------------------------------------------------------
--  Rôle « forces de l'ordre »
-- ---------------------------------------------------------------------
create or replace function private.is_police() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'forces_ordre');
$$;

create or replace function private.require_police_or_staff() returns uuid
language plpgsql set search_path = public, private as $$
declare v uuid := private.require_login();
begin
  if not (private.is_staff() or private.is_police()) then
    raise exception 'Accès réservé au personnel de la fourrière et aux forces de l''ordre.' using errcode = '42501';
  end if;
  return v;
end $$;

create or replace function private.require_admin() returns uuid
language plpgsql set search_path = public, private as $$
declare v uuid := private.require_login();
begin
  if not private.is_main_admin() then
    raise exception 'Accès réservé à l''administrateur.' using errcode = '42501';
  end if;
  return v;
end $$;

-- =====================================================================
--  MISE EN VENTE FORCÉE (administrateur uniquement) : ne pas attendre le
--  délai habituel. Reprend exactement la logique du passage automatique,
--  déclenchée à la demande pour un seul véhicule.
-- =====================================================================
create or replace function public.admin_force_for_sale(p_vehicle_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_admin(); v_name text := private.display_name(v_uid);
  v_v public.vehicles; v_end timestamptz;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if v_v.status not in ('en_fourriere', 'reclamee') then
    raise exception 'Ce véhicule n''est pas en fourrière.';
  end if;
  if exists (select 1 from public.conversations c where c.vehicle_id = p_vehicle_id and c.type = 'claim' and c.status = 'ouverte') then
    raise exception 'Une demande de récupération est en cours pour ce véhicule : attendez qu''elle soit traitée.';
  end if;
  v_end := now();
  if v_v.planned_price is not null and v_v.planned_description is not null then
    update public.vehicles
       set status = 'a_vendre', status_changed_at = now(), auto_flagged_at = now(),
           billing_end_at = v_end, final_amount = private.billing_amount(v_v.handling_fee, v_v.daily_rate, v_v.created_at, v_end),
           planned_price = null, planned_description = null, updated_by = v_uid, updated_by_name = v_name
     where id = p_vehicle_id;
    insert into public.vehicle_sales (vehicle_id, price, description, listed_by, listed_by_name)
    values (p_vehicle_id, v_v.planned_price, v_v.planned_description, v_uid, v_name || ' (mise en vente forcée)');
    perform private.log_action('sale.list', 'vehicle', p_vehicle_id, p_vehicle_id,
      format('%s a forcé la mise en vente immédiate de %s (%s, %s) à %s, sans attendre', v_name, v_v.plate, v_v.model, v_v.color, private.fmt_money(v_v.planned_price)),
      jsonb_build_object('price', v_v.planned_price, 'forced', true));
  else
    update public.vehicles
       set status = 'attente_vente', status_changed_at = now(), auto_flagged_at = now(),
           billing_end_at = v_end, final_amount = private.billing_amount(v_v.handling_fee, v_v.daily_rate, v_v.created_at, v_end),
           updated_by = v_uid, updated_by_name = v_name
     where id = p_vehicle_id;
    perform private.log_action('vehicle.force_sale', 'vehicle', p_vehicle_id, p_vehicle_id,
      format('%s a forcé le passage de %s (%s, %s) en attente de mise en vente, sans attendre le délai habituel', v_name, v_v.plate, v_v.model, v_v.color));
    perform private.notify_roles(array['gerant', 'admin'], 'auto_sale', 'Véhicule prêt pour la vente',
      format('%s (%s) a été avancé par l''administrateur : préparez son prix.', v_v.plate, v_v.model), '#/admin/ventes', null, p_vehicle_id, v_uid);
  end if;
end $$;
-- p_require_active : true pour un achat en libre-service (l'option doit être active),
--                     false pour un gérant qui finalise une vente (plus de souplesse).
create or replace function private.options_snapshot(p_ids uuid[], p_require_active boolean default false)
returns table (items jsonb, total numeric)
language plpgsql security definer set search_path = public, private as $$
declare v_ids uuid[] := coalesce(p_ids, '{}');
begin
  if array_length(v_ids, 1) is not null then
    if exists (select 1 from unnest(v_ids) x (id) left join public.sale_options o on o.id = x.id where o.id is null) then
      raise exception 'Une option sélectionnée est introuvable.';
    end if;
    if p_require_active and exists (select 1 from public.sale_options o where o.id = any (v_ids) and not o.active) then
      raise exception 'Une option sélectionnée n''est plus disponible.';
    end if;
  end if;
  return query
    select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'price', o.price) order by o.label), '[]'::jsonb),
           coalesce(sum(o.price), 0)
      from public.sale_options o where o.id = any (v_ids);
end $$;

-- =====================================================================
--  OPTIONS DE VENTE (réservé aux gérants pour la gestion)
-- =====================================================================
create or replace function public.create_sale_option(p_label text, p_price numeric) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_label text := btrim(coalesce(p_label, '')); v_id uuid;
begin
  if char_length(v_label) < 2 or char_length(v_label) > 60 then raise exception 'Le nom de l''option doit contenir entre 2 et 60 caractères.'; end if;
  if p_price is null or p_price < 0 or p_price > 100000000 then raise exception 'Indiquez un prix valide (0 ou plus).'; end if;
  begin
    insert into public.sale_options (label, price, created_by, created_by_name)
    values (v_label, p_price, v_uid, private.display_name(v_uid)) returning id into v_id;
  exception when unique_violation then
    raise exception 'Une option porte déjà ce nom.';
  end;
  perform private.log_action('option.create', 'sale_option', v_id, null,
    format('%s a créé l''option « %s » (%s)', private.display_name(v_uid), v_label, private.fmt_money(p_price)));
  return v_id;
end $$;

create or replace function public.set_sale_option_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_o public.sale_options;
begin
  update public.sale_options set active = coalesce(p_active, false) where id = p_id returning * into v_o;
  if not found then raise exception 'Option introuvable.'; end if;
  perform private.log_action('option.toggle', 'sale_option', p_id, null,
    format('%s a %s l''option « %s »', private.display_name(v_uid), case when v_o.active then 'réactivé' else 'désactivé' end, v_o.label));
end $$;

create or replace function public.delete_sale_option(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_o public.sale_options;
begin
  select * into v_o from public.sale_options where id = p_id for update;
  if not found then raise exception 'Option introuvable.'; end if;
  if exists (select 1 from public.vehicle_sales s, jsonb_array_elements(s.options) o where (o ->> 'id')::uuid = p_id) then
    raise exception 'Cette option a déjà été utilisée dans une vente : désactivez-la plutôt que de la supprimer.';
  end if;
  delete from public.sale_options where id = p_id;
  perform private.log_action('option.delete', 'sale_option', p_id, null,
    format('%s a supprimé l''option « %s »', private.display_name(v_uid), v_o.label));
end $$;

create or replace function public.list_sale_options() returns table (id uuid, label text, price numeric, active boolean, uses integer, created_at timestamptz)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return query
    select o.id, o.label, o.price, o.active,
           (select count(*)::integer from public.vehicle_sales s, jsonb_array_elements(s.options) x where (x ->> 'id')::uuid = o.id),
           o.created_at
      from public.sale_options o order by o.created_at desc;
end $$;

-- Options actives, utilisables par n'importe quel compte connecté (choix à l'achat).
create or replace function public.active_sale_options() returns table (id uuid, label text, price numeric)
language sql stable security definer set search_path = public, private as $$
  select id, label, price from public.sale_options where active order by created_at;
$$;

-- =====================================================================
--  TARIFICATION ANTICIPÉE (le véhicule est encore en fourrière)
-- =====================================================================
-- p_price = null efface la préparation. Sinon, prix + description obligatoires (mêmes règles qu'une mise en vente).
create or replace function public.set_planned_sale(p_vehicle_id uuid, p_price numeric, p_description text) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_v public.vehicles; v_desc text := nullif(btrim(coalesce(p_description, '')), '');
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if v_v.status not in ('en_fourriere', 'reclamee') then
    raise exception 'Le tarif ne peut être préparé que pendant que le véhicule est en fourrière.';
  end if;
  if p_price is null then
    update public.vehicles set planned_price = null, planned_description = null where id = p_vehicle_id;
    perform private.log_action('sale.plan_clear', 'vehicle', p_vehicle_id, p_vehicle_id,
      format('%s a annulé le tarif préparé pour %s', private.display_name(v_uid), v_v.plate));
    return;
  end if;
  if p_price <= 0 or p_price > 1000000000 then raise exception 'Indiquez un prix de vente valide.'; end if;
  if v_desc is null or char_length(v_desc) < 3 then raise exception 'Ajoutez une description.'; end if;
  if char_length(v_desc) > 2000 then raise exception 'Description trop longue (2000 caractères maximum).'; end if;
  update public.vehicles set planned_price = p_price, planned_description = v_desc where id = p_vehicle_id;
  perform private.log_action('sale.plan', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a préparé un prix de vente pour %s (%s, %s) : %s', private.display_name(v_uid), v_v.plate, v_v.model, v_v.color, private.fmt_money(p_price)));
end $$;

-- =====================================================================
--  ACHAT DIRECT DEPUIS LA CONVERSATION (client)
-- =====================================================================
create or replace function public.buy_vehicle_now(p_conversation_id uuid, p_option_ids uuid[] default '{}') returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_login();
  v_c public.conversations; v_v public.vehicles; v_s public.vehicle_sales;
  v_base numeric; v_pct integer; v_code text; v_price numeric; v_items jsonb; v_opts_total numeric;
  v_opt_txt text; v_note text := ''; r record;
begin
  select * into v_c from public.conversations where id = p_conversation_id for update;
  if not found or v_c.client_id is distinct from v_uid or v_c.type <> 'vente' then
    raise exception 'Conversation introuvable.' using errcode = '42501';
  end if;
  if v_c.status <> 'ouverte' then raise exception 'Cette conversation est fermée.'; end if;
  select * into v_v from public.vehicles where id = v_c.vehicle_id for update;
  if not found or v_v.status <> 'a_vendre' then raise exception 'Ce véhicule n''est plus à vendre.'; end if;
  select * into v_s from public.vehicle_sales where vehicle_id = v_v.id and status = 'a_vendre' for update;
  if not found then raise exception 'Cette annonce n''est plus disponible.'; end if;

  v_base := case when v_s.promo_percent is null then v_s.price else round(v_s.price * (100 - v_s.promo_percent) / 100) end;
  if v_c.discount_redemption_id is not null
     and exists (select 1 from public.discount_redemptions where id = v_c.discount_redemption_id and status = 'appliquee') then
    v_pct := v_c.discount_percent; v_code := v_c.discount_code;
  end if;
  select items, total into v_items, v_opts_total from private.options_snapshot(p_option_ids, true);
  v_price := (case when v_pct is null then v_base else round(v_base * (100 - v_pct) / 100) end) + v_opts_total;

  update public.vehicle_sales
     set status = 'vendue', sold_at = now(), sold_price = v_price, buyer_id = v_uid, buyer_name = v_c.client_name,
         sold_by = null, sold_by_name = v_c.client_name || ' (achat direct)',
         discount_code = v_code, discount_percent = v_pct, options = v_items, options_total = v_opts_total
   where id = v_s.id;
  if v_c.discount_redemption_id is not null then
    update public.discount_redemptions
       set status = 'utilisee', used_at = now(), original_amount = v_base, final_amount = v_price - v_opts_total
     where id = v_c.discount_redemption_id and status = 'appliquee';
  end if;
  update public.vehicles set status = 'vendue', status_changed_at = now() where id = v_v.id;

  select string_agg(format('%s (%s)', o ->> 'label', private.fmt_money((o ->> 'price')::numeric)), ', ') into v_opt_txt
    from jsonb_array_elements(v_items) o;
  if v_opt_txt is not null then v_note := format(' + options : %s', v_opt_txt); end if;

  for r in select id, client_id from public.conversations where vehicle_id = v_v.id and type = 'vente' and status = 'ouverte' loop
    if r.id = p_conversation_id then
      perform private.close_conv(r.id, v_uid, format('Achat confirmé pour %s%s. Merci pour votre achat !', private.fmt_money(v_price), v_note));
    else
      perform private.close_conv(r.id, v_uid, 'Ce véhicule a été vendu. La conversation est fermée.');
    end if;
    if r.client_id is distinct from v_uid then
      perform private.notify_user(r.client_id, 'sale', 'Vente clôturée',
        format('Le véhicule %s a été vendu.', v_v.model), '#/messages/' || r.id, r.id, v_v.id);
    end if;
  end loop;

  perform private.log_action('sale.sold', 'vehicle', v_v.id, v_v.id,
    format('%s a acheté directement le véhicule %s (%s) pour %s%s%s', v_c.client_name, v_v.plate, v_v.model, private.fmt_money(v_price),
           case when v_pct is null then '' else format(' (code %s, −%s %%)', v_code, v_pct) end, v_note),
    jsonb_build_object('price', v_price, 'buyer', v_c.client_name, 'self_service', true, 'options_total', v_opts_total));
end $$;

-- =====================================================================
--  COMPTES DES FORCES DE L'ORDRE (aucun droit sur la fourrière)
-- =====================================================================
create or replace function public.create_police_account(p_nom text, p_prenom text, p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare
  v_uid uuid := private.require_manager();
  v_nom text := btrim(coalesce(p_nom, '')); v_prenom text := btrim(coalesce(p_prenom, ''));
  v_nk text; v_pk text; v_id uuid; v_code text;
begin
  perform private.check_identity(v_nom, v_prenom);
  perform private.check_password(p_password);
  v_nk := private.norm_key(v_nom); v_pk := private.norm_key(v_prenom);
  if private.is_reserved_identity(v_nk, v_pk) then raise exception 'Ce nom RP est réservé.'; end if;
  if exists (select 1 from public.profiles where nom_key = v_nk and prenom_key = v_pk) then
    raise exception 'Une personne porte déjà ce nom et ce prénom RP.';
  end if;
  begin
    v_id := private.create_auth_user(v_nom, v_prenom, p_password);
  exception when unique_violation then
    raise exception 'Une personne porte déjà ce nom et ce prénom RP.';
  end;
  update public.profiles set role = 'forces_ordre' where id = v_id;
  v_code := private.issue_recovery_code(v_id);
  perform private.log_action('police.create', 'profile', v_id, null,
    format('%s a créé un compte forces de l''ordre pour %s %s', private.display_name(v_uid), initcap(lower(v_prenom)), initcap(lower(v_nom))));
  return jsonb_build_object('id', v_id, 'recovery_code', v_code);
end $$;

create or replace function public.list_police_accounts() returns table (id uuid, nom text, prenom text, created_at timestamptz, last_seen_at timestamptz)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return query select p.id, p.nom, p.prenom, p.created_at, p.last_seen_at from public.profiles p where p.role = 'forces_ordre' order by p.created_at desc;
end $$;

create or replace function public.revoke_police_account(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_p public.profiles;
begin
  select * into v_p from public.profiles where id = p_id and role = 'forces_ordre' for update;
  if not found then raise exception 'Compte introuvable.'; end if;
  update public.profiles set role = 'client' where id = p_id;
  perform private.log_action('police.revoke', 'profile', p_id, null,
    format('%s a retiré l''accès forces de l''ordre de %s %s', private.display_name(v_uid), v_p.prenom, v_p.nom));
end $$;

-- Nomme un compte client existant comme forces de l'ordre (sans passer par le personnel de la fourrière).
create or replace function public.recruit_police_existing(p_user_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_t public.profiles;
begin
  select * into v_t from public.profiles where id = p_user_id for update;
  if not found then raise exception 'Compte introuvable.'; end if;
  if v_t.role <> 'client' then raise exception 'Cette personne n''est pas un simple compte client.'; end if;
  update public.profiles set role = 'forces_ordre' where id = p_user_id;
  perform private.log_action('police.recruit', 'profile', p_user_id, null,
    format('%s a donné l''accès forces de l''ordre à %s %s', private.display_name(v_uid), v_t.prenom, v_t.nom));
  perform private.notify_user(p_user_id, 'staff', 'Accès forces de l''ordre',
    'Vous pouvez désormais consulter le registre des saisies.', '#/saisies');
end $$;

-- =====================================================================
--  REMETTRE EN VENTE APRÈS UNE VENTE (l'acheteur se rétracte, par exemple).
--  Ne modifie jamais la vente déjà conclue : une nouvelle annonce est créée.
-- =====================================================================
create or replace function public.relist_after_sale(
  p_vehicle_id uuid, p_price numeric default null, p_description text default null, p_promo_percent integer default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_manager(); v_name text := private.display_name(v_uid);
  v_v public.vehicles; v_last public.vehicle_sales; v_price numeric; v_desc text;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if v_v.status <> 'vendue' then raise exception 'Seul un véhicule vendu peut être remis en vente.'; end if;
  select * into v_last from public.vehicle_sales where vehicle_id = p_vehicle_id and status = 'vendue' order by sold_at desc limit 1;
  v_price := coalesce(p_price, v_last.price); v_desc := coalesce(nullif(btrim(coalesce(p_description, '')), ''), v_last.description);
  if v_price is null or v_price <= 0 or v_price > 1000000000 then raise exception 'Indiquez un prix de vente valide.'; end if;
  if v_desc is null or char_length(v_desc) < 3 then raise exception 'Ajoutez une description.'; end if;
  if p_promo_percent is not null and p_promo_percent not between 1 and 99 then
    raise exception 'La promotion affichée doit être comprise entre 1 et 99 %%.';
  end if;
  insert into public.vehicle_sales (vehicle_id, price, description, promo_percent, listed_by, listed_by_name)
  values (p_vehicle_id, v_price, v_desc, p_promo_percent, v_uid, v_name);
  update public.vehicles set status = 'a_vendre', status_changed_at = now(), updated_by = v_uid, updated_by_name = v_name where id = p_vehicle_id;
  perform private.log_action('sale.relist', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a remis en vente %s (%s, %s) à %s', v_name, v_v.plate, v_v.model, v_v.color, private.fmt_money(v_price)),
    jsonb_build_object('price', v_price));
end $$;

-- =====================================================================
--  SAISIES (créées par le personnel de la fourrière, suivies par tous les deux)
-- =====================================================================
create or replace function public.create_seizure(p_plate text, p_model text, p_color text, p_agency text) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_staff(); v_name text := private.display_name(v_uid);
  v_plate text := upper(btrim(coalesce(p_plate, ''))); v_key text; v_model text := btrim(coalesce(p_model, '')); v_color text := btrim(coalesce(p_color, ''));
  v_id uuid;
begin
  if char_length(v_plate) < 2 then raise exception 'Le numéro de plaque est obligatoire.'; end if;
  if v_model = '' then raise exception 'Le modèle est obligatoire.'; end if;
  if v_color = '' then raise exception 'La couleur est obligatoire.'; end if;
  if p_agency not in ('police', 'gendarmerie') then raise exception 'Indiquez qui a demandé la saisie : police ou gendarmerie.'; end if;
  v_key := regexp_replace(v_plate, '[^A-Z0-9]', '', 'g');
  if exists (select 1 from public.seizures where plate_key = v_key and status = 'en_cours') then
    raise exception 'Une saisie est déjà en cours pour cette plaque.';
  end if;
  insert into public.seizures (plate, plate_key, model, color, agency, created_by, created_by_name)
  values (v_plate, v_key, v_model, v_color, p_agency, v_uid, v_name) returning id into v_id;
  perform private.log_action('seizure.create', 'seizure', v_id, null,
    format('%s a enregistré une saisie %s pour %s (%s, %s)', v_name, case p_agency when 'police' then 'police' else 'gendarmerie' end, v_plate, v_model, v_color));
  perform private.notify_roles(array['forces_ordre'], 'seizure', 'Nouvelle saisie enregistrée',
    format('%s — %s (%s), demandée par la %s', v_plate, v_model, v_color, case p_agency when 'police' then 'police' else 'gendarmerie' end), '#/saisies');
  return v_id;
end $$;

create or replace function public.mark_seizure_recovered(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_police_or_staff(); v_name text := private.display_name(v_uid); v_s public.seizures;
begin
  select * into v_s from public.seizures where id = p_id for update;
  if not found then raise exception 'Saisie introuvable.'; end if;
  if v_s.status <> 'en_cours' then raise exception 'Cette saisie est déjà clôturée.'; end if;
  update public.seizures set status = 'recuperee', recovered_at = now(), recovered_by = v_uid, recovered_by_name = v_name where id = p_id;
  perform private.log_action('seizure.recover', 'seizure', p_id, null,
    format('%s a marqué la saisie de %s comme récupérée', v_name, v_s.plate));
end $$;

create or replace function public.delete_seizure(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_s public.seizures;
begin
  select * into v_s from public.seizures where id = p_id for update;
  if not found then raise exception 'Saisie introuvable.'; end if;
  delete from public.seizures where id = p_id;
  perform private.log_action('seizure.delete', 'seizure', p_id, null,
    format('%s a supprimé la saisie de %s', private.display_name(v_uid), v_s.plate));
end $$;

-- Statistiques dédiées aux saisies : volontairement séparées de get_stats().
create or replace function public.get_seizure_stats() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_today date := (now() at time zone 'Europe/Paris')::date; v_daily jsonb;
begin
  perform private.require_police_or_staff();
  select coalesce(jsonb_agg(jsonb_build_object('day', to_char(d.day, 'YYYY-MM-DD'), 'created', coalesce(c.n, 0), 'recovered', coalesce(r.n, 0)) order by d.day), '[]'::jsonb)
    into v_daily
    from (select generate_series((v_today - 29)::timestamp, v_today::timestamp, interval '1 day')::date as day) d
    left join (select (created_at at time zone 'Europe/Paris')::date as day, count(*) as n from public.seizures group by 1) c on c.day = d.day
    left join (select (recovered_at at time zone 'Europe/Paris')::date as day, count(*) as n from public.seizures where recovered_at is not null group by 1) r on r.day = d.day;
  return jsonb_build_object(
    'total', (select count(*) from public.seizures),
    'en_cours', (select count(*) from public.seizures where status = 'en_cours'),
    'recuperees', (select count(*) from public.seizures where status = 'recuperee'),
    'police', (select count(*) from public.seizures where agency = 'police'),
    'gendarmerie', (select count(*) from public.seizures where agency = 'gendarmerie'),
    'today', (select count(*) from public.seizures where (created_at at time zone 'Europe/Paris')::date = v_today),
    'daily', v_daily);
end $$;
