-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 3/8 : véhicules, claims, conversations, ventes, statistiques
--  Toutes les écritures passent par ces fonctions : les permissions sont
--  vérifiées ici, dans la base, jamais dans le navigateur.
-- =====================================================================

-- ---------------------------------------------------------------------
--  VÉHICULES
-- ---------------------------------------------------------------------
create or replace function public.create_vehicle(
  p_id uuid, p_plate text, p_model text, p_color text, p_notes text, p_photo_paths text[])
returns uuid
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_staff();
  v_set public.pricing_settings;
  v_plate text := upper(btrim(coalesce(p_plate, '')));
  v_model text := btrim(coalesce(p_model, ''));
  v_color text := btrim(coalesce(p_color, ''));
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_n integer := coalesce(array_length(p_photo_paths, 1), 0);
  v_path text; v_found integer; v_name text := private.display_name(v_uid);
begin
  if p_id is null then raise exception 'Identifiant de véhicule manquant.'; end if;
  if char_length(v_plate) < 2 then raise exception 'Le numéro de plaque est obligatoire.'; end if;
  if v_model = '' then raise exception 'Le modèle est obligatoire.'; end if;
  if v_color = '' then raise exception 'La couleur est obligatoire.'; end if;
  if v_n < 1 then raise exception 'Ajoutez au moins une photo du véhicule.'; end if;
  if v_n > 12 then raise exception 'Maximum 12 photos par véhicule.'; end if;
  foreach v_path in array p_photo_paths loop
    if v_path is null or v_path not like (p_id::text || '/%') then
      raise exception 'Chemin de photo invalide.';
    end if;
  end loop;
  select count(*) into v_found from storage.objects
   where bucket_id = 'vehicle-photos' and name = any (p_photo_paths);
  if v_found <> v_n then
    raise exception 'Certaines photos n''ont pas été envoyées correctement. Réessayez.';
  end if;

  select * into v_set from public.pricing_settings where id = 1;
  begin
    insert into public.vehicles (id, plate, model, color, notes, created_by, created_by_name, handling_fee, daily_rate)
    values (p_id, v_plate, v_model, v_color, v_notes, v_uid, v_name, v_set.handling_fee, v_set.daily_rate);
  exception when unique_violation then
    raise exception 'Un véhicule actif porte déjà la plaque %.', v_plate;
  end;
  insert into public.vehicle_photos (vehicle_id, storage_path, position, created_by)
  select p_id, t.path, t.ord - 1, v_uid from unnest(p_photo_paths) with ordinality as t(path, ord);

  perform private.log_action('vehicle.create', 'vehicle', p_id, p_id,
    format('%s a ajouté le véhicule %s (%s, %s)', v_name, v_plate, v_model, v_color));
  perform private.notify_roles(array['employe', 'gerant', 'admin'], 'vehicle', 'Nouveau véhicule arrivé',
    format('%s — %s (%s)', v_plate, v_model, v_color), '#/admin/vehicules/' || p_id, null, p_id, v_uid);
  return p_id;
end $$;

create or replace function public.update_vehicle(
  p_id uuid, p_plate text, p_model text, p_color text, p_notes text,
  p_handling_fee numeric default null, p_daily_rate numeric default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_staff();
  v_old public.vehicles;
  v_plate text := upper(btrim(coalesce(p_plate, '')));
  v_model text := btrim(coalesce(p_model, ''));
  v_color text := btrim(coalesce(p_color, ''));
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
  v_name text := private.display_name(v_uid);
  v_changes jsonb := '{}'::jsonb;
  v_fee numeric; v_rate numeric;
begin
  select * into v_old from public.vehicles where id = p_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if char_length(v_plate) < 2 then raise exception 'Le numéro de plaque est obligatoire.'; end if;
  if v_model = '' then raise exception 'Le modèle est obligatoire.'; end if;
  if v_color = '' then raise exception 'La couleur est obligatoire.'; end if;
  v_fee := v_old.handling_fee;
  v_rate := v_old.daily_rate;
  if private.is_manager() then
    if p_handling_fee is not null then
      if p_handling_fee < 0 then raise exception 'Le montant doit être positif.'; end if;
      v_fee := p_handling_fee;
    end if;
    if p_daily_rate is not null then
      if p_daily_rate < 0 then raise exception 'Le montant doit être positif.'; end if;
      v_rate := p_daily_rate;
    end if;
  end if;
  begin
    update public.vehicles
       set plate = v_plate, model = v_model, color = v_color, notes = v_notes,
           handling_fee = v_fee, daily_rate = v_rate,
           final_amount = case when v_old.final_amount is not null
                               then round(private.billing_amount(v_fee, v_rate, v_old.created_at, v_old.billing_end_at)
                                          * (100 - coalesce(v_old.discount_percent, 0)) / 100)
                               else null end,
           original_amount = case when v_old.discount_percent is not null
                                  then private.billing_amount(v_fee, v_rate, v_old.created_at, v_old.billing_end_at)
                                  else null end,
           updated_by = v_uid, updated_by_name = v_name
     where id = p_id;
  exception when unique_violation then
    raise exception 'Un autre véhicule actif porte déjà la plaque %.', v_plate;
  end;
  if v_old.plate <> upper(v_plate) then v_changes := v_changes || jsonb_build_object('plaque', jsonb_build_array(v_old.plate, v_plate)); end if;
  if v_old.model <> v_model then v_changes := v_changes || jsonb_build_object('modele', jsonb_build_array(v_old.model, v_model)); end if;
  if v_old.color <> v_color then v_changes := v_changes || jsonb_build_object('couleur', jsonb_build_array(v_old.color, v_color)); end if;
  if v_old.notes is distinct from v_notes then v_changes := v_changes || jsonb_build_object('notes', true); end if;
  if v_old.handling_fee <> v_fee then v_changes := v_changes || jsonb_build_object('frais_dossier', jsonb_build_array(v_old.handling_fee, v_fee)); end if;
  if v_old.daily_rate <> v_rate then v_changes := v_changes || jsonb_build_object('garde_jour', jsonb_build_array(v_old.daily_rate, v_rate)); end if;
  if v_changes <> '{}'::jsonb then
    perform private.log_action('vehicle.update', 'vehicle', p_id, p_id,
      format('%s a modifié le véhicule %s', v_name, v_plate), v_changes);
  end if;
end $$;

-- Renvoie les chemins des photos : le navigateur supprime ensuite les fichiers du Storage.
create or replace function public.delete_vehicle(p_id uuid) returns text[]
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_staff();
  v_v public.vehicles; v_set public.pricing_settings; v_paths text[];
begin
  select * into v_v from public.vehicles where id = p_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if not private.is_manager() then
    select * into v_set from public.pricing_settings where id = 1;
    if v_v.created_by is distinct from v_uid
       or v_v.created_at < now() - make_interval(mins => v_set.employee_delete_minutes)
       or exists (select 1 from public.conversations where vehicle_id = p_id) then
      raise exception 'Vous ne pouvez supprimer que vos propres fiches créées il y a moins de % minutes et sans demande client. Demandez à un gérant.', v_set.employee_delete_minutes
        using errcode = '42501';
    end if;
  end if;
  select coalesce(array_agg(storage_path), '{}') into v_paths from public.vehicle_photos where vehicle_id = p_id;
  perform private.log_action('vehicle.delete', 'vehicle', p_id, p_id,
    format('%s a supprimé le véhicule %s (%s, %s)', private.display_name(v_uid), v_v.plate, v_v.model, v_v.color),
    jsonb_build_object('plate', v_v.plate, 'model', v_v.model, 'color', v_v.color, 'status', v_v.status));
  delete from public.vehicles where id = p_id;
  return v_paths;
end $$;

create or replace function public.add_vehicle_photos(p_vehicle_id uuid, p_paths text[]) returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_staff();
  v_n integer := coalesce(array_length(p_paths, 1), 0);
  v_path text; v_found integer; v_pos integer; v_plate text; v_count integer;
begin
  select plate into v_plate from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if v_n < 1 then raise exception 'Aucune photo à ajouter.'; end if;
  select count(*) into v_count from public.vehicle_photos where vehicle_id = p_vehicle_id;
  if v_count + v_n > 12 then raise exception 'Maximum 12 photos par véhicule.'; end if;
  foreach v_path in array p_paths loop
    if v_path is null or v_path not like (p_vehicle_id::text || '/%') then
      raise exception 'Chemin de photo invalide.';
    end if;
  end loop;
  select count(*) into v_found from storage.objects where bucket_id = 'vehicle-photos' and name = any (p_paths);
  if v_found <> v_n then raise exception 'Certaines photos n''ont pas été envoyées correctement.'; end if;
  select coalesce(max(position), -1) + 1 into v_pos from public.vehicle_photos where vehicle_id = p_vehicle_id;
  insert into public.vehicle_photos (vehicle_id, storage_path, position, created_by)
  select p_vehicle_id, t.path, v_pos + t.ord - 1, v_uid from unnest(p_paths) with ordinality as t(path, ord);
  perform private.log_action('vehicle.photos', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a ajouté %s photo(s) au véhicule %s', private.display_name(v_uid), v_n, v_plate));
end $$;

create or replace function public.remove_vehicle_photo(p_photo_id uuid) returns text
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_staff(); v_p public.vehicle_photos; v_plate text;
begin
  select * into v_p from public.vehicle_photos where id = p_photo_id;
  if not found then raise exception 'Photo introuvable.'; end if;
  perform 1 from public.vehicles where id = v_p.vehicle_id for update;
  if (select count(*) from public.vehicle_photos where vehicle_id = v_p.vehicle_id) <= 1 then
    raise exception 'Un véhicule doit conserver au moins une photo.';
  end if;
  delete from public.vehicle_photos where id = p_photo_id;
  select plate into v_plate from public.vehicles where id = v_p.vehicle_id;
  perform private.log_action('vehicle.photos', 'vehicle', v_p.vehicle_id, v_p.vehicle_id,
    format('%s a retiré une photo du véhicule %s', private.display_name(v_uid), v_plate));
  return v_p.storage_path;
end $$;

create or replace function public.set_cover_photo(p_photo_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_p public.vehicle_photos; v_min integer;
begin
  perform private.require_staff();
  select * into v_p from public.vehicle_photos where id = p_photo_id;
  if not found then raise exception 'Photo introuvable.'; end if;
  select min(position) into v_min from public.vehicle_photos where vehicle_id = v_p.vehicle_id;
  update public.vehicle_photos set position = v_min - 1 where id = p_photo_id;
end $$;

-- Véhicule récupéré par son propriétaire (avec ou sans demande sur le site).
-- Si un code promo est appliqué à la conversation de la demande gagnante, le montant réglé est réduit.
create or replace function public.mark_vehicle_recovered(p_vehicle_id uuid, p_claim_id uuid default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_staff();
  v_name text := private.display_name(v_uid);
  v_v public.vehicles; v_claim public.claims; v_wc public.conversations;
  v_amount numeric; v_charge numeric; v_pct integer; v_code text; v_promo text; r record;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if v_v.status not in ('en_fourriere', 'reclamee', 'attente_vente') then
    raise exception 'Ce véhicule ne peut plus être marqué comme récupéré.';
  end if;
  if v_v.status = 'attente_vente' and not private.is_manager() then
    raise exception 'Seul un gérant peut clôturer un véhicule en attente de mise en vente.' using errcode = '42501';
  end if;
  if p_claim_id is not null then
    select * into v_claim from public.claims where id = p_claim_id and vehicle_id = p_vehicle_id;
    if not found or v_claim.status <> 'ouverte' then
      raise exception 'Cette demande n''est plus ouverte.';
    end if;
    select * into v_wc from public.conversations where claim_id = p_claim_id;
    if found and v_wc.discount_redemption_id is not null
       and exists (select 1 from public.discount_redemptions where id = v_wc.discount_redemption_id and status = 'appliquee') then
      v_pct := v_wc.discount_percent; v_code := v_wc.discount_code;
    end if;
  end if;
  v_amount := coalesce(v_v.final_amount,
                private.billing_amount(v_v.handling_fee, v_v.daily_rate, v_v.created_at, null));
  v_charge := case when v_pct is null then v_amount else round(v_amount * (100 - v_pct) / 100) end;
  v_promo := case when v_pct is null then '' else format(' (code %s, −%s %% au lieu de %s)', v_code, v_pct, private.fmt_money(v_amount)) end;

  update public.vehicles
     set status = 'recuperee', status_changed_at = now(), recovered_at = now(),
         recovered_by = v_claim.client_id, recovered_by_name = v_claim.client_name,
         billing_end_at = coalesce(billing_end_at, now()), final_amount = v_charge,
         original_amount = case when v_pct is null then null else v_amount end,
         discount_code = v_code, discount_percent = v_pct,
         planned_price = null, planned_description = null,
         updated_by = v_uid, updated_by_name = v_name
   where id = p_vehicle_id;
  if p_claim_id is not null then
    update public.claims
       set status = 'validee', closed_at = now(), processed_by = v_uid,
           processed_by_name = v_name, amount_due = v_charge
     where id = p_claim_id;
    if v_pct is not null then
      update public.discount_redemptions
         set status = 'utilisee', used_at = now(), original_amount = v_amount, final_amount = v_charge
       where id = v_wc.discount_redemption_id;
    end if;
  end if;

  for r in select c.id as conv_id, c.claim_id, c.client_id from public.conversations c
            where c.vehicle_id = p_vehicle_id and c.type = 'claim' and c.status = 'ouverte' loop
    if p_claim_id is not null and r.claim_id is not distinct from p_claim_id then
      perform private.post_system_message(r.conv_id,
        format('Véhicule récupéré. Montant réglé : %s%s. Merci de votre confiance !', private.fmt_money(v_charge), v_promo));
    else
      perform private.post_system_message(r.conv_id, 'Ce véhicule a été récupéré. La conversation est fermée.');
      update public.claims set status = 'annulee', closed_at = now() where id = r.claim_id and status = 'ouverte';
      perform private.release_redemption(r.conv_id);
    end if;
    update public.conversations
       set status = 'fermee', closed_at = now(), closed_by = v_uid, closed_by_name = v_name
     where id = r.conv_id;
    perform private.notify_user(r.client_id, 'claim', 'Demande clôturée',
      format('Le véhicule %s a été marqué comme récupéré.', v_v.plate), '#/messages/' || r.conv_id, r.conv_id, p_vehicle_id);
  end loop;

  perform private.log_action('vehicle.recovered', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a marqué le véhicule %s comme récupéré (%s%s)%s', v_name, v_v.plate, private.fmt_money(v_charge), v_promo,
           case when v_claim.client_name is not null then ' par ' || v_claim.client_name else '' end),
    jsonb_build_object('amount', v_charge, 'original_amount', v_amount, 'discount_percent', v_pct));
end $$;

create or replace function public.archive_vehicle(p_vehicle_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_v public.vehicles;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if v_v.status not in ('recuperee', 'vendue') then
    raise exception 'Seuls les véhicules récupérés ou vendus peuvent être archivés.';
  end if;
  update public.vehicles
     set status_before_archive = status, status = 'archivee', status_changed_at = now(),
         updated_by = v_uid, updated_by_name = private.display_name(v_uid)
   where id = p_vehicle_id;
  perform private.log_action('vehicle.archive', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a archivé le véhicule %s', private.display_name(v_uid), v_v.plate));
end $$;

create or replace function public.unarchive_vehicle(p_vehicle_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_v public.vehicles;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found or v_v.status <> 'archivee' then raise exception 'Ce véhicule n''est pas archivé.'; end if;
  update public.vehicles
     set status = coalesce(status_before_archive, 'recuperee'), status_before_archive = null,
         status_changed_at = now(), updated_by = v_uid, updated_by_name = private.display_name(v_uid)
   where id = p_vehicle_id;
  perform private.log_action('vehicle.unarchive', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a désarchivé le véhicule %s', private.display_name(v_uid), v_v.plate));
end $$;

-- ---------------------------------------------------------------------
--  MISE EN VENTE
-- ---------------------------------------------------------------------
drop function if exists public.list_vehicle_for_sale(uuid, numeric, text, text[]);
create or replace function public.list_vehicle_for_sale(
  p_vehicle_id uuid, p_price numeric, p_description text, p_new_photo_paths text[] default '{}', p_promo_percent integer default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_manager();
  v_name text := private.display_name(v_uid);
  v_v public.vehicles; v_desc text := btrim(coalesce(p_description, ''));
  v_n integer := coalesce(array_length(p_new_photo_paths, 1), 0);
  v_path text; v_found integer; v_pos integer;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found then raise exception 'Véhicule introuvable.'; end if;
  if v_v.status <> 'attente_vente' then
    raise exception 'Ce véhicule n''est pas en attente de mise en vente.';
  end if;
  if p_price is null or p_price <= 0 or p_price > 1000000000 then raise exception 'Indiquez un prix de vente valide.'; end if;
  if char_length(v_desc) < 3 then raise exception 'Ajoutez une description.'; end if;
  if char_length(v_desc) > 2000 then raise exception 'Description trop longue (2000 caractères maximum).'; end if;
  if p_promo_percent is not null and p_promo_percent not between 1 and 99 then
    raise exception 'La promotion affichée doit être comprise entre 1 et 99 %%.';
  end if;
  if v_n > 0 then
    if (select count(*) from public.vehicle_photos where vehicle_id = p_vehicle_id) + v_n > 12 then
      raise exception 'Maximum 12 photos par véhicule.';
    end if;
    foreach v_path in array p_new_photo_paths loop
      if v_path is null or v_path not like (p_vehicle_id::text || '/%') then raise exception 'Chemin de photo invalide.'; end if;
    end loop;
    select count(*) into v_found from storage.objects where bucket_id = 'vehicle-photos' and name = any (p_new_photo_paths);
    if v_found <> v_n then raise exception 'Certaines photos n''ont pas été envoyées correctement.'; end if;
    select coalesce(max(position), -1) + 1 into v_pos from public.vehicle_photos where vehicle_id = p_vehicle_id;
    insert into public.vehicle_photos (vehicle_id, storage_path, position, created_by)
    select p_vehicle_id, t.path, v_pos + t.ord - 1, v_uid from unnest(p_new_photo_paths) with ordinality as t(path, ord);
  end if;
  insert into public.vehicle_sales (vehicle_id, price, description, promo_percent, listed_by, listed_by_name)
  values (p_vehicle_id, p_price, v_desc, p_promo_percent, v_uid, v_name);
  update public.vehicles set status = 'a_vendre', status_changed_at = now(), planned_price = null, planned_description = null,
         updated_by = v_uid, updated_by_name = v_name where id = p_vehicle_id;
  perform private.log_action('sale.list', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a mis en vente le véhicule %s (%s, %s) à %s%s', v_name, v_v.plate, v_v.model, v_v.color, private.fmt_money(p_price),
           case when p_promo_percent is null then '' else format(' (promotion affichée −%s %%)', p_promo_percent) end),
    jsonb_build_object('price', p_price, 'promo_percent', p_promo_percent));
end $$;

drop function if exists public.update_sale(uuid, numeric, text);
create or replace function public.update_sale(p_vehicle_id uuid, p_price numeric, p_description text, p_promo_percent integer default null) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_desc text := btrim(coalesce(p_description, '')); v_s public.vehicle_sales; v_plate text;
begin
  select * into v_s from public.vehicle_sales where vehicle_id = p_vehicle_id and status = 'a_vendre' for update;
  if not found then raise exception 'Ce véhicule n''est pas à vendre.'; end if;
  if p_price is null or p_price <= 0 or p_price > 1000000000 then raise exception 'Indiquez un prix de vente valide.'; end if;
  if char_length(v_desc) < 3 then raise exception 'Ajoutez une description.'; end if;
  if p_promo_percent is not null and p_promo_percent not between 1 and 99 then
    raise exception 'La promotion affichée doit être comprise entre 1 et 99 %%.';
  end if;
  update public.vehicle_sales set price = p_price, description = v_desc, promo_percent = p_promo_percent where id = v_s.id;
  select plate into v_plate from public.vehicles where id = p_vehicle_id;
  perform private.log_action('sale.update', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a modifié l''annonce du véhicule %s (%s)%s', private.display_name(v_uid), v_plate, private.fmt_money(p_price),
           case when p_promo_percent is null then '' else format(' (promotion affichée −%s %%)', p_promo_percent) end),
    jsonb_build_object('old_price', v_s.price, 'new_price', p_price, 'promo_percent', p_promo_percent));
end $$;

create or replace function public.withdraw_sale(p_vehicle_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_v public.vehicles; r record;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found or v_v.status <> 'a_vendre' then raise exception 'Ce véhicule n''est pas à vendre.'; end if;
  update public.vehicle_sales set status = 'retiree', withdrawn_at = now()
   where vehicle_id = p_vehicle_id and status = 'a_vendre';
  update public.vehicles set status = 'attente_vente', status_changed_at = now(),
         updated_by = v_uid, updated_by_name = private.display_name(v_uid) where id = p_vehicle_id;
  for r in select id from public.conversations where vehicle_id = p_vehicle_id and type = 'vente' and status = 'ouverte' loop
    perform private.close_conv(r.id, v_uid, 'Ce véhicule n''est plus à vendre. La conversation est fermée.');
  end loop;
  perform private.log_action('sale.withdraw', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a retiré le véhicule %s de la vente', private.display_name(v_uid), v_v.plate));
end $$;

drop function if exists public.mark_vehicle_sold(uuid, uuid, numeric, text);
create or replace function public.mark_vehicle_sold(
  p_vehicle_id uuid, p_conversation_id uuid default null,
  p_sold_price numeric default null, p_buyer_name text default null, p_option_ids uuid[] default '{}')
returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_manager();
  v_name text := private.display_name(v_uid);
  v_v public.vehicles; v_s public.vehicle_sales; v_c public.conversations;
  v_buyer_id uuid; v_buyer text := nullif(btrim(coalesce(p_buyer_name, '')), ''); v_price numeric; v_base numeric;
  v_pct integer; v_code text; v_red uuid; v_items jsonb; v_opts_total numeric; v_opt_txt text; v_note text := ''; r record;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found or v_v.status <> 'a_vendre' then raise exception 'Ce véhicule n''est pas à vendre.'; end if;
  select * into v_s from public.vehicle_sales where vehicle_id = p_vehicle_id and status = 'a_vendre' for update;
  if p_conversation_id is not null then
    select * into v_c from public.conversations
     where id = p_conversation_id and vehicle_id = p_vehicle_id and type = 'vente';
    if not found then raise exception 'Conversation d''achat introuvable pour ce véhicule.'; end if;
    v_buyer_id := v_c.client_id;
    v_buyer := v_c.client_name;
    if v_c.discount_redemption_id is not null
       and exists (select 1 from public.discount_redemptions where id = v_c.discount_redemption_id and status = 'appliquee') then
      v_pct := v_c.discount_percent; v_code := v_c.discount_code; v_red := v_c.discount_redemption_id;
    end if;
  elsif v_buyer is null then
    raise exception 'Indiquez l''acheteur.';
  end if;
  -- prix par défaut = prix de l'annonce (déjà réduit d'une éventuelle promotion affichée), réduit du code promo
  -- de l'acheteur, plus les options choisies ; un gérant peut toujours imposer un autre montant final.
  v_base := case when v_s.promo_percent is null then v_s.price else round(v_s.price * (100 - v_s.promo_percent) / 100) end;
  select items, total into v_items, v_opts_total from private.options_snapshot(p_option_ids, false);
  v_price := coalesce(p_sold_price, (case when v_pct is null then v_base else round(v_base * (100 - v_pct) / 100) end) + v_opts_total);
  if v_price < 0 or (v_price = 0 and coalesce(v_pct, 0) < 100 and v_opts_total = 0) then raise exception 'Prix de vente invalide.'; end if;
  update public.vehicle_sales
     set status = 'vendue', sold_at = now(), sold_price = v_price, buyer_id = v_buyer_id,
         buyer_name = v_buyer, sold_by = v_uid, sold_by_name = v_name,
         discount_code = v_code, discount_percent = v_pct, options = v_items, options_total = v_opts_total
   where id = v_s.id;
  if v_red is not null then
    update public.discount_redemptions
       set status = 'utilisee', used_at = now(), original_amount = v_base, final_amount = v_price - v_opts_total
     where id = v_red;
  end if;
  update public.vehicles set status = 'vendue', status_changed_at = now(),
         updated_by = v_uid, updated_by_name = v_name where id = p_vehicle_id;
  select string_agg(format('%s (%s)', o ->> 'label', private.fmt_money((o ->> 'price')::numeric)), ', ') into v_opt_txt
    from jsonb_array_elements(v_items) o;
  if v_opt_txt is not null then v_note := format(' + options : %s', v_opt_txt); end if;
  for r in select id, client_id from public.conversations
            where vehicle_id = p_vehicle_id and type = 'vente' and status = 'ouverte' loop
    if r.id = p_conversation_id then
      perform private.close_conv(r.id, v_uid, format('Véhicule vendu pour %s%s%s. Merci pour votre achat !', private.fmt_money(v_price),
        case when v_pct is null then '' else format(' (code %s, −%s %% sur %s)', v_code, v_pct, private.fmt_money(v_base)) end, v_note));
    else
      perform private.close_conv(r.id, v_uid, 'Ce véhicule a été vendu. La conversation est fermée.');
    end if;
    perform private.notify_user(r.client_id, 'sale', 'Vente clôturée',
      format('Le véhicule %s a été vendu.', v_v.model), '#/messages/' || r.id, r.id, p_vehicle_id);
  end loop;
  perform private.log_action('sale.sold', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('%s a vendu le véhicule %s (%s) à %s pour %s%s%s', v_name, v_v.plate, v_v.model, v_buyer, private.fmt_money(v_price),
           case when v_pct is null then '' else format(' (code %s, −%s %%)', v_code, v_pct) end, v_note),
    jsonb_build_object('price', v_price, 'buyer', v_buyer, 'original_price', v_base, 'discount_percent', v_pct, 'options_total', v_opts_total));
end $$;

-- ---------------------------------------------------------------------
--  CONVERSATIONS
-- ---------------------------------------------------------------------
-- Fermeture interne : la conversation est conservée, jamais supprimée.
create or replace function private.close_conv(p_conv uuid, p_by uuid, p_message text) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_c public.conversations; v_v public.vehicles;
begin
  select * into v_c from public.conversations where id = p_conv for update;
  if not found or v_c.status = 'fermee' then return; end if;
  if p_message is not null then perform private.post_system_message(p_conv, p_message); end if;
  update public.conversations
     set status = 'fermee', closed_at = now(), closed_by = p_by, closed_by_name = private.display_name(p_by)
   where id = p_conv;
  perform private.release_redemption(p_conv);
  if v_c.type = 'claim' then
    update public.claims set status = 'annulee', closed_at = now() where id = v_c.claim_id and status = 'ouverte';
    select * into v_v from public.vehicles where id = v_c.vehicle_id for update;
    if found and v_v.status = 'reclamee'
       and not exists (select 1 from public.conversations c
                        where c.vehicle_id = v_v.id and c.type = 'claim' and c.status = 'ouverte') then
      -- Plus aucune demande active : le véhicule redevient visible en fourrière
      update public.vehicles set status = 'en_fourriere', status_changed_at = now() where id = v_v.id;
    end if;
  end if;
end $$;

create or replace function public.claim_vehicle(p_vehicle_id uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_login();
  v_p public.profiles; v_v public.vehicles; v_claim uuid; v_conv uuid; v_name text;
begin
  select * into v_p from public.profiles where id = v_uid;
  if not found then raise exception 'Profil introuvable.' using errcode = '42501'; end if;
  v_name := v_p.prenom || ' ' || v_p.nom;
  -- Verrou sur le véhicule : plusieurs clients peuvent réclamer en même temps, chacun sa conversation.
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found or v_v.status not in ('en_fourriere', 'reclamee') then
    raise exception 'Ce véhicule n''est plus disponible en fourrière.';
  end if;
  select id into v_conv from public.conversations
   where vehicle_id = p_vehicle_id and client_id = v_uid and type = 'claim' and status = 'ouverte';
  if found then return v_conv; end if;

  insert into public.claims (vehicle_id, client_id, client_name) values (p_vehicle_id, v_uid, v_name)
  returning id into v_claim;
  insert into public.conversations (type, vehicle_id, claim_id, client_id, client_name)
  values ('claim', p_vehicle_id, v_claim, v_uid, v_name) returning id into v_conv;
  insert into public.conversation_participants (conversation_id, user_id, participant_role, last_read_at)
  values (v_conv, v_uid, 'client', now());
  perform private.post_system_message(v_conv,
    format('Demande de récupération créée pour le véhicule %s (%s, %s). Un membre de la fourrière vous répond ici.',
           v_v.plate, v_v.model, v_v.color));
  if v_v.status = 'en_fourriere' then
    update public.vehicles set status = 'reclamee', status_changed_at = now() where id = p_vehicle_id;
  end if;
  perform private.log_action('claim.create', 'claim', v_claim, p_vehicle_id,
    format('%s a réclamé le véhicule %s (%s)', v_name, v_v.plate, v_v.model));
  perform private.notify_roles(array['employe', 'gerant', 'admin'], 'claim', 'Nouvelle demande de récupération',
    format('Nouvelle demande pour le véhicule %s', v_v.plate), '#/messages/' || v_conv, v_conv, p_vehicle_id);
  return v_conv;
end $$;

create or replace function public.express_interest(p_vehicle_id uuid) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_login();
  v_p public.profiles; v_v public.vehicles; v_s public.vehicle_sales; v_conv uuid; v_name text;
begin
  select * into v_p from public.profiles where id = v_uid;
  if not found then raise exception 'Profil introuvable.' using errcode = '42501'; end if;
  v_name := v_p.prenom || ' ' || v_p.nom;
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found or v_v.status <> 'a_vendre' then raise exception 'Ce véhicule n''est plus à vendre.'; end if;
  select * into v_s from public.vehicle_sales where vehicle_id = p_vehicle_id and status = 'a_vendre';
  select id into v_conv from public.conversations
   where vehicle_id = p_vehicle_id and client_id = v_uid and type = 'vente' and status = 'ouverte';
  if found then return v_conv; end if;
  insert into public.conversations (type, vehicle_id, sale_id, client_id, client_name)
  values ('vente', p_vehicle_id, v_s.id, v_uid, v_name) returning id into v_conv;
  insert into public.conversation_participants (conversation_id, user_id, participant_role, last_read_at)
  values (v_conv, v_uid, 'client', now());
  perform private.post_system_message(v_conv,
    format('Vous êtes intéressé par le véhicule %s (%s) à %s. Un membre de la fourrière vous répond ici.',
           v_v.model, v_v.color, private.fmt_money(v_s.price)));
  perform private.log_action('interest.create', 'conversation', v_conv, p_vehicle_id,
    format('%s est intéressé par le véhicule %s (%s) à vendre', v_name, v_v.model, v_v.color));
  perform private.notify_roles(array['employe', 'gerant', 'admin'], 'interest', 'Nouvel intérêt pour un véhicule à vendre',
    format('%s est intéressé par %s (%s)', v_name, v_v.model, v_v.color), '#/messages/' || v_conv, v_conv, p_vehicle_id);
  return v_conv;
end $$;

create or replace function public.close_conversation(p_conversation_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_login(); v_c public.conversations; v_name text := private.display_name(v_uid); v_plate text;
begin
  select * into v_c from public.conversations where id = p_conversation_id;
  if not found then raise exception 'Conversation introuvable.'; end if;
  if v_c.client_id is distinct from v_uid and not private.is_staff() then
    raise exception 'Vous ne pouvez pas fermer cette conversation.' using errcode = '42501';
  end if;
  if v_c.status = 'fermee' then return; end if;
  perform private.close_conv(p_conversation_id, v_uid, format('Conversation fermée par %s.', v_name));
  select plate into v_plate from public.vehicles where id = v_c.vehicle_id;
  perform private.log_action('conversation.close', 'conversation', p_conversation_id, v_c.vehicle_id,
    format('%s a fermé la conversation de %s (%s)', v_name, v_c.client_name, v_plate));
end $$;

create or replace function public.delete_conversation(p_conversation_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_c public.conversations; v_plate text;
begin
  select * into v_c from public.conversations where id = p_conversation_id;
  if not found then raise exception 'Conversation introuvable.'; end if;
  perform private.close_conv(p_conversation_id, v_uid, null);  -- remet le véhicule en fourrière si besoin
  select plate into v_plate from public.vehicles where id = v_c.vehicle_id;
  perform private.log_action('conversation.delete', 'conversation', p_conversation_id, v_c.vehicle_id,
    format('%s a supprimé définitivement la conversation de %s (%s)', private.display_name(v_uid), v_c.client_name, v_plate));
  delete from public.conversations where id = p_conversation_id;
end $$;

create or replace function public.mark_conversation_read(p_conversation_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_login(); v_c public.conversations;
begin
  select * into v_c from public.conversations where id = p_conversation_id;
  if not found then return; end if;
  if v_c.client_id is distinct from v_uid and not private.is_staff() then return; end if;
  insert into public.conversation_participants (conversation_id, user_id, participant_role, last_read_at)
  values (p_conversation_id, v_uid, case when v_uid = v_c.client_id then 'client' else 'staff' end, now())
  on conflict (conversation_id, user_id) do update set last_read_at = now();
  update public.notifications set read_at = now()
   where user_id = v_uid and conversation_id = p_conversation_id and read_at is null;
end $$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_login();
begin
  update public.notifications set read_at = now()
   where user_id = v_uid and read_at is null and (p_ids is null or id = any (p_ids));
end $$;

create or replace function public.get_unread_summary() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); v_staff boolean; v_conv jsonb; v_total integer; v_notif integer;
begin
  if v_uid is null then
    return jsonb_build_object('conversations', '{}'::jsonb, 'messages', 0, 'notifications', 0);
  end if;
  v_staff := private.is_staff();
  select coalesce(jsonb_object_agg(t.cid::text, t.n), '{}'::jsonb), coalesce(sum(t.n), 0)
    into v_conv, v_total
    from (
      select c.id as cid, count(*) as n
        from public.conversations c
        join public.messages m on m.conversation_id = c.id and m.kind = 'text' and m.sender_id is distinct from v_uid
        left join public.conversation_participants cp on cp.conversation_id = c.id and cp.user_id = v_uid
       where c.status = 'ouverte' and (c.client_id = v_uid or v_staff)
         and m.created_at > coalesce(cp.last_read_at, '-infinity'::timestamptz)
       group by c.id
    ) t;
  select count(*) into v_notif from public.notifications where user_id = v_uid and read_at is null;
  return jsonb_build_object('conversations', v_conv, 'messages', v_total, 'notifications', v_notif);
end $$;

-- ---------------------------------------------------------------------
--  TARIFS
-- ---------------------------------------------------------------------
create or replace function public.update_pricing(
  p_handling_fee numeric, p_daily_rate numeric, p_auto_sale_days integer,
  p_employee_delete_minutes integer, p_apply_to_current boolean default false)
returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_old public.pricing_settings; v_name text := private.display_name(v_uid);
begin
  if p_handling_fee is null or p_handling_fee < 0 or p_handling_fee > 100000000 then raise exception 'Frais de dossier invalides.'; end if;
  if p_daily_rate is null or p_daily_rate < 0 or p_daily_rate > 100000000 then raise exception 'Prix de garde invalide.'; end if;
  if p_auto_sale_days is null or p_auto_sale_days not between 1 and 365 then raise exception 'Le délai avant mise en vente doit être compris entre 1 et 365 jours.'; end if;
  if p_employee_delete_minutes is null or p_employee_delete_minutes not between 0 and 1440 then raise exception 'La fenêtre de suppression doit être comprise entre 0 et 1440 minutes.'; end if;
  select * into v_old from public.pricing_settings where id = 1 for update;
  update public.pricing_settings
     set handling_fee = p_handling_fee, daily_rate = p_daily_rate, auto_sale_days = p_auto_sale_days,
         employee_delete_minutes = p_employee_delete_minutes, updated_at = now(),
         updated_by = v_uid, updated_by_name = v_name
   where id = 1;
  if p_apply_to_current then
    update public.vehicles set handling_fee = p_handling_fee, daily_rate = p_daily_rate
     where status in ('en_fourriere', 'reclamee');
  end if;
  perform private.log_action('pricing.update', 'pricing', null, null,
    format('%s a modifié les tarifs : dossier %s, garde %s / jour, mise en vente après %s jours',
           v_name, private.fmt_money(p_handling_fee), private.fmt_money(p_daily_rate), p_auto_sale_days),
    jsonb_build_object('old', jsonb_build_object('fee', v_old.handling_fee, 'rate', v_old.daily_rate, 'days', v_old.auto_sale_days),
                       'new', jsonb_build_object('fee', p_handling_fee, 'rate', p_daily_rate, 'days', p_auto_sale_days),
                       'applied_to_current', p_apply_to_current));
end $$;

-- ---------------------------------------------------------------------
--  PASSAGE AUTOMATIQUE EN "ATTENTE DE MISE EN VENTE"
--  Appelée par pg_cron (recommandé) et opportunément par le site.
-- ---------------------------------------------------------------------
create or replace function public.process_auto_sale() returns integer
language plpgsql security definer set search_path = public, private as $$
declare v_s public.pricing_settings; v_moved integer := 0; r record; v_end timestamptz;
begin
  select * into v_s from public.pricing_settings where id = 1 for update;
  if v_s.last_auto_check_at is not null and v_s.last_auto_check_at > now() - interval '20 seconds' then
    return 0;
  end if;
  update public.pricing_settings set last_auto_check_at = now() where id = 1;

  for r in
    select v.* from public.vehicles v
     where v.status = 'en_fourriere'
       and v.created_at <= now() - make_interval(days => v_s.auto_sale_days)
       and not exists (select 1 from public.conversations c
                        where c.vehicle_id = v.id and c.type = 'claim' and c.status = 'ouverte')
     for update
  loop
    v_end := r.created_at + make_interval(days => v_s.auto_sale_days);
    if r.planned_price is not null and r.planned_description is not null then
      -- Un tarif avait été préparé à l'avance : mise en vente immédiate, sans passer par l'attente manuelle.
      update public.vehicles
         set status = 'a_vendre', status_changed_at = now(), auto_flagged_at = now(),
             billing_end_at = v_end, final_amount = private.billing_amount(r.handling_fee, r.daily_rate, r.created_at, v_end),
             planned_price = null, planned_description = null,
             updated_by_name = 'Automatique (tarif préparé)'
       where id = r.id;
      insert into public.vehicle_sales (vehicle_id, price, description, listed_by, listed_by_name)
      values (r.id, r.planned_price, r.planned_description, null, 'Mise en vente automatique');
      perform private.log_action('sale.list', 'vehicle', r.id, r.id,
        format('Mise en vente automatique de %s (%s, %s) à %s, avec le tarif préparé à l''avance',
               r.plate, r.model, r.color, private.fmt_money(r.planned_price)),
        jsonb_build_object('price', r.planned_price, 'planned', true));
      perform private.notify_roles(array['gerant', 'admin'], 'auto_sale',
        'Véhicule mis en vente automatiquement', format('%s (%s) est en vente, avec le prix que vous aviez préparé.', r.plate, r.model),
        '#/admin/ventes', null, r.id);
    else
      update public.vehicles
         set status = 'attente_vente', status_changed_at = now(), auto_flagged_at = now(),
             billing_end_at = v_end,
             final_amount = private.billing_amount(r.handling_fee, r.daily_rate, r.created_at, v_end)
       where id = r.id;
      perform private.log_action('vehicle.auto_sale', 'vehicle', r.id, r.id,
        format('Le véhicule %s (%s, %s) a atteint %s jours en fourrière : il est en attente de mise en vente',
               r.plate, r.model, r.color, v_s.auto_sale_days),
        jsonb_build_object('old_amount', private.billing_amount(r.handling_fee, r.daily_rate, r.created_at, v_end)));
      perform private.notify_roles(array['gerant', 'admin'], 'auto_sale',
        format('Un véhicule est arrivé à %s jours', v_s.auto_sale_days),
        format('%s (%s) nécessite une mise en vente.', r.plate, r.model), '#/admin/ventes', null, r.id);
    end if;
    v_moved := v_moved + 1;
  end loop;

  begin  -- envoi des messages Discord en attente (ne bloque jamais le reste)
    perform private.discord_worker(4);
  exception when others then null;
  end;
  return v_moved;
end $$;

-- ---------------------------------------------------------------------
--  DONNÉES PUBLIQUES (aucune donnée sensible : pas d'auteur, pas de notes)
-- ---------------------------------------------------------------------
create or replace function public.public_impound_vehicles()
returns table (id uuid, plate text, model text, color text, created_at timestamptz,
               days_in_impound integer, handling_fee numeric, daily_rate numeric,
               total_amount numeric, photos jsonb)
language sql stable security definer set search_path = public, private as $$
  with s as (select auto_sale_days from public.pricing_settings where id = 1)
  select v.id, v.plate, v.model, v.color, v.created_at,
         private.billing_days(v.created_at, v.billing_end_at),
         v.handling_fee, v.daily_rate,
         private.billing_amount(v.handling_fee, v.daily_rate, v.created_at, v.billing_end_at),
         coalesce((select jsonb_agg(p.storage_path order by p.position, p.created_at)
                     from public.vehicle_photos p where p.vehicle_id = v.id), '[]'::jsonb)
    from public.vehicles v, s
   where v.status = 'en_fourriere'
     -- un véhicule non réclamé qui a dépassé le délai n'est plus visible, même avant le passage du traitement automatique
     and not (v.created_at <= now() - make_interval(days => s.auto_sale_days)
              and not exists (select 1 from public.conversations c
                               where c.vehicle_id = v.id and c.type = 'claim' and c.status = 'ouverte'))
   order by v.created_at desc
   limit 500;
$$;

drop function if exists public.public_sale_vehicles();
create or replace function public.public_sale_vehicles()
returns table (id uuid, model text, color text, description text, price numeric, promo_percent integer,
               effective_price numeric, listed_at timestamptz, arrived_at timestamptz, days_in_impound integer, photos jsonb)
language sql stable security definer set search_path = public, private as $$
  select v.id, v.model, v.color, s.description, s.price, s.promo_percent,
         case when s.promo_percent is null then s.price else round(s.price * (100 - s.promo_percent) / 100) end,
         s.listed_at, v.created_at, private.billing_days(v.created_at, v.billing_end_at),
         coalesce((select jsonb_agg(p.storage_path order by p.position, p.created_at)
                     from public.vehicle_photos p where p.vehicle_id = v.id), '[]'::jsonb)
    from public.vehicles v
    join public.vehicle_sales s on s.vehicle_id = v.id and s.status = 'a_vendre'
   where v.status = 'a_vendre'
   order by s.listed_at desc
   limit 500;
$$;

-- ---------------------------------------------------------------------
--  STATISTIQUES (données réelles ; les véhicules archivés restent comptés)
-- ---------------------------------------------------------------------
create or replace function public.get_stats() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare
  v_mgr boolean; v_today date := (now() at time zone 'Europe/Paris')::date;
  v_totals jsonb; v_status jsonb; v_daily jsonb; v_money jsonb := null; v_staff jsonb := null;
begin
  perform private.require_staff();
  v_mgr := private.is_manager();

  v_totals := jsonb_build_object(
    'entered', (select count(*) from public.vehicles),
    'in_impound', (select count(*) from public.vehicles where status = 'en_fourriere'),
    'claimed_now', (select count(*) from public.vehicles where status = 'reclamee'),
    'claimed_vehicles', (select count(distinct vehicle_id) from public.claims),
    'claims', (select count(*) from public.claims),
    'recovered', (select count(*) from public.vehicles where recovered_at is not null),
    'awaiting_sale', (select count(*) from public.vehicles where status = 'attente_vente'),
    'for_sale', (select count(*) from public.vehicles where status = 'a_vendre'),
    'sold', (select count(*) from public.vehicle_sales where status = 'vendue'),
    'auto_flagged', (select count(*) from public.vehicles where auto_flagged_at is not null),
    'archived', (select count(*) from public.vehicles where status = 'archivee'),
    'conversations', (select count(*) from public.conversations),
    'open_conversations', (select count(*) from public.conversations where status = 'ouverte'),
    'interests', (select count(*) from public.conversations where type = 'vente'),
    'discounts_used', (select count(*) from public.discount_redemptions where status = 'utilisee'));

  select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) into v_status
    from (select status, count(*) as n from public.vehicles group by status) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'day', to_char(d.day, 'YYYY-MM-DD'), 'entered', coalesce(e.n, 0), 'recovered', coalesce(r.n, 0),
           'sold', coalesce(s.n, 0), 'claims', coalesce(c.n, 0)) order by d.day), '[]'::jsonb)
    into v_daily
    from (select generate_series((v_today - 29)::timestamp, v_today::timestamp, interval '1 day')::date as day) d
    left join (select (created_at at time zone 'Europe/Paris')::date as day, count(*) as n
                 from public.vehicles group by 1) e on e.day = d.day
    left join (select (recovered_at at time zone 'Europe/Paris')::date as day, count(*) as n
                 from public.vehicles where recovered_at is not null group by 1) r on r.day = d.day
    left join (select (sold_at at time zone 'Europe/Paris')::date as day, count(*) as n
                 from public.vehicle_sales where status = 'vendue' group by 1) s on s.day = d.day
    left join (select (created_at at time zone 'Europe/Paris')::date as day, count(*) as n
                 from public.claims group by 1) c on c.day = d.day;

  if v_mgr then
    v_money := jsonb_build_object(
      'fees_collected', coalesce((select sum(final_amount) from public.vehicles where recovered_at is not null), 0),
      'fees_pending', coalesce((select sum(private.billing_amount(handling_fee, daily_rate, created_at, billing_end_at))
                                  from public.vehicles where status in ('en_fourriere', 'reclamee')), 0),
      'sales_total', coalesce((select sum(sold_price) from public.vehicle_sales where status = 'vendue'), 0),
      'sales_average', coalesce((select round(avg(sold_price)) from public.vehicle_sales where status = 'vendue'), 0),
      'for_sale_value', coalesce((select sum(price) from public.vehicle_sales where status = 'a_vendre'), 0),
      'discounts_total', coalesce((select sum(original_amount - final_amount) from public.discount_redemptions where status = 'utilisee'), 0));
    select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'count', t.n) order by t.n desc), '[]'::jsonb)
      into v_staff
      from (select coalesce(created_by_name, 'Inconnu') as name, count(*) as n
              from public.vehicles group by 1 order by n desc limit 10) t;
  end if;

  return jsonb_build_object('totals', v_totals, 'status_breakdown', v_status, 'daily', v_daily,
                            'money', v_money, 'by_staff', v_staff, 'advanced', v_mgr);
end $$;
