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
