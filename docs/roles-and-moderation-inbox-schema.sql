-- ============================================================================
-- Roles + bandeja de moderació
-- Executar al SQL Editor de Supabase. Idempotent (utilitza IF NOT EXISTS).
-- Després, executar manualment:
--   INSERT INTO public.user_roles (user_id, role)
--   VALUES ('<EL_TEU_UUID>', 'admin');
-- per donar-te a tu mateix el rol admin.
-- ============================================================================

-- 1) Enum de rols ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'app_role') then
    create type public.app_role as enum ('user','moderator','admin');
  end if;
end $$;

-- 2) Taula user_roles (mai a profiles!) -------------------------------------
create table if not exists public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.app_role not null default 'user',
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users(id),
  unique (user_id, role)
);

grant select on public.user_roles to authenticated;
grant all    on public.user_roles to service_role;

alter table public.user_roles enable row level security;

-- 3) Funció SECURITY DEFINER per evitar recursió RLS -------------------------
create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_roles
    where user_id = _user_id and role = _role
  );
$$;

grant execute on function public.has_role(uuid, public.app_role) to authenticated, anon;

-- 4) Policies user_roles ----------------------------------------------------
drop policy if exists "users read own roles"   on public.user_roles;
drop policy if exists "admins read all roles"  on public.user_roles;
drop policy if exists "admins manage all roles" on public.user_roles;

create policy "users read own roles"
  on public.user_roles for select to authenticated
  using (user_id = auth.uid());

create policy "admins read all roles"
  on public.user_roles for select to authenticated
  using (public.has_role(auth.uid(),'admin'));

create policy "admins manage all roles"
  on public.user_roles for all to authenticated
  using (public.has_role(auth.uid(),'admin'))
  with check (public.has_role(auth.uid(),'admin'));

-- 5) Taula d'auditoria -------------------------------------------------------
create table if not exists public.room_chat_flags_audit (
  id bigserial primary key,
  flag_id bigint not null,
  room_id uuid,
  target_device_id text,
  reporter_device_id text,
  message_id bigint,
  message_text text,
  reason text,
  decision text not null check (decision in ('pending','approved','dismissed','forgiven')),
  decided_by uuid references auth.users(id),
  moderator_tag text,
  moderator_note text,
  decided_at timestamptz not null default now(),
  flag_created_at timestamptz,
  flag_expires_at timestamptz
);

grant select, insert on public.room_chat_flags_audit to authenticated;
grant all on public.room_chat_flags_audit to service_role;
grant usage, select on sequence public.room_chat_flags_audit_id_seq to authenticated;

alter table public.room_chat_flags_audit enable row level security;

drop policy if exists "moderators read audit" on public.room_chat_flags_audit;
drop policy if exists "moderators insert audit" on public.room_chat_flags_audit;

create policy "moderators read audit"
  on public.room_chat_flags_audit for select to authenticated
  using (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'));

create policy "moderators insert audit"
  on public.room_chat_flags_audit for insert to authenticated
  with check (
    decided_by = auth.uid()
    and (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'))
  );

-- 6) RLS sobre room_chat_flags per a moderadors ------------------------------
-- (l'edge function fa servir service_role; aquestes policies són per al client)
alter table public.room_chat_flags enable row level security;

grant select, update on public.room_chat_flags to authenticated;

drop policy if exists "moderators read flags"   on public.room_chat_flags;
drop policy if exists "moderators update flags" on public.room_chat_flags;

create policy "moderators read flags"
  on public.room_chat_flags for select to authenticated
  using (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'));

create policy "moderators update flags"
  on public.room_chat_flags for update to authenticated
  using (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'))
  with check (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'));

-- Permetre als moderadors llegir el text de room_text_chat per mostrar context
grant select on public.room_text_chat to authenticated;
drop policy if exists "moderators read text chat" on public.room_text_chat;
create policy "moderators read text chat"
  on public.room_text_chat for select to authenticated
  using (public.has_role(auth.uid(),'admin') or public.has_role(auth.uid(),'moderator'));

-- ============================================================================
-- LLEST. Recorda fer l'INSERT del teu UUID com a 'admin' (vegeu capçalera).
-- ============================================================================