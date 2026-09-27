-- Options de vente, annonces preparees et saisies accessibles aux forces de l'ordre.

create table if not exists public.seizures (
  id uuid primary key default gen_random_uuid(),
  plate text not null check (char_length(btrim(plate)) between 2 and 16),
  color text not null check (char_length(btrim(color)) between 1 and 40),
  model text not null check (char_length(btrim(model)) between 1 and 60),
  requested_by text not null check (requested_by in ('police', 'gendarmerie')),
  status text not null default 'active' check (status in ('active', 'recuperee')),
  created_by uuid references public.profiles (id) on delete set null,
  created_by_name text not null,
  created_at timestamptz not null default now(),
  recovered_by uuid references public.profiles (id) on delete set null,
  recovered_by_name text,
  recovered_at timestamptz
);
create index if not exists seizures_status_created_idx on public.seizures (status, created_at desc);
alter table public.seizures enable row level security;
alter table public.sale_options enable row level security;
alter table public.vehicle_sale_drafts enable row level security;
revoke all on public.seizures, public.sale_options, public.vehicle_sale_drafts from anon, authenticated;

create or replace function private.is_law_enforcement() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('police', 'gendarmerie'));
$$;
create or replace function private.require_law_enforcement() returns uuid
language plpgsql set search_path = public, private as $$
declare v_uid uuid := private.require_login();
begin
  if not private.is_law_enforcement() then raise exception 'Acces reserve aux forces de l''ordre.' using errcode = '42501'; end if;
  return v_uid;
end $$;

insert into public.vehicle_sale_drafts (vehicle_id)
select id from public.vehicles where status in ('en_fourriere', 'reclamee', 'attente_vente')
on conflict (vehicle_id) do nothing;
create or replace function private.ensure_sale_draft() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.vehicle_sale_drafts (vehicle_id) values (new.id) on conflict (vehicle_id) do nothing;
  return new;
end $$;
drop trigger if exists vehicle_sale_draft_insert on public.vehicles;
create trigger vehicle_sale_draft_insert after insert on public.vehicles for each row execute function private.ensure_sale_draft();

create or replace function private.publish_prepared_sale_for_vehicle(p_vehicle_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_d public.vehicle_sale_drafts; v_v public.vehicles;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found or v_v.status <> 'attente_vente' then return; end if;
  select * into v_d from public.vehicle_sale_drafts where vehicle_id = p_vehicle_id for update;
  if not found or v_d.price is null or char_length(btrim(coalesce(v_d.description, ''))) < 3 then return; end if;
  insert into public.vehicle_sales (vehicle_id, price, description, listed_by, listed_by_name)
  values (p_vehicle_id, v_d.price, v_d.description, v_d.updated_by, private.display_name(v_d.updated_by));
  delete from public.vehicle_sale_drafts where vehicle_id = p_vehicle_id;
  update public.vehicles set status = 'a_vendre', status_changed_at = now() where id = p_vehicle_id;
  perform private.log_action('sale.auto_list', 'vehicle', p_vehicle_id, p_vehicle_id,
    format('Le véhicule %s a été mis en vente automatiquement au prix de %s', v_v.plate, private.fmt_money(v_d.price)),
    jsonb_build_object('price', v_d.price));
end $$;

create or replace function private.publish_prepared_sale() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  if new.status = 'attente_vente' and old.status <> 'attente_vente' then
    perform private.publish_prepared_sale_for_vehicle(new.id);
  end if;
  return new;
end $$;
drop trigger if exists vehicle_publish_prepared_sale on public.vehicles;
create trigger vehicle_publish_prepared_sale after update of status on public.vehicles for each row execute function private.publish_prepared_sale();

create or replace function public.sale_queue()
returns table (id uuid, plate text, model text, color text, status text, created_at timestamptz,
  days_in_impound integer, current_amount numeric, prepared_price numeric, prepared_description text, photos jsonb)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return query select v.id, v.plate, v.model, v.color, v.status, v.created_at,
    private.billing_days(v.created_at, v.billing_end_at),
    coalesce(v.final_amount, private.billing_amount(v.handling_fee, v.daily_rate, v.created_at, v.billing_end_at)),
    d.price, d.description,
    coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'path', p.storage_path, 'position', p.position)
      order by p.position, p.created_at) from public.vehicle_photos p where p.vehicle_id = v.id), '[]'::jsonb)
    from public.vehicles v left join public.vehicle_sale_drafts d on d.vehicle_id = v.id
    where v.status in ('en_fourriere', 'reclamee', 'attente_vente') order by v.created_at asc;
end $$;

create or replace function public.save_sale_draft(p_vehicle_id uuid, p_price numeric, p_description text) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_v public.vehicles; v_desc text := btrim(coalesce(p_description, ''));
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found or v_v.status not in ('en_fourriere', 'reclamee', 'attente_vente') then raise exception 'Ce véhicule ne peut pas être préparé pour la vente.'; end if;
  if p_price is not null and (p_price <= 0 or p_price > 1000000000) then raise exception 'Prix de vente invalide.'; end if;
  if p_price is not null and char_length(v_desc) < 3 then raise exception 'Ajoutez une description avant de préparer le prix.'; end if;
  if char_length(v_desc) > 2000 then raise exception 'Description trop longue (2000 caractères maximum).'; end if;
  insert into public.vehicle_sale_drafts (vehicle_id, price, description, updated_at, updated_by)
  values (p_vehicle_id, p_price, case when p_price is null then null else v_desc end, now(), v_uid)
  on conflict (vehicle_id) do update set price = excluded.price, description = excluded.description, updated_at = now(), updated_by = v_uid;
  if v_v.status = 'attente_vente' and p_price is not null then perform private.publish_prepared_sale_for_vehicle(p_vehicle_id); end if;
end $$;

create or replace function public.force_sale_ready(p_vehicle_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_v public.vehicles; v_days integer;
begin
  select * into v_v from public.vehicles where id = p_vehicle_id for update;
  if not found or v_v.status <> 'en_fourriere' then raise exception 'Seuls les véhicules non réclamés en fourrière peuvent être accélérés.'; end if;
  if exists (select 1 from public.conversations where vehicle_id = p_vehicle_id and type = 'claim' and status = 'ouverte') then raise exception 'Ce véhicule a une demande de récupération ouverte.'; end if;
  select auto_sale_days into v_days from public.pricing_settings where id = 1;
  update public.vehicles set created_at = now() - make_interval(days => v_days), updated_by = v_uid, updated_by_name = private.display_name(v_uid) where id = p_vehicle_id;
  update public.pricing_settings set last_auto_check_at = null where id = 1;
  perform public.process_auto_sale();
end $$;

create or replace function public.list_sale_options()
returns table (id uuid, label text, price numeric, active boolean)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_login();
  return query select o.id, o.label, o.price, o.active from public.sale_options o where o.active or private.is_manager() order by o.label;
end $$;
create or replace function public.save_sale_option(p_id uuid, p_label text, p_price numeric, p_active boolean default true) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_id uuid := p_id; v_label text := btrim(coalesce(p_label, ''));
begin
  if char_length(v_label) not between 2 and 80 then raise exception 'Le nom de l''option doit contenir entre 2 et 80 caractères.'; end if;
  if p_price is null or p_price < 0 or p_price > 100000000 then raise exception 'Prix d''option invalide.'; end if;
  if p_id is null then
    insert into public.sale_options (label, price, active) values (v_label, p_price, coalesce(p_active, true)) returning id into v_id;
  else
    update public.sale_options set label = v_label, price = p_price, active = coalesce(p_active, false), updated_at = now() where id = p_id;
    if not found then raise exception 'Option introuvable.'; end if;
  end if;
  perform private.log_action('sale.option', 'sale_option', v_id, null, format('%s a modifié l''option %s (%s)', private.display_name(v_uid), v_label, private.fmt_money(p_price)));
  return v_id;
end $$;

create or replace function public.create_seizure(p_plate text, p_color text, p_model text, p_requested_by text) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_law_enforcement(); v_id uuid; v_name text := private.display_name(v_uid);
begin
  if char_length(btrim(coalesce(p_plate, ''))) not between 2 and 16 then raise exception 'Plaque invalide.'; end if;
  if char_length(btrim(coalesce(p_color, ''))) not between 1 and 40 then raise exception 'Couleur invalide.'; end if;
  if char_length(btrim(coalesce(p_model, ''))) not between 1 and 60 then raise exception 'Modèle invalide.'; end if;
  if p_requested_by not in ('police', 'gendarmerie') then raise exception 'Service demandeur invalide.'; end if;
  insert into public.seizures (plate, color, model, requested_by, created_by, created_by_name)
  values (upper(btrim(p_plate)), btrim(p_color), btrim(p_model), p_requested_by, v_uid, v_name) returning id into v_id;
  return v_id;
end $$;
create or replace function public.list_seizures()
returns table (id uuid, plate text, color text, model text, requested_by text, status text,
  created_by_name text, created_at timestamptz, recovered_by_name text, recovered_at timestamptz)
language plpgsql stable security definer set search_path = public, private as $$
begin
  if not private.is_law_enforcement() and not private.is_manager() then raise exception 'Acces reserve aux forces de l''ordre et aux gerants.' using errcode = '42501'; end if;
  return query select s.id, s.plate, s.color, s.model, s.requested_by, s.status, s.created_by_name, s.created_at, s.recovered_by_name, s.recovered_at
    from public.seizures s order by (s.status = 'active') desc, s.created_at desc;
end $$;
create or replace function public.recover_seizure(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_law_enforcement();
begin
  update public.seizures set status = 'recuperee', recovered_at = now(), recovered_by = v_uid, recovered_by_name = private.display_name(v_uid)
    where id = p_id and status = 'active';
  if not found then raise exception 'Cette saisie est deja recuperee ou introuvable.'; end if;
end $$;
create or replace function public.seizure_stats() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare v_uid uuid := private.require_law_enforcement();
begin
  return jsonb_build_object('total', (select count(*) from public.seizures), 'active', (select count(*) from public.seizures where status = 'active'),
    'recovered', (select count(*) from public.seizures where status = 'recuperee'), 'police', (select count(*) from public.seizures where requested_by = 'police'),
    'gendarmerie', (select count(*) from public.seizures where requested_by = 'gendarmerie'), 'mine', (select count(*) from public.seizures where created_by = v_uid));
end $$;

revoke all on function private.is_law_enforcement() from public, anon, authenticated;
revoke all on function private.require_law_enforcement() from public, anon, authenticated;
revoke all on function private.ensure_sale_draft() from public, anon, authenticated;
revoke all on function private.publish_prepared_sale() from public, anon, authenticated;
revoke all on function private.publish_prepared_sale_for_vehicle(uuid) from public, anon, authenticated;
do $$
declare v_fn text;
begin
  foreach v_fn in array array['sale_queue', 'save_sale_draft', 'force_sale_ready', 'list_sale_options', 'save_sale_option', 'create_seizure', 'list_seizures', 'recover_seizure', 'seizure_stats'] loop
    execute format('revoke all on function public.%I from public, anon, authenticated', v_fn);
    execute format('grant execute on function public.%I to authenticated', v_fn);
  end loop;
end $$;