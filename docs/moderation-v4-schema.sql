-- ============================================================
--  Moderació v4 — Bandeja del administrador (alertes manuals).
--
--  Afig:
--    (a) Taula `admin_alerts` per a notificacions automàtiques i
--        apel·lacions enviades pels usuaris.
--    (b) Modifica `_apply_official_strike` perquè genere una
--        alerta automàtica quan un usuari arriba a la FALTA 6
--        (2n baneig temporal → entra en fase de seguiment manual
--        abans del baneig definitiu de la falta 9).
--    (c) RPC `submit_moderation_appeal` perquè qualsevol jugador
--        puga enviar una apel·lació des de l'app (cartel de baneig).
--
--  Executa aquest fitxer SENCER al SQL Editor de Supabase DESPRÉS
--  de v2 i v3.
-- ============================================================

-- ---------- 1) Taula `admin_alerts` ----------
create table if not exists public.admin_alerts (
  id              bigserial primary key,
  kind            text not null check (kind in ('strike6','appeal','other')),
  target_user_id  uuid,                 -- compte afectat (si es coneix)
  target_device_id text,                -- dispositiu afectat (si es coneix)
  scope           text,                 -- 'device' | 'account' (per a strike6)
  category        text,                 -- 'conduct' | 'foul_play' | 'leaver' | null
  subject         text,
  content         text not null,
  metadata        jsonb not null default '{}'::jsonb,
  read_at         timestamptz,
  resolved_at     timestamptz,
  created_at      timestamptz not null default now()
);

create index if not exists idx_admin_alerts_created
  on public.admin_alerts(created_at desc);
create index if not exists idx_admin_alerts_kind_unread
  on public.admin_alerts(kind, created_at desc)
  where read_at is null;

-- GRANTS (Data API): només l'admin (via service_role / panell) llegirà
-- aquesta taula. Permetem INSERT als usuaris autenticats i anònims via
-- la RPC `submit_moderation_appeal` (security definer); no calen grants
-- directes a anon/authenticated sobre la taula.
grant all on public.admin_alerts to service_role;
grant usage, select on sequence public.admin_alerts_id_seq to service_role;

alter table public.admin_alerts enable row level security;

-- Per defecte: ningú llig ni escriu directament des del client.
-- L'admin accedeix amb service_role (panell). Si en el futur s'afig un
-- rol `admin` via `has_role`, es pot afegir aquesta política:
--   create policy "admin can read alerts" on public.admin_alerts
--     for select to authenticated using (public.has_role(auth.uid(),'admin'));

-- ---------- 2) `_apply_official_strike` v4 — alerta a la falta 6 ----------
create or replace function public._apply_official_strike(
  _table    text,
  _key_col  text,
  _key_val  text,
  _source   text,
  _category text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  msg text;
  new_strikes int;
  block_in_cycle int;
  step_in_block  int;
  alert_scope text;
  alert_user  uuid;
  alert_device text;
begin
  execute format(
    'insert into public.%I(%I) values ($1) on conflict (%I) do nothing',
    _table, _key_col, _key_col
  ) using _key_val;

  execute format(
    'select * from public.%I where %I = $1 for update',
    _table, _key_col
  ) into rec using _key_val;

  if rec.permanent_ban then
    return;
  end if;

  new_strikes := least(coalesce(rec.strikes, 0) + 1, 9);
  block_in_cycle := ceil(new_strikes::numeric / 3.0)::int;
  step_in_block  := ((new_strikes - 1) % 3) + 1;

  if new_strikes = 9 then
    rec.permanent_ban := true;
    rec.banned_until  := null;
    msg := 'Aviso del Administrador: Tu cuenta ha sido bloqueada permanentemente (falta 9/9).';
  elsif step_in_block = 3 then
    rec.ban_count    := coalesce(rec.ban_count, 0) + 1;
    rec.banned_until := now() + interval '24 hours';
    msg := format(
      'Aviso del Administrador: Has acumulado %s faltas oficiales. Suspendido 24 horas. (Bloque %s/3).',
      new_strikes, block_in_cycle
    );
  else
    msg := format(
      'Aviso del Administrador: Falta oficial %s/9 registrada (motivo: %s). Próxima suspensión a las %s faltas.',
      new_strikes, coalesce(_source,'-'), block_in_cycle * 3
    );
  end if;

  execute format(
    'update public.%I set
       strikes        = $1,
       ban_count      = $2,
       banned_until   = $3,
       permanent_ban  = $4,
       last_notice    = $5,
       last_notice_at = now(),
       updated_at     = now()
     where %I = $6',
    _table, _key_col
  ) using new_strikes, rec.ban_count, rec.banned_until,
          rec.permanent_ban, msg, _key_val;

  -- ─── ALERTA AUTOMÀTICA A LA FALTA 6 (2n baneig temporal) ───
  if new_strikes = 6 then
    if _table = 'account_moderation' then
      alert_scope := 'account';
      begin
        alert_user := _key_val::uuid;
      exception when others then
        alert_user := null;
      end;
      alert_device := null;
    else
      alert_scope := 'device';
      alert_user := null;
      alert_device := _key_val;
    end if;

    insert into public.admin_alerts
      (kind, target_user_id, target_device_id, scope, category, subject, content, metadata)
    values (
      'strike6',
      alert_user,
      alert_device,
      alert_scope,
      _category,
      'Seguiment manual: falta 6 assolida',
      format(
        'El usuario [%s] ha alcanzado la Falta 6 (2º baneo temporal). Su historial de reincidencia es alto y ha entrado en fase de seguimiento manual antes del baneo definitivo.',
        _key_val
      ),
      jsonb_build_object(
        'scope', alert_scope,
        'key_value', _key_val,
        'strikes', new_strikes,
        'block', block_in_cycle,
        'source', coalesce(_source,'-'),
        'category', _category,
        'banned_until', rec.banned_until
      )
    );
  end if;
end;
$$;

-- ---------- 3) RPC pública: enviar apel·lació ----------
-- L'usuari (autenticat o anònim per dispositiu) envia una reclamació
-- que arriba a la bandeja de l'administrador. Validacions bàsiques
-- (longitud, throttling) per evitar abús.
create or replace function public.submit_moderation_appeal(
  p_device_id text,
  p_user_id   uuid,
  p_reason    text,
  p_message   text
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  recent_count int;
  body text;
  new_id bigint;
begin
  if coalesce(length(trim(p_message)), 0) < 5 then
    raise exception 'Missatge massa curt';
  end if;
  if length(p_message) > 2000 then
    raise exception 'Missatge massa llarg';
  end if;

  -- Throttle: màx 3 apel·lacions per dispositiu o usuari les últimes 24h.
  select count(*) into recent_count
    from public.admin_alerts
   where kind = 'appeal'
     and created_at > now() - interval '24 hours'
     and (
       (p_device_id is not null and target_device_id = p_device_id)
       or (p_user_id is not null and target_user_id = p_user_id)
     );
  if recent_count >= 3 then
    raise exception 'Límit d''apel·lacions assolit. Torna a provar més tard.';
  end if;

  body := format(
    'APEL·LACIÓ — usuari[%s] dispositiu[%s] motiu[%s]%s%s',
    coalesce(p_user_id::text, '-'),
    coalesce(p_device_id, '-'),
    coalesce(p_reason, '-'),
    E'\n\n',
    p_message
  );

  insert into public.admin_alerts
    (kind, target_user_id, target_device_id, scope, category, subject, content, metadata)
  values (
    'appeal',
    p_user_id,
    p_device_id,
    case when p_user_id is not null then 'account' else 'device' end,
    null,
    'Apel·lació d''un usuari (DSA)',
    body,
    jsonb_build_object(
      'reason', p_reason,
      'submitted_at', now()
    )
  )
  returning id into new_id;

  return new_id;
end;
$$;

revoke all on function public.submit_moderation_appeal(text, uuid, text, text) from public;
grant execute on function public.submit_moderation_appeal(text, uuid, text, text) to anon, authenticated;

-- ============================================================
--  FIN v4.
--  · `admin_alerts` és la bandeja del super-admin (service_role).
--  · `_apply_official_strike` insereix una alerta automàtica quan
--    es marca la falta 6 (seguiment manual abans del ban permanent).
--  · `submit_moderation_appeal` permet als jugadors enviar apel·lacions
--    DSA des del cartel de baneig (botó "Apel·lar Sanció").
-- ============================================================