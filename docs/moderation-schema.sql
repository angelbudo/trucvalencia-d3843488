-- ============================================================
--  Sistema de moderación acumulativa por device_id + user_id
--  Ejecutar en el SQL editor de Supabase.
--  Cierra la brecha de que un baneado pueda esquivar el castigo
--  iniciando sesión en otro dispositivo: el contador se duplica
--  en una tabla `account_moderation` ligada al user_id real.
-- ============================================================

-- ---------- TABLA 1: moderación por dispositivo ----------
create table if not exists public.device_moderation (
  device_id      text primary key,
  report_count   int  not null default 0,
  ban_count      int  not null default 0,
  banned_until   timestamptz,
  permanent_ban  boolean not null default false,
  last_notice    text,
  last_notice_at timestamptz,
  updated_at     timestamptz not null default now()
);

grant select on public.device_moderation to anon, authenticated;
grant all    on public.device_moderation to service_role;

alter table public.device_moderation enable row level security;

drop policy if exists "device_moderation read all" on public.device_moderation;
create policy "device_moderation read all"
  on public.device_moderation for select
  using (true);

-- ---------- TABLA 2: moderación por cuenta (user_id) ----------
create table if not exists public.account_moderation (
  user_id        uuid primary key,
  report_count   int  not null default 0,
  ban_count      int  not null default 0,
  banned_until   timestamptz,
  permanent_ban  boolean not null default false,
  last_notice    text,
  last_notice_at timestamptz,
  updated_at     timestamptz not null default now()
);

grant select on public.account_moderation to anon, authenticated;
grant all    on public.account_moderation to service_role;

alter table public.account_moderation enable row level security;

drop policy if exists "account_moderation read all" on public.account_moderation;
create policy "account_moderation read all"
  on public.account_moderation for select
  using (true);

-- ---------- Función auxiliar: aplica una notificación de moderación ----------
create or replace function public._apply_moderation_step(
  _table   text,
  _key_col text,
  _key_val text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  msg text;
  sql_text text;
begin
  -- Carga o crea la fila
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

  rec.report_count := rec.report_count + 1;

  if rec.report_count >= 3 then
    rec.ban_count := rec.ban_count + 1;
    rec.report_count := 0;
    if rec.ban_count >= 3 then
      rec.permanent_ban := true;
      rec.banned_until := null;
      msg := 'Aviso del Administrador: Tu cuenta ha sido bloqueada permanentemente por reincidencia.';
    else
      rec.banned_until := now() + interval '24 hours';
      msg := format(
        'Aviso del Administrador: Tu cuenta está suspendida por 24 horas. Te quedan %s baneos temporales antes del bloqueo permanente.',
        3 - rec.ban_count
      );
    end if;
  else
    if rec.ban_count > 0 then
      msg := format(
        'Aviso del Administrador: Has sido reportado. Te quedan %s reportes para ser suspendido 24 horas. Te quedan %s baneos antes del bloqueo permanente.',
        3 - rec.report_count, 3 - rec.ban_count
      );
    else
      msg := format(
        'Aviso del Administrador: Has sido reportado. Te quedan %s reportes para ser suspendido 24 horas. (Baneos consumidos: %s/3).',
        3 - rec.report_count, rec.ban_count
      );
    end if;
  end if;

  execute format(
    'update public.%I set
       report_count   = $1,
       ban_count      = $2,
       banned_until   = $3,
       permanent_ban  = $4,
       last_notice    = $5,
       last_notice_at = now(),
       updated_at     = now()
     where %I = $6',
    _table, _key_col
  ) using rec.report_count, rec.ban_count, rec.banned_until,
          rec.permanent_ban, msg, _key_val;
end;
$$;

-- ---------- Trigger principal: cada report puntúa device + cuenta ----------
create or replace function public.handle_chat_report()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_user uuid;
begin
  -- 1) Penaliza al dispositivo reportado
  perform public._apply_moderation_step(
    'device_moderation', 'device_id', new.target_device_id
  );

  -- 2) Si el dispositivo está vinculado a una cuenta (por room_players
  --    o account_links), penaliza también esa cuenta para que el baneo
  --    le siga aunque cambie de móvil.
  select coalesce(rp.profile_user_id, al.user_id)
    into target_user
    from (select 1) _
    left join public.room_players rp
      on rp.room_id = new.room_id
     and rp.device_id = new.target_device_id
    left join public.account_links al
      on al.device_id = new.target_device_id
    limit 1;

  if target_user is not null then
    perform public._apply_moderation_step(
      'account_moderation', 'user_id', target_user::text
    );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_chat_report on public.room_chat_flags;
create trigger trg_chat_report
  after insert on public.room_chat_flags
  for each row execute function public.handle_chat_report();

-- ---------- Realtime para que el cliente reciba el aviso al instante ----------
do $$
begin
  begin
    alter publication supabase_realtime add table public.device_moderation;
  exception when duplicate_object then null; end;
  begin
    alter publication supabase_realtime add table public.account_moderation;
  exception when duplicate_object then null; end;
end $$;