-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — INSTALLATION COMPLÈTE DE LA BASE
--  À coller en une seule fois dans Supabase > SQL Editor > New query > Run.
--  (Contenu = les fichiers du dossier parts/ mis bout à bout.)
-- =====================================================================

-- >>>>>>>>>> parts/01_tables.sql
-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 1/8 : extensions, tables et index
--  À exécuter dans Supabase : SQL Editor > New query > coller > Run
--  Le script peut être relancé sans danger (il ne supprime aucune donnée).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Schéma "private" : fonctions internes et données sensibles.
-- Il n'est PAS exposé par l'API Supabase (seul "public" l'est).
create schema if not exists private;
grant usage on schema private to anon, authenticated;

-- ---------------------------------------------------------------------
--  Fonctions utilitaires nécessaires aux tables
-- ---------------------------------------------------------------------

-- Clé de comparaison d'un nom : minuscules, sans accents, sans ponctuation.
-- "Jean-Pierre", "jean pierre" et "JEAN PIERRE" donnent la même clé.
create or replace function private.norm_key(p_text text)
returns text
language sql immutable parallel safe
set search_path = ''
as $$
  select btrim(regexp_replace(lower(translate(coalesce(p_text, ''),
    'ÀÁÂÃÄÅàáâãäåÇçÈÉÊËèéêëÌÍÎÏìíîïÑñÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÝýÿŒœÆæ',
    'AAAAAAaaaaaaCcEEEEeeeeIIIIiiiiNnOOOOOOooooooUUUUuuuuYyyOoAa')),
    '[^a-z0-9]+', ' ', 'g'));
$$;

-- E-mail technique interne (jamais affiché, aucun e-mail n'est envoyé).
-- Le domaine ".invalid" est réservé par la norme : personne ne peut le posséder.
create or replace function private.make_email(p_nom_key text, p_prenom_key text)
returns text
language sql immutable
set search_path = ''
as $$
  select replace(p_prenom_key, ' ', '-') || '.' || replace(p_nom_key, ' ', '-') || '@belleroche.invalid';
$$;

-- ---------------------------------------------------------------------
--  Profils (un par compte)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  nom           text not null,
  prenom        text not null,
  nom_key       text not null,
  prenom_key    text not null,
  role          text not null default 'client'
                check (role in ('client', 'employe', 'gerant', 'admin', 'forces_ordre')),
  is_main_admin boolean not null default false,
  phone_rp      text,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz,
  constraint profiles_identity_unique unique (nom_key, prenom_key),
  -- Le rôle "admin" n'existe que pour le compte principal, et inversement.
  constraint profiles_admin_only_main check ((role = 'admin') = is_main_admin)
);
create unique index if not exists profiles_single_main_admin
  on public.profiles (is_main_admin) where is_main_admin;

-- ---------------------------------------------------------------------
--  Personnel (historique d'embauche / licenciement)
-- ---------------------------------------------------------------------
create table if not exists public.staff (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  role          text not null check (role in ('employe', 'gerant', 'admin')),
  status        text not null default 'actif' check (status in ('actif', 'vire')),
  hired_at      timestamptz not null default now(),
  hired_by      uuid references public.profiles (id) on delete set null,
  hired_by_name text,
  fired_at      timestamptz,
  fired_by      uuid references public.profiles (id) on delete set null,
  fired_by_name text,
  fire_reason   text
);
create unique index if not exists staff_one_active_per_user
  on public.staff (user_id) where status = 'actif';

-- ---------------------------------------------------------------------
--  Tarifs et paramètres (une seule ligne)
-- ---------------------------------------------------------------------
create table if not exists public.pricing_settings (
  id                      smallint primary key default 1 check (id = 1),
  handling_fee            numeric(12, 2) not null default 1000 check (handling_fee >= 0),
  daily_rate              numeric(12, 2) not null default 1500 check (daily_rate >= 0),
  auto_sale_days          integer not null default 7 check (auto_sale_days between 1 and 365),
  employee_delete_minutes integer not null default 30 check (employee_delete_minutes between 0 and 1440),
  last_auto_check_at      timestamptz,
  updated_at              timestamptz not null default now(),
  updated_by              uuid references public.profiles (id) on delete set null,
  updated_by_name         text
);
insert into public.pricing_settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
--  Véhicules
--  Un véhicule n'est jamais supprimé lors d'un claim ou d'une vente :
--  seul son statut change (voir la colonne "status").
-- ---------------------------------------------------------------------
create table if not exists public.vehicles (
  id                    uuid primary key default gen_random_uuid(),
  plate                 text not null check (char_length(btrim(plate)) between 2 and 16),
  plate_key             text not null,
  model                 text not null check (char_length(btrim(model)) between 1 and 60),
  color                 text not null check (char_length(btrim(color)) between 1 and 40),
  notes                 text check (char_length(notes) <= 1000),
  status                text not null default 'en_fourriere'
                        check (status in ('en_fourriere', 'reclamee', 'recuperee',
                                          'attente_vente', 'a_vendre', 'vendue', 'archivee')),
  status_changed_at     timestamptz not null default now(),
  status_before_archive text,
  created_at            timestamptz not null default now(),
  created_by            uuid references public.profiles (id) on delete set null,
  created_by_name       text,
  handling_fee          numeric(12, 2) not null,
  daily_rate            numeric(12, 2) not null,
  billing_end_at        timestamptz,          -- fin de la facturation de garde
  final_amount          numeric(12, 2),       -- montant figé quand le véhicule quitte la garde
  recovered_at          timestamptz,
  recovered_by          uuid references public.profiles (id) on delete set null,
  recovered_by_name     text,
  auto_flagged_at       timestamptz,          -- passage automatique en attente de vente
  updated_at            timestamptz not null default now(),
  updated_by            uuid references public.profiles (id) on delete set null,
  updated_by_name       text
);
-- Une plaque ne peut être présente qu'une fois parmi les véhicules "actifs".
create unique index if not exists vehicles_active_plate_unique
  on public.vehicles (plate_key)
  where status in ('en_fourriere', 'reclamee', 'attente_vente', 'a_vendre');
create index if not exists vehicles_status_idx on public.vehicles (status, created_at desc);
create index if not exists vehicles_created_by_idx on public.vehicles (created_by);

create table if not exists public.vehicle_photos (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references public.vehicles (id) on delete cascade,
  storage_path text not null unique,
  position     integer not null default 0,
  created_at   timestamptz not null default now(),
  created_by   uuid references public.profiles (id) on delete set null
);
create index if not exists vehicle_photos_vehicle_idx on public.vehicle_photos (vehicle_id, position);

-- ---------------------------------------------------------------------
--  Ventes de véhicules
-- ---------------------------------------------------------------------
create table if not exists public.vehicle_sales (
  id             uuid primary key default gen_random_uuid(),
  vehicle_id     uuid not null references public.vehicles (id) on delete cascade,
  status         text not null default 'a_vendre' check (status in ('a_vendre', 'vendue', 'retiree')),
  price          numeric(12, 2) not null check (price > 0),
  description    text not null,
  listed_at      timestamptz not null default now(),
  listed_by      uuid references public.profiles (id) on delete set null,
  listed_by_name text,
  sold_at        timestamptz,
  sold_price     numeric(12, 2),
  buyer_id       uuid references public.profiles (id) on delete set null,
  buyer_name     text,
  sold_by        uuid references public.profiles (id) on delete set null,
  sold_by_name   text,
  withdrawn_at   timestamptz
);
create unique index if not exists vehicle_sales_one_active
  on public.vehicle_sales (vehicle_id) where status = 'a_vendre';
create index if not exists vehicle_sales_status_idx on public.vehicle_sales (status);

-- ---------------------------------------------------------------------
--  Claims (demandes de récupération) : plusieurs par véhicule possibles
-- ---------------------------------------------------------------------
create table if not exists public.claims (
  id                uuid primary key default gen_random_uuid(),
  vehicle_id        uuid not null references public.vehicles (id) on delete cascade,
  client_id         uuid references public.profiles (id) on delete set null,
  client_name       text not null,
  status            text not null default 'ouverte' check (status in ('ouverte', 'validee', 'annulee')),
  created_at        timestamptz not null default now(),
  closed_at         timestamptz,
  processed_by      uuid references public.profiles (id) on delete set null,
  processed_by_name text,
  amount_due        numeric(12, 2)
);
create unique index if not exists claims_one_open_per_client
  on public.claims (vehicle_id, client_id) where status = 'ouverte';
create index if not exists claims_vehicle_idx on public.claims (vehicle_id);

-- ---------------------------------------------------------------------
--  Conversations, participants, messages
-- ---------------------------------------------------------------------
create table if not exists public.conversations (
  id                   uuid primary key default gen_random_uuid(),
  type                 text not null check (type in ('claim', 'vente')),
  vehicle_id           uuid not null references public.vehicles (id) on delete cascade,
  claim_id             uuid references public.claims (id) on delete set null,
  sale_id              uuid references public.vehicle_sales (id) on delete set null,
  client_id            uuid references public.profiles (id) on delete set null,
  client_name          text not null,
  status               text not null default 'ouverte' check (status in ('ouverte', 'fermee')),
  created_at           timestamptz not null default now(),
  last_message_at      timestamptz not null default now(),
  last_message_preview text,
  closed_at            timestamptz,
  closed_by            uuid references public.profiles (id) on delete set null,
  closed_by_name       text
);
-- Un client ne peut avoir qu'une conversation ouverte par véhicule et par type.
create unique index if not exists conversations_one_open
  on public.conversations (vehicle_id, client_id, type) where status = 'ouverte';
create index if not exists conversations_client_idx on public.conversations (client_id, last_message_at desc);
create index if not exists conversations_vehicle_idx on public.conversations (vehicle_id, status);
create index if not exists conversations_last_msg_idx on public.conversations (last_message_at desc);

create table if not exists public.conversation_participants (
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  participant_role text not null check (participant_role in ('client', 'staff')),
  joined_at        timestamptz not null default now(),
  last_read_at     timestamptz,
  primary key (conversation_id, user_id)
);
create index if not exists conv_participants_user_idx on public.conversation_participants (user_id);

create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id       uuid references public.profiles (id) on delete set null,
  sender_name     text not null default 'Système',
  sender_role     text not null default 'system'
                  check (sender_role in ('client', 'employe', 'gerant', 'admin', 'system')),
  kind            text not null default 'text' check (kind in ('text', 'system')),
  content         text not null check (char_length(btrim(content)) between 1 and 2000),
  created_at      timestamptz not null default now()
);
create index if not exists messages_conversation_idx on public.messages (conversation_id, created_at);

-- ---------------------------------------------------------------------
--  Notifications et historique
-- ---------------------------------------------------------------------
create table if not exists public.notifications (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  type            text not null,
  title           text not null,
  body            text,
  link            text,
  conversation_id uuid references public.conversations (id) on delete cascade,
  vehicle_id      uuid references public.vehicles (id) on delete cascade,
  count           integer not null default 1,
  created_at      timestamptz not null default now(),
  read_at         timestamptz
);
create index if not exists notifications_user_idx on public.notifications (user_id, read_at, created_at desc);

create table if not exists public.activity_logs (
  id          bigint generated always as identity primary key,
  actor_id    uuid references public.profiles (id) on delete set null,
  actor_name  text not null,
  actor_role  text not null,
  action      text not null,
  entity_type text not null,
  entity_id   uuid,
  vehicle_id  uuid,            -- volontairement sans clé étrangère : l'historique survit à la suppression
  summary     text not null,
  details     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists activity_logs_created_idx on public.activity_logs (created_at desc);
create index if not exists activity_logs_vehicle_idx on public.activity_logs (vehicle_id, created_at desc);

-- ---------------------------------------------------------------------
--  Codes de récupération de mot de passe (jamais exposés à l'API)
-- ---------------------------------------------------------------------
create table if not exists private.recovery_codes (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  code_hash       text not null,
  created_at      timestamptz not null default now(),
  failed_attempts integer not null default 0,
  locked_until    timestamptz
);
alter table private.recovery_codes enable row level security;

-- =====================================================================
--  CODES PROMO (ajout) : réductions en % appliquées depuis une conversation.
--  Instructions répétables sans risque (IF NOT EXISTS) : on peut relancer
--  l'installation par-dessus une base existante, les données sont conservées.
-- =====================================================================
alter table public.conversations  add column if not exists discount_code text;
alter table public.conversations  add column if not exists discount_percent integer;
alter table public.conversations  add column if not exists discount_redemption_id uuid;
alter table public.vehicles       add column if not exists discount_code text;
alter table public.vehicles       add column if not exists discount_percent integer;
alter table public.vehicles       add column if not exists original_amount numeric(12, 2);
alter table public.vehicle_sales  add column if not exists discount_code text;
alter table public.vehicle_sales  add column if not exists discount_percent integer;

create table if not exists public.discount_codes (
  id              uuid primary key default gen_random_uuid(),
  code            text not null,
  percent         integer not null check (percent between 1 and 100),
  scope           text not null default 'tous' check (scope in ('fourriere', 'vente', 'tous')),
  max_uses        integer check (max_uses is null or max_uses > 0),
  once_per_client boolean not null default true,
  expires_at      timestamptz,
  active          boolean not null default true,
  note            text check (char_length(note) <= 200),
  created_by      uuid references public.profiles (id) on delete set null,
  created_by_name text,
  created_at      timestamptz not null default now()
);
create unique index if not exists discount_codes_code_uidx on public.discount_codes (code);

create table if not exists public.discount_redemptions (
  id              uuid primary key default gen_random_uuid(),
  code_id         uuid not null references public.discount_codes (id),
  code            text not null,
  conversation_id uuid references public.conversations (id) on delete set null,
  vehicle_id      uuid,                          -- sans clé étrangère : l'historique survit à la suppression du véhicule
  client_id       uuid references public.profiles (id) on delete set null,
  client_name     text not null,
  applied_by_name text,
  kind            text not null check (kind in ('fourriere', 'vente')),
  percent         integer not null,
  status          text not null default 'appliquee' check (status in ('appliquee', 'utilisee', 'annulee')),
  original_amount numeric(12, 2),
  final_amount    numeric(12, 2),
  applied_at      timestamptz not null default now(),
  used_at         timestamptz,
  released_at     timestamptz
);
create unique index if not exists discount_redemptions_conv_uidx on public.discount_redemptions (conversation_id) where status in ('appliquee', 'utilisee');
create index if not exists discount_redemptions_code_idx on public.discount_redemptions (code_id, status);

-- Essais ratés de saisie de code (anti-devinette) : invisible depuis l'API
create table if not exists private.discount_attempts (
  id      bigint generated always as identity primary key,
  user_id uuid not null,
  at      timestamptz not null default now()
);
create index if not exists discount_attempts_user_idx on private.discount_attempts (user_id, at);


-- =====================================================================
--  AJOUT : options de vente, tarification anticipée, promotion affichée,
--  comptes forces de l'ordre et saisies. Colonnes/tables ajoutées de façon
--  répétable (IF NOT EXISTS) pour pouvoir relancer l'installation sans
--  perdre de données.
-- =====================================================================

-- Sur une base déjà installée, la contrainte ci-dessus (dans le CREATE TABLE) n'est pas rejouée :
-- on la met à jour explicitement pour autoriser le nouveau rôle « forces_ordre ».
do $$
begin
  alter table public.profiles drop constraint if exists profiles_role_check;
  alter table public.profiles add constraint profiles_role_check
    check (role in ('client', 'employe', 'gerant', 'admin', 'forces_ordre'));
exception when others then
  raise notice 'Contrainte de rôle non mise à jour automatiquement (%). Vérifiez-la manuellement si besoin.', sqlerrm;
end $$;

-- Tarif préparé à l'avance pendant que le véhicule est encore en fourrière.
alter table public.vehicles add column if not exists planned_price numeric(12, 2) check (planned_price is null or planned_price > 0);
alter table public.vehicles add column if not exists planned_description text check (planned_description is null or char_length(planned_description) <= 2000);

-- Promotion affichée directement sur l'annonce (sans code) + options choisies à l'achat.
alter table public.vehicle_sales add column if not exists promo_percent integer check (promo_percent is null or promo_percent between 1 and 99);
alter table public.vehicle_sales add column if not exists options jsonb not null default '[]'::jsonb;
alter table public.vehicle_sales add column if not exists options_total numeric(12, 2) not null default 0;

-- Options de vente (ex. « Réservoir plein », « Moteur réparé ») avec leur propre prix.
create table if not exists public.sale_options (
  id              uuid primary key default gen_random_uuid(),
  label           text not null check (char_length(btrim(label)) between 2 and 60),
  price           numeric(12, 2) not null check (price >= 0),
  active          boolean not null default true,
  created_by      uuid references public.profiles (id) on delete set null,
  created_by_name text,
  created_at      timestamptz not null default now()
);
create unique index if not exists sale_options_label_uidx on public.sale_options (lower(btrim(label)));

-- Saisies des forces de l'ordre : simple registre, sans lien avec la facturation de la fourrière.
create table if not exists public.seizures (
  id                uuid primary key default gen_random_uuid(),
  plate             text not null check (char_length(btrim(plate)) between 2 and 16),
  plate_key         text not null,
  model             text not null check (char_length(btrim(model)) between 1 and 60),
  color             text not null check (char_length(btrim(color)) between 1 and 40),
  agency            text not null check (agency in ('police', 'gendarmerie')),
  status            text not null default 'en_cours' check (status in ('en_cours', 'recuperee')),
  created_by        uuid references public.profiles (id) on delete set null,
  created_by_name   text,
  created_at        timestamptz not null default now(),
  recovered_by      uuid references public.profiles (id) on delete set null,
  recovered_by_name text,
  recovered_at      timestamptz
);
create unique index if not exists seizures_open_plate_uidx on public.seizures (plate_key) where status = 'en_cours';
create index if not exists seizures_status_idx on public.seizures (status, created_at desc);

-- >>>>>>>>>> parts/02_functions_core.sql
-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 2/8 : fonctions internes, triggers, comptes et personnel
-- =====================================================================

-- ---------------------------------------------------------------------
--  Rôles : toujours vérifiés côté base de données
-- ---------------------------------------------------------------------
create or replace function private.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('employe', 'gerant', 'admin'));
$$;

create or replace function private.is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('gerant', 'admin'));
$$;

create or replace function private.is_main_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and is_main_admin);
$$;

create or replace function private.require_login() returns uuid
language plpgsql set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception 'Vous devez être connecté.' using errcode = '42501';
  end if;
  return v;
end $$;

create or replace function private.require_staff() returns uuid
language plpgsql set search_path = public, private as $$
declare v uuid := private.require_login();
begin
  if not private.is_staff() then
    raise exception 'Accès réservé au personnel de la fourrière.' using errcode = '42501';
  end if;
  return v;
end $$;

create or replace function private.require_manager() returns uuid
language plpgsql set search_path = public, private as $$
declare v uuid := private.require_login();
begin
  if not private.is_manager() then
    raise exception 'Accès réservé aux gérants.' using errcode = '42501';
  end if;
  return v;
end $$;

create or replace function private.display_name(p_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select prenom || ' ' || nom from public.profiles where id = p_id;
$$;

-- ---------------------------------------------------------------------
--  Calcul des jours et des montants (toujours côté serveur)
--  Le premier jour compte comme une journée complète.
-- ---------------------------------------------------------------------
create or replace function private.billing_days(p_start timestamptz, p_end timestamptz default null)
returns integer language sql stable set search_path = '' as $$
  select greatest(1, ceil(extract(epoch from (coalesce(p_end, now()) - p_start)) / 86400.0))::integer;
$$;

create or replace function private.billing_amount(p_fee numeric, p_rate numeric,
                                                  p_start timestamptz, p_end timestamptz default null)
returns numeric language sql stable set search_path = '' as $$
  select p_fee + p_rate * private.billing_days(p_start, p_end);
$$;

create or replace function private.fmt_money(p_amount numeric) returns text
language sql immutable set search_path = '' as $$
  select replace(to_char(round(p_amount), 'FM999,999,999,990'), ',', ' ') || ' €';
$$;

-- ---------------------------------------------------------------------
--  Validation des identités et mots de passe
-- ---------------------------------------------------------------------
create or replace function private.check_identity(p_nom text, p_prenom text) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_nom !~ '^[A-Za-zÀ-ÖØ-öø-ÿŒœ][A-Za-zÀ-ÖØ-öø-ÿŒœ''’ -]{1,39}$' then
    raise exception 'Nom RP invalide : 2 à 40 lettres (espaces, tirets et apostrophes autorisés).';
  end if;
  if p_prenom !~ '^[A-Za-zÀ-ÖØ-öø-ÿŒœ][A-Za-zÀ-ÖØ-öø-ÿŒœ''’ -]{1,39}$' then
    raise exception 'Prénom RP invalide : 2 à 40 lettres (espaces, tirets et apostrophes autorisés).';
  end if;
end $$;

create or replace function private.check_password(p_password text) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_password is null or char_length(p_password) < 8 or char_length(p_password) > 72 then
    raise exception 'Le mot de passe doit contenir entre 8 et 72 caractères.';
  end if;
end $$;

-- Identité du compte administrateur principal : Gabin Muller.
create or replace function private.is_reserved_identity(p_nom_key text, p_prenom_key text)
returns boolean language sql immutable set search_path = '' as $$
  select p_nom_key = 'muller' and p_prenom_key = 'gabin';
$$;

-- ---------------------------------------------------------------------
--  Création d'un compte d'authentification (mot de passe haché en bcrypt)
-- ---------------------------------------------------------------------
create or replace function private.create_auth_user(p_nom text, p_prenom text, p_password text)
returns uuid
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare
  v_id    uuid := gen_random_uuid();
  v_email text := private.make_email(private.norm_key(p_nom), private.norm_key(p_prenom));
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
    crypt(p_password, gen_salt('bf', 10)), now(),
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('nom', p_nom, 'prenom', p_prenom, 'email_verified', true),
    now(), now(), '', '', '', ''
  );
  insert into auth.identities (id, user_id, provider_id, provider, identity_data,
                               last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text, 'email',
          jsonb_build_object('sub', v_id::text, 'email', v_email,
                             'email_verified', true, 'phone_verified', false),
          now(), now(), now());
  return v_id;
end $$;

-- Crée le profil dès qu'un compte est créé. Le rôle n'est JAMAIS lu depuis
-- les métadonnées envoyées par le navigateur : seul le nom réservé de
-- l'administrateur principal donne le rôle admin, et uniquement via
-- public.bootstrap_main_admin().
create or replace function private.handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  v_nom text := btrim(coalesce(new.raw_user_meta_data ->> 'nom', ''));
  v_prenom text := btrim(coalesce(new.raw_user_meta_data ->> 'prenom', ''));
  v_nk text; v_pk text; v_admin boolean;
begin
  if v_nom = '' or v_prenom = '' then
    return new;  -- compte non créé par le site : aucun profil
  end if;
  perform private.check_identity(v_nom, v_prenom);
  v_nk := private.norm_key(v_nom);
  v_pk := private.norm_key(v_prenom);
  v_admin := private.is_reserved_identity(v_nk, v_pk);
  if v_admin and coalesce(current_setting('app.bootstrap_admin', true), '') <> 'on' then
    raise exception 'Ce nom RP est réservé.';
  end if;
  insert into public.profiles (id, nom, prenom, nom_key, prenom_key, role, is_main_admin)
  values (new.id, initcap(lower(v_nom)), initcap(lower(v_prenom)), v_nk, v_pk,
          case when v_admin then 'admin' else 'client' end, v_admin);
  if v_admin then
    insert into public.staff (user_id, role, hired_by_name) values (new.id, 'admin', 'Système');
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created_belleroche on auth.users;
create trigger on_auth_user_created_belleroche
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

-- Protège le compte administrateur principal
create or replace function private.guard_profiles() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if tg_op = 'DELETE' then
    if old.is_main_admin and coalesce(current_setting('app.allow_admin_delete', true), '') <> 'on' then
      raise exception 'Le compte administrateur principal ne peut pas être supprimé.' using errcode = '42501';
    end if;
    return old;
  end if;
  if old.is_main_admin and (new.role <> 'admin' or not new.is_main_admin
                            or new.nom_key <> old.nom_key or new.prenom_key <> old.prenom_key) then
    raise exception 'Le compte administrateur principal ne peut pas être modifié.' using errcode = '42501';
  end if;
  if new.is_main_admin and not old.is_main_admin then
    raise exception 'Il ne peut exister qu''un seul administrateur principal.' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists guard_profiles_trg on public.profiles;
create trigger guard_profiles_trg before update or delete on public.profiles
  for each row execute function private.guard_profiles();

create or replace function private.guard_staff() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.role = 'admin' and (new.status = 'vire' or new.role <> 'admin') then
    raise exception 'L''administrateur principal ne peut pas être retiré du personnel.' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists guard_staff_trg on public.staff;
create trigger guard_staff_trg before update on public.staff
  for each row execute function private.guard_staff();

-- ---------------------------------------------------------------------
--  Codes de récupération de mot de passe
-- ---------------------------------------------------------------------
create or replace function private.issue_recovery_code(p_user uuid) returns text
language plpgsql security definer set search_path = public, extensions, private as $$
declare
  v_alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- 32 caractères, sans O/0/I/1
  v_bytes bytea := gen_random_bytes(16);
  v_raw text := '';
  v_i integer;
begin
  for v_i in 0..15 loop
    v_raw := v_raw || substr(v_alpha, (get_byte(v_bytes, v_i) % 32) + 1, 1);
  end loop;
  insert into private.recovery_codes (user_id, code_hash)
  values (p_user, crypt(v_raw, gen_salt('bf', 8)))
  on conflict (user_id) do update
    set code_hash = excluded.code_hash, created_at = now(), failed_attempts = 0, locked_until = null;
  return substr(v_raw, 1, 4) || '-' || substr(v_raw, 5, 4) || '-' || substr(v_raw, 9, 4) || '-' || substr(v_raw, 13, 4);
end $$;

-- ---------------------------------------------------------------------
--  Notifications internes et historique
-- ---------------------------------------------------------------------
create or replace function private.notify_user(
  p_user uuid, p_type text, p_title text, p_body text, p_link text,
  p_conv uuid default null, p_vehicle uuid default null, p_merge boolean default false)
returns void
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid;
begin
  if p_user is null then return; end if;
  if p_merge and p_conv is not null then
    select id into v_id from public.notifications
     where user_id = p_user and type = p_type and conversation_id = p_conv and read_at is null
     order by created_at desc limit 1;
    if found then
      update public.notifications
         set count = count + 1, title = p_title, body = p_body, created_at = now()
       where id = v_id;
      return;
    end if;
  end if;
  insert into public.notifications (user_id, type, title, body, link, conversation_id, vehicle_id)
  values (p_user, p_type, p_title, p_body, p_link, p_conv, p_vehicle);
end $$;

create or replace function private.notify_roles(
  p_roles text[], p_type text, p_title text, p_body text, p_link text,
  p_conv uuid default null, p_vehicle uuid default null, p_except uuid default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare r record;
begin
  for r in select id from public.profiles where role = any (p_roles) and id is distinct from p_except loop
    perform private.notify_user(r.id, p_type, p_title, p_body, p_link, p_conv, p_vehicle);
  end loop;
end $$;

create or replace function private.log_action(
  p_action text, p_entity_type text, p_entity_id uuid, p_vehicle_id uuid,
  p_summary text, p_details jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := auth.uid(); v_name text; v_role text;
begin
  if v_uid is not null then
    select prenom || ' ' || nom, role into v_name, v_role from public.profiles where id = v_uid;
  end if;
  insert into public.activity_logs (actor_id, actor_name, actor_role, action, entity_type,
                                    entity_id, vehicle_id, summary, details)
  values (case when v_name is null then null else v_uid end, coalesce(v_name, 'Système'),
          coalesce(v_role, 'system'), p_action, p_entity_type, p_entity_id, p_vehicle_id,
          p_summary, coalesce(p_details, '{}'::jsonb));
end $$;

create or replace function private.post_system_message(p_conv uuid, p_content text) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  perform set_config('app.system_message', 'on', true);
  insert into public.messages (conversation_id, content) values (p_conv, p_content);
  perform set_config('app.system_message', 'off', true);
end $$;

-- ---------------------------------------------------------------------
--  Triggers des véhicules
-- ---------------------------------------------------------------------
-- La date d'ajout est imposée par la base : l'utilisateur ne peut pas la choisir.
create or replace function private.vehicles_guard() returns trigger
language plpgsql set search_path = public, private as $$
begin
  new.plate := upper(regexp_replace(btrim(new.plate), '\s+', ' ', 'g'));
  new.plate_key := regexp_replace(new.plate, '[^A-Z0-9]', '', 'g');
  new.model := btrim(new.model);
  new.color := btrim(new.color);
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.status := 'en_fourriere';
    new.status_changed_at := now();
    new.billing_end_at := null;
    new.final_amount := null;
    new.recovered_at := null;
    new.auto_flagged_at := null;
    return new;
  end if;
  if new.created_at is distinct from old.created_at then
    raise exception 'La date d''ajout ne peut pas être modifiée.' using errcode = '42501';
  end if;
  if old.created_by is not null and new.created_by is not null and new.created_by <> old.created_by then
    raise exception 'L''auteur de la fiche ne peut pas être modifié.' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists vehicles_guard_trg on public.vehicles;
create trigger vehicles_guard_trg before insert or update on public.vehicles
  for each row execute function private.vehicles_guard();

-- ---------------------------------------------------------------------
--  Triggers des messages
-- ---------------------------------------------------------------------
create or replace function private.messages_before_insert() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  v_conv public.conversations;
  v_p public.profiles;
  v_system boolean := coalesce(current_setting('app.system_message', true), '') = 'on';
begin
  select * into v_conv from public.conversations where id = new.conversation_id;
  if not found then
    raise exception 'Conversation introuvable.';
  end if;
  new.created_at := clock_timestamp();
  if v_system then
    new.sender_id := null; new.sender_name := 'Système'; new.sender_role := 'system'; new.kind := 'system';
    return new;
  end if;
  if auth.uid() is null then
    raise exception 'Vous devez être connecté.' using errcode = '42501';
  end if;
  if v_conv.status <> 'ouverte' then
    raise exception 'Cette conversation est fermée.';
  end if;
  select * into v_p from public.profiles where id = auth.uid();
  if not found then
    raise exception 'Profil introuvable.' using errcode = '42501';
  end if;
  new.sender_id := v_p.id;
  new.sender_name := v_p.prenom || ' ' || v_p.nom;
  new.sender_role := case when v_p.id = v_conv.client_id then 'client' else v_p.role end;
  new.kind := 'text';
  new.content := btrim(new.content);
  return new;
end $$;

drop trigger if exists messages_before_insert_trg on public.messages;
create trigger messages_before_insert_trg before insert on public.messages
  for each row execute function private.messages_before_insert();

create or replace function private.messages_after_insert() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  v_c public.conversations;
  v_v public.vehicles;
  v_preview text := left(regexp_replace(new.content, '\s+', ' ', 'g'), 120);
  v_recipients uuid[];
  v_to uuid;
begin
  select * into v_c from public.conversations where id = new.conversation_id;
  update public.conversations
     set last_message_at = new.created_at, last_message_preview = v_preview
   where id = new.conversation_id;
  if new.kind = 'system' then return new; end if;

  insert into public.conversation_participants (conversation_id, user_id, participant_role, last_read_at)
  values (new.conversation_id, new.sender_id,
          case when new.sender_id = v_c.client_id then 'client' else 'staff' end, now())
  on conflict (conversation_id, user_id) do update set last_read_at = now();

  select * into v_v from public.vehicles where id = v_c.vehicle_id;

  if new.sender_id = v_c.client_id then
    -- Vers le personnel : ceux qui suivent déjà la conversation, sinon tout le personnel
    select array_agg(cp.user_id) into v_recipients
      from public.conversation_participants cp
      join public.profiles p on p.id = cp.user_id
     where cp.conversation_id = new.conversation_id and cp.participant_role = 'staff'
       and p.role in ('employe', 'gerant', 'admin') and cp.user_id <> new.sender_id;
    if v_recipients is null then
      select array_agg(id) into v_recipients from public.profiles
       where role in ('employe', 'gerant', 'admin') and id <> new.sender_id;
    end if;
  else
    -- Vers le client et les autres membres du personnel impliqués
    select array_agg(x) into v_recipients from (
      select v_c.client_id as x
      union
      select cp.user_id from public.conversation_participants cp
       where cp.conversation_id = new.conversation_id and cp.participant_role = 'staff'
         and cp.user_id <> new.sender_id
    ) t where x is not null and x <> new.sender_id;
  end if;

  foreach v_to in array coalesce(v_recipients, '{}') loop
    perform private.notify_user(v_to, 'message', 'Nouveau message',
      new.sender_name || ' : ' || v_preview, '#/messages/' || new.conversation_id,
      new.conversation_id, v_c.vehicle_id, true);
  end loop;
  return new;
end $$;

drop trigger if exists messages_after_insert_trg on public.messages;
create trigger messages_after_insert_trg after insert on public.messages
  for each row execute function private.messages_after_insert();

-- =====================================================================
--  COMPTES
-- =====================================================================

-- Inscription : nom RP + prénom RP + mot de passe.
create or replace function public.register_account(p_nom text, p_prenom text, p_password text)
returns jsonb
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare
  v_nom text := btrim(coalesce(p_nom, ''));
  v_prenom text := btrim(coalesce(p_prenom, ''));
  v_nk text; v_pk text; v_id uuid; v_code text;
begin
  perform private.check_identity(v_nom, v_prenom);
  perform private.check_password(p_password);
  v_nk := private.norm_key(v_nom);
  v_pk := private.norm_key(v_prenom);
  if private.is_reserved_identity(v_nk, v_pk) then
    raise exception 'Ce nom RP est réservé.';
  end if;
  if exists (select 1 from public.profiles where nom_key = v_nk and prenom_key = v_pk) then
    raise exception 'Une personne porte déjà ce nom et ce prénom RP.';
  end if;
  if (select count(*) from public.profiles where created_at > now() - interval '10 minutes') >= 40 then
    raise exception 'Trop d''inscriptions en peu de temps. Réessayez dans quelques minutes.';
  end if;
  begin
    v_id := private.create_auth_user(v_nom, v_prenom, p_password);
  exception when unique_violation then
    raise exception 'Une personne porte déjà ce nom et ce prénom RP.';
  end;
  v_code := private.issue_recovery_code(v_id);
  return jsonb_build_object('email', private.make_email(v_nk, v_pk), 'recovery_code', v_code);
end $$;

-- Création du compte Gabin Muller (à lancer une seule fois depuis le SQL Editor).
create or replace function public.bootstrap_main_admin(p_password text) returns jsonb
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare v_id uuid; v_code text;
begin
  perform private.check_password(p_password);
  if exists (select 1 from public.profiles where is_main_admin) then
    raise exception 'Le compte administrateur Gabin Muller existe déjà.';
  end if;
  perform set_config('app.bootstrap_admin', 'on', true);
  v_id := private.create_auth_user('Muller', 'Gabin', p_password);
  perform set_config('app.bootstrap_admin', 'off', true);
  v_code := private.issue_recovery_code(v_id);
  return jsonb_build_object('message', 'Compte administrateur créé. Notez ce code de récupération et gardez-le précieusement.',
                            'nom', 'Muller', 'prenom', 'Gabin', 'recovery_code', v_code);
end $$;

-- Retrouve l'identifiant technique de connexion à partir du nom et du prénom.
create or replace function public.get_login_email(p_nom text, p_prenom text) returns text
language sql stable security definer set search_path = public, auth, private as $$
  select u.email::text
    from public.profiles p join auth.users u on u.id = p.id
   where p.nom_key = private.norm_key(p_nom) and p.prenom_key = private.norm_key(p_prenom);
$$;

create or replace function public.change_my_password(p_current text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare v_uid uuid := private.require_login(); v_hash text; v_sid text := auth.jwt() ->> 'session_id';
begin
  perform private.check_password(p_new);
  select encrypted_password into v_hash from auth.users where id = v_uid;
  if v_hash is null or crypt(coalesce(p_current, ''), v_hash) <> v_hash then
    raise exception 'Le mot de passe actuel est incorrect.';
  end if;
  update auth.users set encrypted_password = crypt(p_new, gen_salt('bf', 10)), updated_at = now()
   where id = v_uid;
  if v_sid is not null then
    begin  -- déconnecte les autres appareils
      delete from auth.sessions where user_id = v_uid and id::text <> v_sid;
    exception when others then null;
    end;
  end if;
end $$;

create or replace function public.regenerate_recovery_code(p_password text) returns text
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare v_uid uuid := private.require_login(); v_hash text;
begin
  select encrypted_password into v_hash from auth.users where id = v_uid;
  if v_hash is null or crypt(coalesce(p_password, ''), v_hash) <> v_hash then
    raise exception 'Le mot de passe est incorrect.';
  end if;
  return private.issue_recovery_code(v_uid);
end $$;

-- Mot de passe oublié : nom + prénom + code de récupération.
-- Renvoie un objet {ok, message} plutôt qu'une erreur, afin que le compteur
-- de tentatives échouées soit bien enregistré.
create or replace function public.reset_password_with_code(
  p_nom text, p_prenom text, p_code text, p_new_password text)
returns jsonb
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare
  v_prof public.profiles;
  v_rc private.recovery_codes;
  v_norm text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_new_code text;
  v_generic constant text := 'Informations incorrectes ou récupération temporairement bloquée.';
begin
  perform private.check_password(p_new_password);
  select * into v_prof from public.profiles
   where nom_key = private.norm_key(p_nom) and prenom_key = private.norm_key(p_prenom);
  if not found or char_length(v_norm) <> 16 then
    return jsonb_build_object('ok', false, 'message', v_generic);
  end if;
  select * into v_rc from private.recovery_codes where user_id = v_prof.id for update;
  if not found or (v_rc.locked_until is not null and v_rc.locked_until > now()) then
    return jsonb_build_object('ok', false, 'message', v_generic);
  end if;
  if crypt(v_norm, v_rc.code_hash) <> v_rc.code_hash then
    update private.recovery_codes
       set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
           locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end
     where user_id = v_prof.id;
    return jsonb_build_object('ok', false, 'message', v_generic);
  end if;
  update auth.users set encrypted_password = crypt(p_new_password, gen_salt('bf', 10)), updated_at = now()
   where id = v_prof.id;
  begin
    delete from auth.sessions where user_id = v_prof.id;
  exception when others then null;
  end;
  v_new_code := private.issue_recovery_code(v_prof.id);
  return jsonb_build_object('ok', true, 'recovery_code', v_new_code);
end $$;

create or replace function public.update_my_profile(p_phone text) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_login(); v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
begin
  if v_phone is not null and v_phone !~ '^[0-9 .+-]{3,20}$' then
    raise exception 'Numéro invalide (chiffres, espaces, points ou tirets, 20 caractères maximum).';
  end if;
  update public.profiles set phone_rp = v_phone where id = v_uid;
end $$;

create or replace function public.touch_last_seen() returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set last_seen_at = now()
   where id = auth.uid() and (last_seen_at is null or last_seen_at < now() - interval '5 minutes');
end $$;

-- =====================================================================
--  PERSONNEL
-- =====================================================================

-- Crée un nouveau compte directement avec le rôle employé ou gérant.
create or replace function public.staff_create_account(
  p_nom text, p_prenom text, p_password text, p_role text)
returns jsonb
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare
  v_uid uuid := private.require_manager();
  v_nom text := btrim(coalesce(p_nom, ''));
  v_prenom text := btrim(coalesce(p_prenom, ''));
  v_nk text; v_pk text; v_id uuid; v_code text;
begin
  if p_role not in ('employe', 'gerant') then
    raise exception 'Le rôle doit être « employé » ou « gérant ».';
  end if;
  perform private.check_identity(v_nom, v_prenom);
  perform private.check_password(p_password);
  v_nk := private.norm_key(v_nom);
  v_pk := private.norm_key(v_prenom);
  if private.is_reserved_identity(v_nk, v_pk) then
    raise exception 'Ce nom RP est réservé.';
  end if;
  if exists (select 1 from public.profiles where nom_key = v_nk and prenom_key = v_pk) then
    raise exception 'Une personne porte déjà ce nom et ce prénom RP.';
  end if;
  begin
    v_id := private.create_auth_user(v_nom, v_prenom, p_password);
  exception when unique_violation then
    raise exception 'Une personne porte déjà ce nom et ce prénom RP.';
  end;
  update public.profiles set role = p_role where id = v_id;
  insert into public.staff (user_id, role, hired_by, hired_by_name)
  values (v_id, p_role, v_uid, private.display_name(v_uid));
  v_code := private.issue_recovery_code(v_id);
  perform private.log_action('staff.create', 'staff', v_id, null,
    format('%s a créé le compte %s de %s %s', private.display_name(v_uid),
           case p_role when 'gerant' then 'gérant' else 'employé' end,
           initcap(lower(v_prenom)), initcap(lower(v_nom))),
    jsonb_build_object('role', p_role));
  perform private.notify_user(v_id, 'staff', 'Bienvenue dans l''équipe',
    'Votre compte ' || case p_role when 'gerant' then 'gérant' else 'employé' end || ' a été créé.', '#/admin');
  return jsonb_build_object('id', v_id, 'recovery_code', v_code);
end $$;

-- Recrute un compte existant (client) comme employé. Seul l'administrateur peut recruter un gérant.
create or replace function public.staff_recruit_existing(p_user_id uuid, p_role text) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_t public.profiles;
begin
  if p_role not in ('employe', 'gerant') then
    raise exception 'Rôle invalide.';
  end if;
  if p_role = 'gerant' and not private.is_main_admin() then
    raise exception 'Seul l''administrateur peut nommer un gérant à partir d''un compte existant.' using errcode = '42501';
  end if;
  select * into v_t from public.profiles where id = p_user_id for update;
  if not found then raise exception 'Compte introuvable.'; end if;
  if v_t.role <> 'client' then
    raise exception 'Cette personne fait déjà partie du personnel.';
  end if;
  update public.profiles set role = p_role where id = p_user_id;
  insert into public.staff (user_id, role, hired_by, hired_by_name)
  values (p_user_id, p_role, v_uid, private.display_name(v_uid));
  perform private.log_action('staff.recruit', 'staff', p_user_id, null,
    format('%s a recruté %s %s comme %s', private.display_name(v_uid), v_t.prenom, v_t.nom,
           case p_role when 'gerant' then 'gérant' else 'employé' end),
    jsonb_build_object('role', p_role));
  perform private.notify_user(p_user_id, 'staff', 'Vous rejoignez l''équipe',
    'Vous avez été recruté comme ' || case p_role when 'gerant' then 'gérant' else 'employé' end || '.', '#/admin');
end $$;

create or replace function public.staff_fire(p_user_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_t public.profiles; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into v_t from public.profiles where id = p_user_id for update;
  if not found then raise exception 'Compte introuvable.'; end if;
  if v_t.is_main_admin then
    raise exception 'Le compte administrateur principal ne peut pas être retiré du personnel.' using errcode = '42501';
  end if;
  if p_user_id = v_uid then
    raise exception 'Vous ne pouvez pas vous retirer vous-même du personnel.';
  end if;
  if v_t.role not in ('employe', 'gerant') then
    raise exception 'Cette personne ne fait pas partie du personnel.';
  end if;
  update public.staff
     set status = 'vire', fired_at = now(), fired_by = v_uid,
         fired_by_name = private.display_name(v_uid), fire_reason = v_reason
   where user_id = p_user_id and status = 'actif';
  update public.profiles set role = 'client' where id = p_user_id;
  perform private.log_action('staff.fire', 'staff', p_user_id, null,
    format('%s a viré %s %s (%s)', private.display_name(v_uid), v_t.prenom, v_t.nom,
           case v_t.role when 'gerant' then 'gérant' else 'employé' end),
    jsonb_build_object('role', v_t.role, 'reason', v_reason));
  perform private.notify_user(p_user_id, 'staff', 'Fin de vos fonctions',
    'Vous ne faites plus partie du personnel de la fourrière.', '#/compte');
end $$;

-- Promotion / rétrogradation : réservée à l'administrateur.
create or replace function public.staff_set_role(p_user_id uuid, p_role text) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_login(); v_t public.profiles;
begin
  if not private.is_main_admin() then
    raise exception 'Seul l''administrateur peut promouvoir ou rétrograder un membre du personnel.' using errcode = '42501';
  end if;
  if p_role not in ('employe', 'gerant') then raise exception 'Rôle invalide.'; end if;
  select * into v_t from public.profiles where id = p_user_id for update;
  if not found then raise exception 'Compte introuvable.'; end if;
  if v_t.is_main_admin or v_t.role not in ('employe', 'gerant') then
    raise exception 'Ce membre du personnel ne peut pas changer de rôle.';
  end if;
  if v_t.role = p_role then return; end if;
  update public.profiles set role = p_role where id = p_user_id;
  update public.staff set role = p_role where user_id = p_user_id and status = 'actif';
  perform private.log_action('staff.role', 'staff', p_user_id, null,
    format('%s est maintenant %s', v_t.prenom || ' ' || v_t.nom, case p_role when 'gerant' then 'gérant' else 'employé' end),
    jsonb_build_object('from', v_t.role, 'to', p_role));
  perform private.notify_user(p_user_id, 'staff', 'Votre rôle a changé',
    'Vous êtes maintenant ' || case p_role when 'gerant' then 'gérant' else 'employé' end || '.', '#/admin');
end $$;

-- Réinitialisation du mot de passe d'un client ou d'un employé (gérant), ou de n'importe qui (admin).
create or replace function public.staff_reset_password(p_user_id uuid, p_new_password text) returns void
language plpgsql security definer set search_path = public, extensions, private, auth as $$
declare v_uid uuid := private.require_manager(); v_t public.profiles;
begin
  perform private.check_password(p_new_password);
  select * into v_t from public.profiles where id = p_user_id;
  if not found then raise exception 'Compte introuvable.'; end if;
  if p_user_id = v_uid then
    raise exception 'Modifiez votre propre mot de passe depuis la page « Mon compte ».';
  end if;
  if v_t.is_main_admin then
    raise exception 'Le mot de passe de l''administrateur ne peut pas être réinitialisé ici.' using errcode = '42501';
  end if;
  if v_t.role = 'gerant' and not private.is_main_admin() then
    raise exception 'Seul l''administrateur peut réinitialiser le mot de passe d''un gérant.' using errcode = '42501';
  end if;
  update auth.users set encrypted_password = crypt(p_new_password, gen_salt('bf', 10)), updated_at = now()
   where id = p_user_id;
  begin
    delete from auth.sessions where user_id = p_user_id;
  exception when others then null;
  end;
  perform private.log_action('staff.reset_password', 'profile', p_user_id, null,
    format('%s a réinitialisé le mot de passe de %s %s', private.display_name(v_uid), v_t.prenom, v_t.nom));
end $$;

-- >>>>>>>>>> parts/03_functions_app.sql
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

-- >>>>>>>>>> parts/04_promo_codes.sql
-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 4/8 : codes promo
--
--  • Les gérants créent des codes (ex. −50 %), valables sur la fourrière,
--    sur la vente, ou les deux.
--  • Dans une conversation, le client (ou un employé) saisit le code : la
--    réduction est enregistrée et appliquée au moment de la récupération ou
--    de la vente. Les montants sont TOUJOURS recalculés par le serveur.
--  • Un code peut être limité (nombre d'utilisations, date de fin, une fois
--    par personne). Une utilisation abandonnée (conversation fermée sans
--    récupération ni vente) est rendue disponible.
--  • Anti-devinette : 8 essais ratés en 10 minutes bloquent la saisie.
-- =====================================================================

create or replace function private.norm_code(p text) returns text
language sql immutable set search_path = '' as $$
  select upper(regexp_replace(btrim(coalesce(p, '')), '\s+', '', 'g'));
$$;

-- Rend disponible l'utilisation d'un code si la conversation se ferme sans aboutir
create or replace function private.release_redemption(p_conv uuid) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  update public.discount_redemptions set status = 'annulee', released_at = now()
   where conversation_id = p_conv and status = 'appliquee';
  if found then  -- la réduction n'est plus valable : elle disparaît de la conversation (l'historique reste dans les utilisations)
    update public.conversations set discount_code = null, discount_percent = null, discount_redemption_id = null
     where id = p_conv;
  end if;
end $$;

-- ---------------------------------------------------------------------
--  Gestion des codes (gérants et administrateur)
-- ---------------------------------------------------------------------
create or replace function public.create_discount_code(
  p_code text, p_percent integer, p_scope text default 'tous', p_max_uses integer default null,
  p_expires_at timestamptz default null, p_once_per_client boolean default true, p_note text default null)
returns uuid
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_manager();
  v_code text := private.norm_code(p_code);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_id uuid;
begin
  if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,23}$' then
    raise exception 'Code invalide : 3 à 24 caractères (lettres, chiffres, tirets), sans espace ni accent.';
  end if;
  if p_percent is null or p_percent not between 1 and 100 then
    raise exception 'La réduction doit être comprise entre 1 et 100 %%.';
  end if;
  if p_scope not in ('fourriere', 'vente', 'tous') then raise exception 'Portée invalide.'; end if;
  if p_max_uses is not null and p_max_uses not between 1 and 100000 then
    raise exception 'Le nombre d''utilisations doit être compris entre 1 et 100000.';
  end if;
  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'La date de fin doit être dans le futur.';
  end if;
  if v_note is not null and char_length(v_note) > 200 then raise exception 'Note trop longue (200 caractères maximum).'; end if;
  begin
    insert into public.discount_codes (code, percent, scope, max_uses, once_per_client, expires_at, note, created_by, created_by_name)
    values (v_code, p_percent, p_scope, p_max_uses, coalesce(p_once_per_client, true), p_expires_at, v_note, v_uid, private.display_name(v_uid))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Ce code existe déjà.';
  end;
  perform private.log_action('discount.create', 'discount_code', v_id, null,
    format('%s a créé le code promo %s (−%s %%, %s)', private.display_name(v_uid), v_code, p_percent,
           case p_scope when 'fourriere' then 'fourrière' when 'vente' then 'vente' else 'fourrière et vente' end));
  return v_id;
end $$;

create or replace function public.set_discount_code_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_d public.discount_codes;
begin
  update public.discount_codes set active = coalesce(p_active, false) where id = p_id returning * into v_d;
  if not found then raise exception 'Code introuvable.'; end if;
  perform private.log_action('discount.toggle', 'discount_code', p_id, null,
    format('%s a %s le code promo %s', private.display_name(v_uid), case when v_d.active then 'réactivé' else 'désactivé' end, v_d.code));
end $$;

create or replace function public.delete_discount_code(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_d public.discount_codes;
begin
  select * into v_d from public.discount_codes where id = p_id for update;
  if not found then raise exception 'Code introuvable.'; end if;
  if exists (select 1 from public.discount_redemptions where code_id = p_id) then
    raise exception 'Ce code a déjà été utilisé : désactivez-le plutôt que de le supprimer.';
  end if;
  delete from public.discount_codes where id = p_id;
  perform private.log_action('discount.delete', 'discount_code', p_id, null,
    format('%s a supprimé le code promo %s', private.display_name(v_uid), v_d.code));
end $$;

create or replace function public.list_discount_codes()
returns table (id uuid, code text, percent integer, scope text, max_uses integer, once_per_client boolean,
               expires_at timestamptz, active boolean, note text, created_by_name text, created_at timestamptz,
               uses integer, used_count integer, state text)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return query
    select d.id, d.code, d.percent, d.scope, d.max_uses, d.once_per_client, d.expires_at, d.active, d.note,
           d.created_by_name, d.created_at,
           (select count(*)::integer from public.discount_redemptions r where r.code_id = d.id and r.status in ('appliquee', 'utilisee')),
           (select count(*)::integer from public.discount_redemptions r where r.code_id = d.id and r.status = 'utilisee'),
           case when not d.active then 'desactive'
                when d.expires_at is not null and d.expires_at <= now() then 'expire'
                when d.max_uses is not null and (select count(*) from public.discount_redemptions r
                       where r.code_id = d.id and r.status in ('appliquee', 'utilisee')) >= d.max_uses then 'epuise'
                else 'actif' end
      from public.discount_codes d
     order by d.created_at desc;
end $$;

create or replace function public.list_discount_redemptions(p_code_id uuid)
returns table (id uuid, client_name text, applied_by_name text, kind text, status text, percent integer,
               original_amount numeric, final_amount numeric, applied_at timestamptz, vehicle_label text)
language plpgsql stable security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return query
    select r.id, r.client_name, r.applied_by_name, r.kind, r.status, r.percent, r.original_amount, r.final_amount,
           r.applied_at, case when v.id is null then null else v.plate || ' · ' || v.model end
      from public.discount_redemptions r
      left join public.vehicles v on v.id = r.vehicle_id
     where r.code_id = p_code_id
     order by r.applied_at desc;
end $$;

-- ---------------------------------------------------------------------
--  Saisie d'un code dans une conversation (client concerné ou personnel)
--  Renvoie {ok, message, ...} au lieu de lever une erreur pour que les
--  essais ratés soient bien comptés.
-- ---------------------------------------------------------------------
create or replace function public.apply_discount_code(p_conversation_id uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_login();
  v_name text := private.display_name(v_uid);
  v_norm text := private.norm_code(p_code);
  v_c public.conversations; v_v public.vehicles; v_s public.vehicle_sales; v_d public.discount_codes;
  v_kind text; v_orig numeric; v_new numeric; v_red uuid; v_msg text;
begin
  select * into v_c from public.conversations where id = p_conversation_id for update;
  if not found or (v_c.client_id is distinct from v_uid and not private.is_staff()) then
    raise exception 'Conversation introuvable.' using errcode = '42501';
  end if;
  if v_c.status <> 'ouverte' then raise exception 'Cette conversation est fermée.'; end if;
  if v_c.discount_redemption_id is not null then
    return jsonb_build_object('ok', false, 'message', 'Un code promo est déjà appliqué à cette conversation.');
  end if;

  v_kind := case v_c.type when 'claim' then 'fourriere' else 'vente' end;
  select * into v_v from public.vehicles where id = v_c.vehicle_id for update;
  if v_kind = 'fourriere' then
    if not found or coalesce(v_v.status, '') not in ('en_fourriere', 'reclamee') then
      raise exception 'Ce véhicule n''est plus en fourrière.';
    end if;
    v_orig := private.billing_amount(v_v.handling_fee, v_v.daily_rate, v_v.created_at, v_v.billing_end_at);
  else
    select * into v_s from public.vehicle_sales where vehicle_id = v_c.vehicle_id and status = 'a_vendre';
    if not found or coalesce(v_v.status, '') <> 'a_vendre' then raise exception 'Ce véhicule n''est plus à vendre.'; end if;
    v_orig := case when v_s.promo_percent is null then v_s.price else round(v_s.price * (100 - v_s.promo_percent) / 100) end;
  end if;

  delete from private.discount_attempts where at < now() - interval '1 day';
  if (select count(*) from private.discount_attempts where user_id = v_uid and at > now() - interval '10 minutes') >= 8 then
    return jsonb_build_object('ok', false, 'message', 'Trop d''essais. Réessayez dans quelques minutes.');
  end if;

  select * into v_d from public.discount_codes where code = v_norm for update;
  if not found or not v_d.active or (v_d.expires_at is not null and v_d.expires_at <= now()) then
    insert into private.discount_attempts (user_id) values (v_uid);
    return jsonb_build_object('ok', false, 'message', 'Code invalide ou expiré.');
  end if;
  if v_d.scope <> 'tous' and v_d.scope <> v_kind then
    insert into private.discount_attempts (user_id) values (v_uid);
    return jsonb_build_object('ok', false, 'message',
      case v_d.scope when 'fourriere' then 'Ce code est réservé aux véhicules en fourrière.' else 'Ce code est réservé à l''achat d''un véhicule.' end);
  end if;
  if v_d.max_uses is not null and (select count(*) from public.discount_redemptions
        where code_id = v_d.id and status in ('appliquee', 'utilisee')) >= v_d.max_uses then
    return jsonb_build_object('ok', false, 'message', 'Ce code a atteint sa limite d''utilisations.');
  end if;
  if v_d.once_per_client and exists (select 1 from public.discount_redemptions
        where code_id = v_d.id and client_id = v_c.client_id and status in ('appliquee', 'utilisee')) then
    return jsonb_build_object('ok', false, 'message', 'Ce code a déjà été utilisé avec ce compte.');
  end if;

  v_new := round(v_orig * (100 - v_d.percent) / 100);
  insert into public.discount_redemptions (code_id, code, conversation_id, vehicle_id, client_id, client_name, applied_by_name, kind, percent, original_amount)
  values (v_d.id, v_d.code, v_c.id, v_c.vehicle_id, v_c.client_id, v_c.client_name, v_name, v_kind, v_d.percent, v_orig)
  returning id into v_red;
  update public.conversations
     set discount_code = v_d.code, discount_percent = v_d.percent, discount_redemption_id = v_red
   where id = v_c.id;

  v_msg := case v_kind
    when 'fourriere' then format('Code %s appliqué (−%s %%) : montant à régler actuellement %s au lieu de %s.', v_d.code, v_d.percent, private.fmt_money(v_new), private.fmt_money(v_orig))
    else format('Code %s appliqué (−%s %%) : %s au lieu de %s.', v_d.code, v_d.percent, private.fmt_money(v_new), private.fmt_money(v_orig)) end;
  perform private.post_system_message(v_c.id, v_msg);
  perform private.log_action('discount.apply', 'conversation', v_c.id, v_c.vehicle_id,
    format('%s a utilisé le code %s (−%s %%) sur %s (%s)',
           case when v_uid = v_c.client_id then v_c.client_name else v_name || ' pour ' || v_c.client_name end,
           v_d.code, v_d.percent, v_v.plate, v_v.model),
    jsonb_build_object('code', v_d.code, 'percent', v_d.percent, 'original', v_orig, 'discounted', v_new, 'kind', v_kind));
  perform private.notify_roles(array['employe', 'gerant', 'admin'], 'discount', 'Code promo utilisé',
    format('%s a utilisé le code %s (−%s %%)', v_c.client_name, v_d.code, v_d.percent),
    '#/messages/' || v_c.id, v_c.id, v_c.vehicle_id, v_uid);
  return jsonb_build_object('ok', true, 'code', v_d.code, 'percent', v_d.percent, 'kind', v_kind,
                            'original', v_orig, 'discounted', v_new, 'message', v_msg);
end $$;

-- Un gérant peut retirer un code encore non utilisé d'une conversation
create or replace function public.remove_conversation_discount(p_conversation_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare v_uid uuid := private.require_manager(); v_c public.conversations; v_name text := private.display_name(v_uid);
begin
  select * into v_c from public.conversations where id = p_conversation_id for update;
  if not found then raise exception 'Conversation introuvable.'; end if;
  if v_c.discount_redemption_id is null then raise exception 'Aucun code promo actif sur cette conversation.'; end if;
  if exists (select 1 from public.discount_redemptions where id = v_c.discount_redemption_id and status = 'utilisee') then
    raise exception 'Ce code a déjà servi à une transaction terminée : il ne peut plus être retiré.';
  end if;
  update public.discount_redemptions set status = 'annulee', released_at = now()
   where id = v_c.discount_redemption_id and status = 'appliquee';
  update public.conversations set discount_code = null, discount_percent = null, discount_redemption_id = null
   where id = p_conversation_id;
  if v_c.status = 'ouverte' then
    perform private.post_system_message(p_conversation_id, format('Le code %s a été retiré par %s.', v_c.discount_code, v_name));
  end if;
  perform private.log_action('discount.remove', 'conversation', p_conversation_id, v_c.vehicle_id,
    format('%s a retiré le code %s de la conversation de %s', v_name, v_c.discount_code, v_c.client_name));
end $$;

-- >>>>>>>>>> parts/05_extras.sql
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

-- >>>>>>>>>> parts/06_discord.sql
-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 6/8 : intégration Discord (webhooks)
--
--  • Catalogue "En fourrière" et catalogue "À vendre" : un message par
--    véhicule, SUPPRIMÉ AUTOMATIQUEMENT dès que le véhicule n'est plus
--    dans la catégorie (réclamé, récupéré, vendu, etc.).
--  • Notifications du personnel : nouveaux messages, demandes, etc.
--    (uniquement pour les employés, jamais pour les clients).
--
--  Les URL de webhook sont stockées dans le schéma "private" : elles ne
--  sont jamais renvoyées au navigateur. Les appels vers Discord sont faits
--  par la base (extension pg_net), de manière asynchrone, avec file
--  d'attente et nouvelles tentatives.
-- =====================================================================

do $$
begin
  begin
    create extension if not exists pg_net with schema extensions;
  exception when others then
    begin
      create extension if not exists pg_net;
    exception when others then
      raise notice 'pg_net n''a pas pu être activé automatiquement (%). Activez-le dans Database > Extensions.', sqlerrm;
    end;
  end;
end $$;

-- ---------------------------------------------------------------------
--  Tables (schéma private : invisibles depuis l'API)
-- ---------------------------------------------------------------------
create table if not exists private.discord_settings (
  id             smallint primary key default 1 check (id = 1),
  site_name      text not null default 'Fourrière de Belle Roche',
  site_url       text,
  storage_url    text,
  impound_url    text,
  impound_enabled boolean not null default true,
  sale_url       text,
  sale_enabled   boolean not null default true,
  staff_url      text,
  staff_enabled  boolean not null default true,
  staff_events   jsonb not null default
    '{"messages_client":true,"messages_staff":true,"claims":true,"vehicles":true,"sales":true,"staff":true,"other":true}',
  mention        text,
  updated_at     timestamptz not null default now(),
  updated_by_name text
);
insert into private.discord_settings (id) values (1) on conflict (id) do nothing;

create table if not exists private.discord_messages (
  id               uuid primary key default gen_random_uuid(),
  vehicle_id       uuid not null,      -- sans clé étrangère : on doit pouvoir supprimer le message d'un véhicule supprimé
  kind             text not null check (kind in ('impound', 'sale')),
  message_id       text,
  state            text not null default 'queued'
                   check (state in ('queued', 'posting', 'posted', 'deleting', 'deleted', 'cancelled', 'failed')),
  delete_requested boolean not null default false,
  last_error       text,
  created_at       timestamptz not null default now(),
  posted_at        timestamptz,
  deleted_at       timestamptz
);
create index if not exists discord_messages_vehicle_idx on private.discord_messages (vehicle_id, kind);
create index if not exists discord_messages_state_idx on private.discord_messages (state);

create table if not exists private.discord_outbox (
  id                 bigint generated always as identity primary key,
  slot               text not null check (slot in ('impound', 'sale', 'staff')),
  op                 text not null check (op in ('post', 'delete', 'notify', 'test')),
  message_ref        uuid references private.discord_messages (id) on delete set null,
  discord_message_id text,
  payload            jsonb,
  state              text not null default 'queued' check (state in ('queued', 'sent', 'done', 'failed', 'cancelled')),
  request_id         bigint,
  attempts           integer not null default 0,
  next_attempt_at    timestamptz not null default now(),
  sent_at            timestamptz,
  finished_at        timestamptz,
  last_error         text,
  created_at         timestamptz not null default now()
);
create index if not exists discord_outbox_state_idx on private.discord_outbox (state, next_attempt_at);

alter table private.discord_settings enable row level security;
alter table private.discord_messages enable row level security;
alter table private.discord_outbox enable row level security;

-- ---------------------------------------------------------------------
--  Validation des saisies (protège contre les URL arbitraires)
-- ---------------------------------------------------------------------
create or replace function private.discord_clean_url(p text) returns text
language plpgsql immutable set search_path = '' as $$
declare v text := btrim(coalesce(p, ''));
begin
  if v = '' then return null; end if;
  if v !~ '^https://(canary\.|ptb\.)?discord(app)?\.com/api(/v[0-9]+)?/webhooks/[0-9]{15,25}/[A-Za-z0-9._-]{20,120}$' then
    raise exception 'URL de webhook Discord invalide. Elle doit ressembler à https://discord.com/api/webhooks/123456789012345678/abcdef…';
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------
--  Envoi : construit et poste les messages, supprime les anciens
-- ---------------------------------------------------------------------
create or replace function private.discord_eligible(p_vehicle uuid, p_kind text) returns boolean
language sql stable security definer set search_path = public, private as $$
  select exists (select 1 from public.vehicles v
                  where v.id = p_vehicle
                    and ((p_kind = 'impound' and v.status = 'en_fourriere')
                      or (p_kind = 'sale' and v.status = 'a_vendre')));
$$;

-- Prépare le retrait d'un message du catalogue
create or replace function private.discord_retire(p_msg uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare m private.discord_messages;
begin
  select * into m from private.discord_messages where id = p_msg for update;
  if not found then return; end if;
  if m.state = 'queued' then
    update private.discord_messages set state = 'cancelled' where id = m.id;
    update private.discord_outbox set state = 'cancelled', finished_at = now()
     where message_ref = m.id and op = 'post' and state = 'queued';
  elsif m.state = 'posting' then
    update private.discord_messages set delete_requested = true where id = m.id;
  elsif m.state = 'posted' then
    if m.message_id is null then
      update private.discord_messages set state = 'deleted', deleted_at = now() where id = m.id;
    else
      update private.discord_messages set state = 'deleting' where id = m.id;
      insert into private.discord_outbox (slot, op, message_ref, discord_message_id)
      values (m.kind, 'delete', m.id, m.message_id);
    end if;
  end if;
end $$;

-- Compare l'état du véhicule et les messages Discord, puis corrige.
create or replace function private.discord_sync_vehicle(p_vehicle uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare
  s private.discord_settings; k text; v_elig boolean; m private.discord_messages; v_ref uuid;
begin
  select * into s from private.discord_settings where id = 1;
  if not found then return; end if;
  foreach k in array array['impound', 'sale'] loop
    v_elig := private.discord_eligible(p_vehicle, k);
    select * into m from private.discord_messages
     where vehicle_id = p_vehicle and kind = k and state in ('queued', 'posting', 'posted')
     order by created_at desc limit 1;
    if v_elig and not found then
      if (k = 'impound' and s.impound_enabled and s.impound_url is not null)
         or (k = 'sale' and s.sale_enabled and s.sale_url is not null) then
        insert into private.discord_messages (vehicle_id, kind) values (p_vehicle, k) returning id into v_ref;
        insert into private.discord_outbox (slot, op, message_ref) values (k, 'post', v_ref);
      end if;
    elsif (not v_elig) and found then
      perform private.discord_retire(m.id);
    end if;
  end loop;
end $$;

-- Remplace le message publié (le véhicule a été modifié : photo, modèle, prix…)
create or replace function private.discord_repost(p_vehicle uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare s private.discord_settings; k text; m private.discord_messages; v_ref uuid;
begin
  select * into s from private.discord_settings where id = 1;
  if not found then return; end if;
  foreach k in array array['impound', 'sale'] loop
    select * into m from private.discord_messages
     where vehicle_id = p_vehicle and kind = k and state in ('queued', 'posting', 'posted')
     order by created_at desc limit 1;
    if found and m.state = 'posted' and private.discord_eligible(p_vehicle, k) then
      perform private.discord_retire(m.id);
      if (k = 'impound' and s.impound_enabled and s.impound_url is not null)
         or (k = 'sale' and s.sale_enabled and s.sale_url is not null) then
        insert into private.discord_messages (vehicle_id, kind) values (p_vehicle, k) returning id into v_ref;
        insert into private.discord_outbox (slot, op, message_ref) values (k, 'post', v_ref);
      end if;
    end if;
  end loop;
end $$;

create or replace function private.discord_vehicle_payload(p_vehicle uuid, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare
  s private.discord_settings; v public.vehicles; sale public.vehicle_sales;
  v_photo text; v_embed jsonb; v_ts text;
begin
  select * into s from private.discord_settings where id = 1;
  select * into v from public.vehicles where id = p_vehicle;
  if not found then return null; end if;
  select storage_path into v_photo from public.vehicle_photos
   where vehicle_id = p_vehicle order by position, created_at limit 1;
  v_ts := extract(epoch from v.created_at)::bigint::text;

  if p_kind = 'impound' then
    v_embed := jsonb_build_object(
      'title', left('🚗 ' || v.model || ' — ' || v.plate, 250),
      'description', 'Véhicule en fourrière. Si c''est le vôtre, cliquez sur **« C''est ma voiture »** sur le site.',
      'color', x'1F5FBF'::int,
      'url', case when s.site_url is not null then s.site_url || '#/vehicules' end,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Plaque', 'value', '`' || replace(v.plate, '`', '') || '`', 'inline', true),
        jsonb_build_object('name', 'Modèle', 'value', left(v.model, 200), 'inline', true),
        jsonb_build_object('name', 'Couleur', 'value', left(v.color, 200), 'inline', true),
        jsonb_build_object('name', 'Arrivée', 'value', '<t:' || v_ts || ':f>', 'inline', true),
        jsonb_build_object('name', 'En fourrière', 'value', '<t:' || v_ts || ':R>', 'inline', true),
        jsonb_build_object('name', 'Tarif (RP)', 'value',
          private.fmt_money(v.handling_fee) || ' + ' || private.fmt_money(v.daily_rate) || ' / jour', 'inline', true)),
      'footer', jsonb_build_object('text', 'Le message disparaît quand le véhicule quitte la fourrière'));
  else
    select * into sale from public.vehicle_sales where vehicle_id = p_vehicle and status = 'a_vendre';
    if not found then return null; end if;
    v_embed := jsonb_build_object(
      'title', left('🏷️ ' || v.model || ' — ' || private.fmt_money(sale.price), 250),
      'description', left(sale.description, 1800),
      'color', x'1E8E5A'::int,
      'url', case when s.site_url is not null then s.site_url || '#/vente' end,
      'fields', jsonb_build_array(
        jsonb_build_object('name', 'Prix (RP)', 'value', private.fmt_money(sale.price), 'inline', true),
        jsonb_build_object('name', 'Modèle', 'value', left(v.model, 200), 'inline', true),
        jsonb_build_object('name', 'Couleur', 'value', left(v.color, 200), 'inline', true)),
      'footer', jsonb_build_object('text', 'Cliquez sur « Je suis intéressé » sur le site · le message disparaît une fois vendu'));
  end if;
  if v_photo is not null and s.storage_url is not null then
    v_embed := v_embed || jsonb_build_object('image', jsonb_build_object('url', s.storage_url || v_photo));
  end if;
  return jsonb_build_object('username', left(s.site_name, 80),
    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
    'embeds', jsonb_build_array(jsonb_strip_nulls(v_embed)));
end $$;

-- ---------------------------------------------------------------------
--  Le "travailleur" : envoie les messages en attente et traite les réponses
-- ---------------------------------------------------------------------
create or replace function private.discord_worker(p_max integer default 4) returns integer
language plpgsql security definer set search_path = public, private as $$
declare
  s private.discord_settings; j private.discord_outbox; m private.discord_messages; resp record;
  v_sent integer := 0; v_url text; v_payload jsonb; v_req bigint; v_mid text; v_retry numeric; v_err text;
begin
  if to_regclass('net._http_response') is null then return 0; end if;
  select * into s from private.discord_settings where id = 1;
  if not found then return 0; end if;

  -- 1) Traiter les réponses de Discord pour les requêtes déjà envoyées
  for j in select * from private.discord_outbox where state = 'sent' order by id limit 50 for update skip locked loop
    select status_code, content into resp from net._http_response where id = j.request_id;
    if not found then
      if j.sent_at < now() - interval '3 minutes' then
        update private.discord_outbox
           set state = 'queued', next_attempt_at = now(), last_error = 'Aucune réponse de Discord'
         where id = j.id;
        if j.op = 'post' then
          update private.discord_messages set state = 'queued' where id = j.message_ref and state = 'posting';
        end if;
      end if;
      continue;
    end if;

    if (resp.status_code between 200 and 299) or (j.op = 'delete' and resp.status_code = 404) then
      update private.discord_outbox set state = 'done', finished_at = now(), last_error = null where id = j.id;
      if j.op = 'post' and j.message_ref is not null then
        v_mid := null;
        begin v_mid := (resp.content::jsonb) ->> 'id'; exception when others then v_mid := null; end;
        select * into m from private.discord_messages where id = j.message_ref for update;
        if found then
          if m.delete_requested and v_mid is not null then
            update private.discord_messages set state = 'deleting', message_id = v_mid, posted_at = now() where id = m.id;
            insert into private.discord_outbox (slot, op, message_ref, discord_message_id)
            values (m.kind, 'delete', m.id, v_mid);
          elsif m.delete_requested then
            update private.discord_messages
               set state = 'deleted', deleted_at = now(), last_error = 'ID de message inconnu : suppression impossible'
             where id = m.id;
          else
            update private.discord_messages
               set state = 'posted', message_id = v_mid, posted_at = now(),
                   last_error = case when v_mid is null then 'ID de message inconnu' end
             where id = m.id;
          end if;
        end if;
      elsif j.op = 'delete' and j.message_ref is not null then
        update private.discord_messages set state = 'deleted', deleted_at = now() where id = j.message_ref;
      end if;

    elsif resp.status_code is null or resp.status_code = 429 or resp.status_code >= 500 then
      v_retry := 5;
      if resp.status_code = 429 then
        begin v_retry := coalesce(((resp.content::jsonb) ->> 'retry_after')::numeric, 5); exception when others then v_retry := 5; end;
      end if;
      if j.attempts >= 5 then
        update private.discord_outbox
           set state = 'failed', finished_at = now(),
               last_error = 'Discord indisponible ou débit dépassé (code ' || coalesce(resp.status_code::text, 'délai dépassé') || ')'
         where id = j.id;
        update private.discord_messages set state = 'failed', last_error = 'Échec d''envoi vers Discord' where id = j.message_ref;
      else
        select * into m from private.discord_messages where id = j.message_ref;
        if j.op = 'post' and found and m.delete_requested then
          update private.discord_outbox set state = 'cancelled', finished_at = now() where id = j.id;
          update private.discord_messages set state = 'cancelled' where id = m.id;
        else
          update private.discord_outbox
             set state = 'queued', next_attempt_at = now() + make_interval(secs => greatest(v_retry, 1) + j.attempts * 10),
                 last_error = 'Nouvelle tentative (code ' || coalesce(resp.status_code::text, 'délai dépassé') || ')'
           where id = j.id;
          if j.op = 'post' then
            update private.discord_messages set state = 'queued' where id = j.message_ref and state = 'posting';
          end if;
        end if;
      end if;

    else
      v_err := 'Discord a refusé la requête (code ' || resp.status_code || ') : ' || left(coalesce(resp.content, ''), 200);
      update private.discord_outbox set state = 'failed', finished_at = now(), last_error = v_err where id = j.id;
      if j.message_ref is not null then
        update private.discord_messages set state = 'failed', last_error = v_err where id = j.message_ref;
      end if;
    end if;
  end loop;

  -- 2) Envoyer les requêtes prêtes
  for j in select * from private.discord_outbox
            where state = 'queued' and next_attempt_at <= now()
            order by id limit p_max for update skip locked loop
    v_url := case j.slot when 'impound' then s.impound_url when 'sale' then s.sale_url else s.staff_url end;
    if v_url is null then
      update private.discord_outbox set state = 'failed', finished_at = now(), last_error = 'Webhook non configuré' where id = j.id;
      if j.message_ref is not null then
        update private.discord_messages set state = 'failed', last_error = 'Webhook non configuré' where id = j.message_ref;
      end if;
      continue;
    end if;
    begin
      if j.op = 'post' then
        select * into m from private.discord_messages where id = j.message_ref;
        if not found or m.state <> 'queued' or not private.discord_eligible(m.vehicle_id, m.kind) then
          update private.discord_outbox set state = 'cancelled', finished_at = now() where id = j.id;
          if found and m.state = 'queued' then
            update private.discord_messages set state = 'cancelled' where id = m.id;
          end if;
          continue;
        end if;
        v_payload := private.discord_vehicle_payload(m.vehicle_id, m.kind);
        if v_payload is null then
          update private.discord_outbox set state = 'cancelled', finished_at = now() where id = j.id;
          update private.discord_messages set state = 'cancelled' where id = m.id;
          continue;
        end if;
        v_req := net.http_post(url := v_url || '?wait=true', body := v_payload);
        update private.discord_messages set state = 'posting' where id = m.id;
      elsif j.op = 'delete' then
        v_req := net.http_delete(url := v_url || '/messages/' || j.discord_message_id);
      else
        v_req := net.http_post(url := v_url, body := j.payload);
      end if;
      update private.discord_outbox
         set state = 'sent', request_id = v_req, sent_at = now(), attempts = attempts + 1
       where id = j.id;
      v_sent := v_sent + 1;
    exception when others then
      update private.discord_outbox set state = 'failed', finished_at = now(), last_error = left(sqlerrm, 300) where id = j.id;
      if j.message_ref is not null then
        update private.discord_messages set state = 'failed', last_error = left(sqlerrm, 300) where id = j.message_ref;
      end if;
    end;
  end loop;

  -- 3) Ménage
  delete from private.discord_outbox where state in ('done', 'cancelled', 'failed') and finished_at < now() - interval '3 days';
  delete from private.discord_messages
   where state in ('deleted', 'cancelled', 'failed') and coalesce(deleted_at, created_at) < now() - interval '3 days';
  return v_sent;
end $$;

-- Envoi immédiat à la fin de la transaction (les données sont alors complètes : photos comprises)
create or replace function private.discord_kick() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    perform private.discord_worker(4);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_outbox_kick on private.discord_outbox;
create constraint trigger discord_outbox_kick
  after insert on private.discord_outbox
  deferrable initially deferred
  for each row execute function private.discord_kick();

-- ---------------------------------------------------------------------
--  Notifications du personnel (jamais envoyées aux clients)
-- ---------------------------------------------------------------------
create or replace function private.discord_enqueue_staff(
  p_group text, p_title text, p_description text, p_fields jsonb, p_color integer,
  p_link text, p_ping boolean, p_footer text, p_vehicle uuid default null)
returns void
language plpgsql security definer set search_path = public, private as $$
declare s private.discord_settings; v_embed jsonb; v_payload jsonb; v_photo text; v_ping boolean;
begin
  select * into s from private.discord_settings where id = 1;
  if not found or not s.staff_enabled or s.staff_url is null then return; end if;
  if coalesce((s.staff_events ->> p_group)::boolean, true) is not true then return; end if;
  v_ping := p_ping and coalesce(s.mention, '') <> '';
  if p_vehicle is not null and s.storage_url is not null then
    select storage_path into v_photo from public.vehicle_photos
     where vehicle_id = p_vehicle order by position, created_at limit 1;
  end if;
  v_embed := jsonb_strip_nulls(jsonb_build_object(
    'title', left(p_title, 250),
    'description', nullif(left(coalesce(p_description, ''), 1800), ''),
    'color', p_color,
    'url', case when s.site_url is not null and p_link is not null then s.site_url || p_link end,
    'fields', case when p_fields is not null and jsonb_array_length(p_fields) > 0 then p_fields end,
    'thumbnail', case when v_photo is not null then jsonb_build_object('url', s.storage_url || v_photo) end,
    'footer', jsonb_build_object('text', left(coalesce(nullif(p_footer, ''), s.site_name), 200)),
    'timestamp', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  v_payload := jsonb_build_object(
    'username', left(s.site_name, 80),
    'allowed_mentions', case when v_ping then jsonb_build_object('parse', jsonb_build_array('roles', 'users'))
                             else jsonb_build_object('parse', '[]'::jsonb) end,
    'embeds', jsonb_build_array(v_embed));
  if v_ping then v_payload := v_payload || jsonb_build_object('content', s.mention); end if;
  insert into private.discord_outbox (slot, op, payload) values ('staff', 'notify', v_payload);
end $$;

-- Chaque action de l'historique alimente le salon du personnel
create or replace function private.discord_on_log() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_group text; v_title text; v_color integer; v_link text; v_conv uuid; v_role text;
begin
  begin
    v_group := case
      when new.action like 'claim.%' or new.action like 'interest.%' or new.action in ('discount.apply', 'discount.remove') then 'claims'
      when new.action like 'vehicle.%' then 'vehicles'
      when new.action like 'sale.%' then 'sales'
      when new.action like 'staff.%' then 'staff'
      else 'other' end;
    v_title := case new.action
      when 'vehicle.create' then '🚗 Nouveau véhicule en fourrière'
      when 'vehicle.update' then '✏️ Véhicule modifié'
      when 'vehicle.delete' then '🗑️ Véhicule supprimé'
      when 'vehicle.photos' then '🖼️ Photos modifiées'
      when 'vehicle.recovered' then '✅ Véhicule récupéré'
      when 'vehicle.auto_sale' then '⏰ Véhicule à mettre en vente'
      when 'vehicle.archive' then '📦 Véhicule archivé'
      when 'vehicle.unarchive' then '📤 Véhicule désarchivé'
      when 'claim.create' then '🙋 Nouvelle demande de récupération'
      when 'interest.create' then '🏷️ Intérêt pour un véhicule à vendre'
      when 'discount.apply' then '🎟️ Code promo utilisé'
      when 'discount.remove' then '🎟️ Code promo retiré'
      when 'discount.create' then '🎟️ Code promo créé'
      when 'discount.toggle' then '🎟️ Code promo modifié'
      when 'discount.delete' then '🎟️ Code promo supprimé'
      when 'conversation.close' then '🔒 Conversation fermée'
      when 'conversation.delete' then '🗑️ Conversation supprimée'
      when 'sale.list' then '🏷️ Véhicule mis en vente'
      when 'sale.update' then '✏️ Annonce modifiée'
      when 'sale.withdraw' then '↩️ Véhicule retiré de la vente'
      when 'sale.sold' then '💶 Véhicule vendu'
      when 'staff.create' then '👥 Nouveau compte du personnel'
      when 'staff.recruit' then '👥 Nouveau membre du personnel'
      when 'staff.fire' then '🚪 Membre du personnel viré'
      when 'staff.role' then '🔧 Rôle modifié'
      when 'staff.reset_password' then '🔑 Mot de passe réinitialisé'
      when 'pricing.update' then '💰 Tarifs modifiés'
      when 'discord.settings' then '⚙️ Paramètres Discord modifiés'
      else '📋 ' || new.action end;
    v_color := case v_group
      when 'claims' then x'F5B400'::int when 'vehicles' then x'1F5FBF'::int
      when 'sales' then x'1E8E5A'::int when 'staff' then x'7A5CD6'::int else x'6B7785'::int end;
    if new.action = 'claim.create' then
      select id into v_conv from public.conversations where claim_id = new.entity_id;
    end if;
    v_link := case
      when v_conv is not null then '#/messages/' || v_conv
      when new.entity_type = 'conversation' and new.entity_id is not null then '#/messages/' || new.entity_id
      when new.action like 'discount.%' and new.entity_type <> 'conversation' then '#/admin/codes'
      when new.vehicle_id is not null and new.action not like 'vehicle.delete' then '#/admin/vehicules/' || new.vehicle_id
      when new.action like 'staff.%' then '#/admin/personnel'
      when new.action like 'pricing.%' then '#/admin/tarifs'
      else null end;
    v_role := case new.actor_role when 'client' then 'client' when 'employe' then 'employé'
              when 'gerant' then 'gérant' when 'admin' then 'administrateur' else 'système' end;
    perform private.discord_enqueue_staff(
      v_group, v_title, new.summary, null, v_color, v_link,
      new.action in ('claim.create', 'interest.create', 'vehicle.auto_sale'),
      new.actor_name || ' (' || v_role || ')',
      case when new.action = 'vehicle.delete' then null else new.vehicle_id end);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_log_trg on public.activity_logs;
create trigger discord_log_trg after insert on public.activity_logs
  for each row execute function private.discord_on_log();

-- Chaque message d'une conversation alimente le salon du personnel
create or replace function private.discord_on_message() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare v_c public.conversations; v_v public.vehicles; v_client boolean; v_role text;
begin
  begin
    select * into v_c from public.conversations where id = new.conversation_id;
    select * into v_v from public.vehicles where id = v_c.vehicle_id;
    v_client := new.sender_role = 'client';
    v_role := case new.sender_role when 'client' then 'client' when 'employe' then 'employé'
              when 'gerant' then 'gérant' else 'administrateur' end;
    perform private.discord_enqueue_staff(
      case when v_client then 'messages_client' else 'messages_staff' end,
      case when v_client then '💬 Message de ' || new.sender_name else '↩️ Réponse de ' || new.sender_name end,
      new.content,
      jsonb_build_array(
        jsonb_build_object('name', 'Véhicule', 'value', left(coalesce(v_v.plate || ' · ' || v_v.model, 'Inconnu'), 200), 'inline', true),
        jsonb_build_object('name', 'Type', 'value', case v_c.type when 'claim' then 'Récupération' else 'Achat' end, 'inline', true),
        jsonb_build_object('name', 'Client', 'value', left(v_c.client_name, 200), 'inline', true)),
      case when v_client then x'F5B400'::int else x'6B7785'::int end,
      '#/messages/' || new.conversation_id, v_client,
      new.sender_name || ' (' || v_role || ')', null);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_message_trg on public.messages;
create trigger discord_message_trg after insert on public.messages
  for each row when (new.kind = 'text')
  execute function private.discord_on_message();

-- ---------------------------------------------------------------------
--  Déclencheurs : le catalogue se met à jour tout seul
-- ---------------------------------------------------------------------
create or replace function private.discord_on_vehicle() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    if tg_op = 'DELETE' then
      perform private.discord_sync_vehicle(old.id);
    else
      perform private.discord_sync_vehicle(new.id);
    end if;
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_vehicle_trg on public.vehicles;
create trigger discord_vehicle_trg after insert or delete or update of status on public.vehicles
  for each row execute function private.discord_on_vehicle();

create or replace function private.discord_on_vehicle_edit() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    perform private.discord_repost(new.id);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_vehicle_edit_trg on public.vehicles;
create trigger discord_vehicle_edit_trg after update of plate, model, color on public.vehicles
  for each row
  when (old.plate is distinct from new.plate or old.model is distinct from new.model or old.color is distinct from new.color)
  execute function private.discord_on_vehicle_edit();

create or replace function private.discord_on_photo() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    perform private.discord_repost(case when tg_op = 'DELETE' then old.vehicle_id else new.vehicle_id end);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_photo_trg on public.vehicle_photos;
create trigger discord_photo_trg after insert or delete or update of position on public.vehicle_photos
  for each row execute function private.discord_on_photo();

create or replace function private.discord_on_sale_edit() returns trigger
language plpgsql security definer set search_path = public, private as $$
begin
  begin
    perform private.discord_repost(new.vehicle_id);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists discord_sale_edit_trg on public.vehicle_sales;
create trigger discord_sale_edit_trg after update of price, description on public.vehicle_sales
  for each row
  when (old.price is distinct from new.price or old.description is distinct from new.description)
  execute function private.discord_on_sale_edit();

-- ---------------------------------------------------------------------
--  Fonctions du tableau de bord (réservées aux gérants et à l'admin)
-- ---------------------------------------------------------------------
create or replace function public.get_discord_settings() returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s private.discord_settings;
begin
  perform private.require_manager();
  select * into s from private.discord_settings where id = 1;
  return jsonb_build_object(
    'site_name', s.site_name, 'site_url', s.site_url, 'storage_url', s.storage_url, 'mention', s.mention,
    'slots', jsonb_build_object(
      'impound', jsonb_build_object('configured', s.impound_url is not null, 'enabled', s.impound_enabled,
                                    'hint', case when s.impound_url is not null then right(s.impound_url, 4) end),
      'sale', jsonb_build_object('configured', s.sale_url is not null, 'enabled', s.sale_enabled,
                                 'hint', case when s.sale_url is not null then right(s.sale_url, 4) end),
      'staff', jsonb_build_object('configured', s.staff_url is not null, 'enabled', s.staff_enabled,
                                  'hint', case when s.staff_url is not null then right(s.staff_url, 4) end)),
    'staff_events', s.staff_events,
    'status', jsonb_build_object(
      'impound_posted', (select count(*) from private.discord_messages where kind = 'impound' and state in ('posted', 'posting')),
      'sale_posted', (select count(*) from private.discord_messages where kind = 'sale' and state in ('posted', 'posting')),
      'pending', (select count(*) from private.discord_outbox where state in ('queued', 'sent')),
      'failed', (select count(*) from private.discord_outbox where state = 'failed' and finished_at > now() - interval '1 day'),
      'pg_net', to_regclass('net._http_response') is not null),
    'recent', (select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc), '[]'::jsonb)
                 from (select id, slot, op, state, last_error, created_at
                         from private.discord_outbox order by id desc limit 12) t));
end $$;

create or replace function public.save_discord_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare
  v_uid uuid := private.require_manager();
  s private.discord_settings; v_old private.discord_settings;
  k text; v text; v_events jsonb;
  c_keys constant text[] := array['messages_client', 'messages_staff', 'claims', 'vehicles', 'sales', 'staff', 'other'];
begin
  select * into s from private.discord_settings where id = 1 for update;
  v_old := s;
  if p_settings ? 'impound_url' then s.impound_url := private.discord_clean_url(p_settings ->> 'impound_url'); end if;
  if p_settings ? 'sale_url' then s.sale_url := private.discord_clean_url(p_settings ->> 'sale_url'); end if;
  if p_settings ? 'staff_url' then s.staff_url := private.discord_clean_url(p_settings ->> 'staff_url'); end if;
  if p_settings ? 'impound_enabled' then s.impound_enabled := (p_settings ->> 'impound_enabled')::boolean; end if;
  if p_settings ? 'sale_enabled' then s.sale_enabled := (p_settings ->> 'sale_enabled')::boolean; end if;
  if p_settings ? 'staff_enabled' then s.staff_enabled := (p_settings ->> 'staff_enabled')::boolean; end if;
  if p_settings ? 'staff_events' then
    v_events := p_settings -> 'staff_events';
    if jsonb_typeof(v_events) <> 'object' then raise exception 'Paramètres d''événements invalides.'; end if;
    foreach k in array c_keys loop
      if v_events ? k then s.staff_events := s.staff_events || jsonb_build_object(k, (v_events ->> k)::boolean); end if;
    end loop;
  end if;
  if p_settings ? 'mention' then
    v := btrim(coalesce(p_settings ->> 'mention', ''));
    if v <> '' and v !~ '^<@&?[0-9]{15,25}>( <@&?[0-9]{15,25}>){0,4}$' then
      raise exception 'Mention invalide. Exemple : <@&123456789012345678> (identifiant du rôle Discord).';
    end if;
    s.mention := nullif(v, '');
  end if;
  if p_settings ? 'site_name' then
    v := btrim(coalesce(p_settings ->> 'site_name', ''));
    if char_length(v) < 2 or char_length(v) > 80 then raise exception 'Nom du site invalide.'; end if;
    s.site_name := v;
  end if;
  if p_settings ? 'site_url' then
    v := btrim(coalesce(p_settings ->> 'site_url', ''));
    if v <> '' then
      if v !~ '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?$' then raise exception 'Adresse du site invalide.'; end if;
      if right(v, 1) <> '/' then v := v || '/'; end if;
    end if;
    s.site_url := nullif(v, '');
  end if;
  if p_settings ? 'storage_url' then
    v := btrim(coalesce(p_settings ->> 'storage_url', ''));
    if v <> '' and v !~ '^https://[A-Za-z0-9.-]+/storage/v1/object/public/vehicle-photos/$' then
      raise exception 'Adresse du stockage des photos invalide.';
    end if;
    s.storage_url := nullif(v, '');
  end if;

  update private.discord_settings
     set site_name = s.site_name, site_url = s.site_url, storage_url = s.storage_url, mention = s.mention,
         impound_url = s.impound_url, impound_enabled = s.impound_enabled,
         sale_url = s.sale_url, sale_enabled = s.sale_enabled,
         staff_url = s.staff_url, staff_enabled = s.staff_enabled, staff_events = s.staff_events,
         updated_at = now(), updated_by_name = private.display_name(v_uid)
   where id = 1;
  perform private.log_action('discord.settings', 'settings', null, null,
    private.display_name(v_uid) || ' a modifié les paramètres Discord');
  -- Un webhook vient d'être activé ou changé : on publie le catalogue existant
  if (s.impound_url is distinct from v_old.impound_url or s.impound_enabled is distinct from v_old.impound_enabled
      or s.sale_url is distinct from v_old.sale_url or s.sale_enabled is distinct from v_old.sale_enabled) then
    perform public.discord_resync_all();
  end if;
end $$;

-- Aligne Discord sur l'état réel : publie ce qui manque, retire ce qui ne devrait plus y être
create or replace function public.discord_resync_all() returns integer
language plpgsql security definer set search_path = public, private as $$
declare r record; v_n integer := 0;
begin
  perform private.require_manager();
  for r in select id from public.vehicles where status in ('en_fourriere', 'a_vendre') loop
    perform private.discord_sync_vehicle(r.id);
  end loop;
  for r in select id from private.discord_messages
            where state in ('queued', 'posting', 'posted') and not private.discord_eligible(vehicle_id, kind) loop
    perform private.discord_retire(r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Supprime tous les messages du catalogue ('impound', 'sale' ou tous si null)
create or replace function public.discord_purge(p_kind text default null) returns integer
language plpgsql security definer set search_path = public, private as $$
declare r record; v_n integer := 0;
begin
  perform private.require_manager();
  if p_kind is not null and p_kind not in ('impound', 'sale') then raise exception 'Catégorie invalide.'; end if;
  for r in select id from private.discord_messages
            where state in ('queued', 'posting', 'posted') and (p_kind is null or kind = p_kind) loop
    perform private.discord_retire(r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.discord_send_test(p_slot text) returns void
language plpgsql security definer set search_path = public, private as $$
declare s private.discord_settings; v_url text; v_uid uuid := private.require_manager();
begin
  if p_slot not in ('impound', 'sale', 'staff') then raise exception 'Webhook inconnu.'; end if;
  select * into s from private.discord_settings where id = 1;
  v_url := case p_slot when 'impound' then s.impound_url when 'sale' then s.sale_url else s.staff_url end;
  if v_url is null then raise exception 'Enregistrez d''abord l''URL de ce webhook.'; end if;
  insert into private.discord_outbox (slot, op, payload) values (p_slot, 'test', jsonb_build_object(
    'username', left(s.site_name, 80),
    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb),
    'embeds', jsonb_build_array(jsonb_build_object(
      'title', '✅ Test réussi',
      'description', 'Le webhook « ' || case p_slot when 'impound' then 'véhicules en fourrière' when 'sale' then 'véhicules à vendre'
                                   else 'notifications du personnel' end || ' » est bien connecté.',
      'color', x'1E8E5A'::int,
      'footer', jsonb_build_object('text', 'Test lancé par ' || private.display_name(v_uid))))));
end $$;

-- Force l'envoi et la lecture des réponses (bouton "Actualiser" du tableau de bord)
create or replace function public.discord_run_worker() returns integer
language plpgsql security definer set search_path = public, private as $$
begin
  perform private.require_manager();
  return private.discord_worker(8);
end $$;

-- >>>>>>>>>> parts/07_security.sql
-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 7/8 : sécurité (Row Level Security), droits et vue
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
grant execute on function private.is_police() to anon, authenticated;

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
alter table public.sale_options               enable row level security;
alter table public.seizures                   enable row level security;
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

drop policy if exists sale_options_select on public.sale_options;
create policy sale_options_select on public.sale_options for select to authenticated
  using (active or private.is_manager());

drop policy if exists seizures_select on public.seizures;
create policy seizures_select on public.seizures for select to authenticated
  using (private.is_staff() or private.is_police());

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
  s.discount_code as sale_discount_code, s.discount_percent as sale_discount_percent,
  case when private.is_manager() then v.planned_price end as planned_price,
  case when private.is_manager() then v.planned_description end as planned_description,
  s.promo_percent as sale_promo_percent,
  coalesce(s.options, '[]'::jsonb) as sale_options, coalesce(s.options_total, 0) as sale_options_total,
  case when s.promo_percent is null then s.price else round(s.price * (100 - s.promo_percent) / 100) end as sale_effective_price
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
                           'messages', 'notifications', 'activity_logs', 'vehicles_ext', 'discount_codes', 'discount_redemptions',
                           'sale_options', 'seizures'] loop
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

grant select on public.pricing_settings to anon, authenticated;
grant select on public.profiles, public.staff, public.vehicles, public.vehicle_photos,
                public.vehicle_sales, public.claims, public.conversations,
                public.conversation_participants, public.messages, public.notifications,
                public.activity_logs, public.vehicles_ext, public.sale_options, public.seizures to authenticated;
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
    'remove_conversation_discount', 'list_discount_codes', 'list_discount_redemptions',
    'create_sale_option', 'set_sale_option_active', 'delete_sale_option', 'list_sale_options', 'active_sale_options',
    'set_planned_sale', 'buy_vehicle_now', 'admin_force_for_sale',
    'create_police_account', 'list_police_accounts', 'revoke_police_account',
    'create_seizure', 'mark_seizure_recovered', 'delete_seizure', 'get_seizure_stats'];
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

-- >>>>>>>>>> parts/08_storage_realtime.sql
-- =====================================================================
--  FOURRIÈRE DE BELLE ROCHE — Base de données
--  Fichier 8/8 : stockage des photos et temps réel
-- =====================================================================

-- Bucket public (lecture des photos par tous), écriture réservée au personnel
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vehicle-photos', 'vehicle-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists vehicle_photos_staff_insert on storage.objects;
create policy vehicle_photos_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'vehicle-photos' and private.is_staff());

drop policy if exists vehicle_photos_staff_select on storage.objects;
create policy vehicle_photos_staff_select on storage.objects for select to authenticated
  using (bucket_id = 'vehicle-photos' and private.is_staff());

drop policy if exists vehicle_photos_staff_delete on storage.objects;
create policy vehicle_photos_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'vehicle-photos' and private.is_staff());

-- Temps réel (Supabase Realtime) : les règles RLS s'appliquent aussi aux abonnements
do $$
declare t text;
begin
  foreach t in array array['messages', 'conversations', 'notifications', 'vehicles', 'claims',
                           'vehicle_sales', 'profiles', 'staff'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- Recharge le cache de l'API pour qu'elle voie les nouvelles fonctions
notify pgrst, 'reload schema';
