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
