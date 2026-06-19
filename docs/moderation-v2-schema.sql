-- ============================================================
--  Moderació v2 — Reportes humanos con dedup, categorías,
--  ventanas temporales y progresión de 9 niveles.
--
--  Ejecuta este archivo entero en el SQL editor de Supabase.
--  REEMPLAZA la lógica del trigger anterior (handle_chat_report
--  y _apply_moderation_step) pero conserva las tablas existentes
--  `device_moderation` y `account_moderation` (les añade columnas).
-- ============================================================

-- ---------- 0) Nuevas columnas en room_chat_flags ----------
alter table public.room_chat_flags
  add column if not exists category text not null default 'conduct'
    check (category in ('conduct', 'foul_play')),
  add column if not exists counted  boolean not null default true,
  add column if not exists strike_awarded boolean not null default false;

create index if not exists idx_room_chat_flags_target_cat_time
  on public.room_chat_flags(target_device_id, category, created_at desc)
  where counted = true;

-- ---------- 1) Helper: inferir categoría desde texto libre ----------
-- (Por compatibilidad con reportes antiguos que solo traen `reason`.)
create or replace function public._infer_report_category(_reason text)
returns text
language sql
immutable
as $$
  select case
    when _reason is null then 'conduct'
    when lower(_reason) ~ '(slow|lent|len ?to|alentar|trampa|cheat|colud|colud|colluding|colusi|farm|sabote|sabotag|juego sucio|joc brut|foul|farmeo|abus)'
      then 'foul_play'
    else 'conduct'
  end;
$$;

-- ---------- 2) Añadir columnas a device_moderation / account_moderation ----------
alter table public.device_moderation
  add column if not exists strikes int not null default 0;
alter table public.account_moderation
  add column if not exists strikes int not null default 0;

-- ---------- 3) Tabla de auditoría de strikes (idempotencia ventanas) ----------
create table if not exists public.moderation_strike_log (
  id            bigserial primary key,
  scope         text not null check (scope in ('device','account')),
  key_value     text not null,                  -- device_id o user_id
  source        text not null,                  -- 'window_day' | 'window_7d' | 'window_30d' | 'ai'
  category      text,                           -- 'conduct' | 'foul_play' | null (ai)
  window_key    text not null,                  -- p.e. 'day:2026-06-18:conduct'
  strike_index  int  not null,                  -- nº de strike resultante (1..9)
  awarded_at    timestamptz not null default now(),
  unique (scope, key_value, window_key)
);

grant select on public.moderation_strike_log to authenticated;
grant all    on public.moderation_strike_log to service_role;
alter table public.moderation_strike_log enable row level security;
drop policy if exists "strike_log read all" on public.moderation_strike_log;
create policy "strike_log read all"
  on public.moderation_strike_log for select using (true);

-- ---------- 4) Aplicar 1 strike oficial con progresión de 9 niveles ----------
-- 1,2 → aviso  · 3 → ban 24h
-- 4,5 → aviso  · 6 → ban 24h
-- 7,8 → aviso  · 9 → ban permanente
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
  block_in_cycle := ceil(new_strikes::numeric / 3.0)::int;   -- 1..3
  step_in_block  := ((new_strikes - 1) % 3) + 1;             -- 1,2,3

  if new_strikes = 9 then
    rec.permanent_ban := true;
    rec.banned_until  := null;
    msg := 'Aviso del Administrador: Tu cuenta ha sido bloqueada permanentemente (falta 9/9).';
  elsif step_in_block = 3 then
    -- strikes 3 o 6 → baneo temporal 24h
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
end;
$$;

-- ---------- 5) Conceder strike por ventana temporal (con idempotencia) ----------
create or replace function public._maybe_strike_window(
  _scope     text,        -- 'device' | 'account'
  _key_val   text,
  _category  text,
  _source    text,        -- 'window_day' | 'window_7d' | 'window_30d'
  _window_key text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tbl   text;
  kcol  text;
  cur_strikes int;
begin
  -- ¿ya se concedió este strike por esta ventana?
  if exists (
    select 1 from public.moderation_strike_log
    where scope = _scope and key_value = _key_val and window_key = _window_key
  ) then
    return;
  end if;

  if _scope = 'device' then
    tbl := 'device_moderation'; kcol := 'device_id';
  else
    tbl := 'account_moderation'; kcol := 'user_id';
  end if;

  perform public._apply_official_strike(tbl, kcol, _key_val, _source, _category);

  execute format(
    'select coalesce(strikes,0) from public.%I where %I = $1',
    tbl, kcol
  ) into cur_strikes using _key_val;

  insert into public.moderation_strike_log
    (scope, key_value, source, category, window_key, strike_index)
  values (_scope, _key_val, _source, _category, _window_key, cur_strikes)
  on conflict do nothing;
end;
$$;

-- ---------- 6) Evaluar ventanas para un target+categoría ----------
create or replace function public._evaluate_windows(
  _scope    text,
  _key_val  text,
  _target_device text,
  _target_user   uuid,
  _category text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  distinct_today int;
  distinct_7d    int;
  distinct_30d   int;
  day_key   text;
begin
  -- Cuenta REPORTERS DISTINTOS sobre el dispositivo objetivo en la categoría,
  -- usando solo flags con counted=true (los humanos; los flags 'openai-moderation'
  -- se contabilizan como una sola fuente humana neutra y aún así dedupean).
  with src as (
    select reporter_device_id, created_at
      from public.room_chat_flags
     where target_device_id = _target_device
       and category = _category
       and counted = true
       and reporter_device_id <> 'openai-moderation'
       and created_at >= now() - interval '30 days'
  )
  select
    (select count(distinct reporter_device_id) from src
       where created_at::date = current_date),
    (select count(distinct reporter_device_id) from src
       where created_at >= now() - interval '7 days'),
    (select count(distinct reporter_device_id) from src
       where created_at >= now() - interval '30 days')
  into distinct_today, distinct_7d, distinct_30d;

  day_key := to_char(current_date, 'YYYY-MM-DD');

  if distinct_today >= 3 then
    perform public._maybe_strike_window(
      _scope, _key_val, _category, 'window_day',
      format('day:%s:%s', day_key, _category)
    );
  end if;

  if distinct_7d >= 5 then
    perform public._maybe_strike_window(
      _scope, _key_val, _category, 'window_7d',
      format('week:%s:%s', to_char(date_trunc('week', now()), 'IYYY-IW'), _category)
    );
  end if;

  if distinct_30d >= 10 then
    perform public._maybe_strike_window(
      _scope, _key_val, _category, 'window_30d',
      format('month:%s:%s', to_char(date_trunc('month', now()), 'YYYY-MM'), _category)
    );
  end if;
end;
$$;

-- ---------- 7) Trigger principal: reemplaza al anterior ----------
create or replace function public.handle_chat_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cat text;
  is_dup boolean;
  target_user uuid;
begin
  -- Categoría: usa la columna si viene; si no, infierela del `reason`.
  cat := coalesce(new.category, public._infer_report_category(new.reason));
  if cat not in ('conduct','foul_play') then cat := 'conduct'; end if;

  -- ─── REGLA DE ORO: dedup por (reporter, target, categoría) ───
  -- Si ya hay un reporte previo del mismo reporter contra el mismo target
  -- en la misma categoría dentro de la MISMA partida o el MISMO día natural,
  -- esta fila NO cuenta para las ventanas (sigue guardada para auditoría).
  is_dup := false;
  if new.reporter_device_id <> 'openai-moderation' then
    select exists (
      select 1 from public.room_chat_flags f
       where f.id <> new.id
         and f.reporter_device_id = new.reporter_device_id
         and f.target_device_id   = new.target_device_id
         and coalesce(f.category, public._infer_report_category(f.reason)) = cat
         and (f.room_id = new.room_id
              or f.created_at::date = new.created_at::date)
    ) into is_dup;
  end if;

  update public.room_chat_flags
     set category = cat,
         counted  = (not is_dup)
   where id = new.id;

  if is_dup then
    return new;
  end if;

  -- Resuelve user_id objetivo (cuenta vinculada al dispositivo reportado)
  select coalesce(rp.profile_user_id, al.user_id)
    into target_user
    from (select 1) _
    left join public.room_players rp
      on rp.room_id = new.room_id
     and rp.device_id = new.target_device_id
    left join public.account_links al
      on al.device_id = new.target_device_id
    limit 1;

  -- ─── Canal rápido IA: cada flag de OpenAI = +1 strike directo ───
  if new.reporter_device_id = 'openai-moderation' then
    perform public._apply_official_strike(
      'device_moderation', 'device_id', new.target_device_id,
      'ai', cat
    );
    insert into public.moderation_strike_log
      (scope, key_value, source, category, window_key, strike_index)
    select 'device', new.target_device_id, 'ai', cat,
           format('ai:%s', new.id),
           coalesce((select strikes from public.device_moderation
                       where device_id = new.target_device_id), 1)
    on conflict do nothing;

    if target_user is not null then
      perform public._apply_official_strike(
        'account_moderation', 'user_id', target_user::text,
        'ai', cat
      );
      insert into public.moderation_strike_log
        (scope, key_value, source, category, window_key, strike_index)
      select 'account', target_user::text, 'ai', cat,
             format('ai:%s', new.id),
             coalesce((select strikes from public.account_moderation
                         where user_id = target_user), 1)
      on conflict do nothing;
    end if;

    return new;
  end if;

  -- ─── Canal humano: evaluar ventanas (1d / 7d / 30d) ───
  perform public._evaluate_windows(
    'device', new.target_device_id,
    new.target_device_id, target_user, cat
  );

  if target_user is not null then
    perform public._evaluate_windows(
      'account', target_user::text,
      new.target_device_id, target_user, cat
    );
  end if;

  return new;
end;
$$;

-- (Re)engancha el trigger (idempotente).
drop trigger if exists trg_chat_report on public.room_chat_flags;
create trigger trg_chat_report
  after insert on public.room_chat_flags
  for each row execute function public.handle_chat_report();

-- ---------- 8) Limpia la función vieja (ya no se usa) ----------
-- La dejamos opcionalmente; si quieres eliminarla, descomenta:
-- drop function if exists public._apply_moderation_step(text, text, text);

-- ============================================================
--  FIN. Tras ejecutar:
--   * Los reportes humanos siguen guardándose siempre (auditoría).
--   * Solo los counted=true alimentan las ventanas.
--   * Los strikes oficiales (1..9) viven en *.strikes y disparan
--     baneos en faltas 3 y 6 (24h) y bloqueo permanente en la 9.
--   * El canal IA suma 1 strike por cada flag automático.
-- ============================================================