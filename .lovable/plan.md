# Sistema de roles y bandeja de moderació integrada

## Objectiu
Substituir l'actual `/admin/moderacio` (protegida per contrasenya local) per un sistema real de rols (`user` / `moderator` / `admin`) basat en Supabase, amb ruta protegida i una bandeja d'entrada estil correu adaptada a mòbil i escriptori.

## 1. Base de dades (migració SQL)

Crear migració `docs/roles-and-moderation-inbox-schema.sql`:

```sql
-- Enum de rols
create type public.app_role as enum ('user','moderator','admin');

-- Taula user_roles (mai al perfil)
create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role app_role not null default 'user',
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users(id),
  unique (user_id, role)
);

grant select on public.user_roles to authenticated;
grant all on public.user_roles to service_role;
alter table public.user_roles enable row level security;

-- Funció security definer (evita recursió RLS)
create or replace function public.has_role(_user_id uuid, _role app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _user_id and role = _role)
$$;

-- Policies
create policy "users read own roles" on public.user_roles
  for select to authenticated using (user_id = auth.uid());
create policy "admins read all roles" on public.user_roles
  for select to authenticated using (public.has_role(auth.uid(),'admin'));
create policy "admins manage roles" on public.user_roles
  for all to authenticated using (public.has_role(auth.uid(),'admin'))
  with check (public.has_role(auth.uid(),'admin'));

-- Seed: el meu usuari com a admin (substituir <UUID> manualment a Supabase)
-- insert into public.user_roles (user_id, role) values ('<UUID>', 'admin');
```

L'usuari haurà d'executar el `INSERT` final amb el seu propi `auth.users.id`. Li explicaré com fer-ho al final.

## 2. Server functions (`src/online/moderation.functions.ts`)

Noves functions amb `requireSupabaseAuth` que verifiquen rol via `has_role`:

- `getMyRole()` → retorna `'user' | 'moderator' | 'admin'`.
- `listChatFlags({ status })` → llegeix `room_chat_flags` amb join a `room_chat` per obtenir el text del missatge. Només per `moderator`/`admin`.
- `listChatFlagsAudit({ flagId? })` → llegeix `room_chat_flags_audit`.
- `decideChatFlag({ flagId, decision: 'approved'|'dismissed'|'pending', note? })` → actualitza `room_chat_flags` + insereix a `room_chat_flags_audit` amb `decided_by = userId`, `decided_at = now()`. `moderator` i `admin` poden usar-la.
- `forgivePoints({ targetDeviceId })` → només `admin`. Marca flags aprovats com `dismissed` per anul·lar pes en la finestra de shadow ban.

Cada handler comprova rol abans d'operar. Carrega `supabaseAdmin` dins el handler només quan calgui per llegir dades cross-user.

## 3. Hook de rol (`src/hooks/useMyRole.ts`)

```ts
export function useMyRole(): { role: AppRole | null; isAdmin: boolean; isModerator: boolean; ready: boolean }
```

Crida `getMyRole` via `useServerFn` + `useQuery`. Cau a `'user'` quan no hi ha sessió.

## 4. Route guard

Reescriure `src/pages/admin/Moderacio.tsx`:
- Treure `useAdminPassword` i el formulari de contrasenya.
- En montar, esperar `useAuth().ready` + `useMyRole()`. Si `role !== 'admin' && role !== 'moderator'` → `navigate('/', { replace: true })`.
- Mentre carrega, spinner.

## 5. UI bandeja d'entrada

Mateixa pàgina `Moderacio.tsx`, amb `Tabs`:
- **Alertes actives** (pestanya `pending`): tarjeta amb:
  - Missatge en `bg-destructive/10 border-destructive/40 text-destructive font-medium` (vermell/taronja segons severitat — `llenguatge` vermell, `antiesportiu` taronja).
  - `target_device_id` truncat + nom (si el tenim via `target_name`).
  - Badge d'origen: `local-blacklist` o `openai-moderation` (llegit de `reporter_device_id`).
  - Categoria (`reason`) i pes (`weight`).
  - Data formatada.
  - Botons segons rol:
    - `admin` + `moderator`: "Aprovar baneig" (destructive), "Desestimar" (outline).
    - `admin` només: "Perdonar punts" (ghost groc).
- **Historial d'auditoria** (pestanya `audit`): llista de `room_chat_flags_audit` ordenada `decided_at desc`, mostrant decisió, moderador, motiu, data.

Responsive: `flex-col` mòbil, `max-w-4xl` centrat, tarjetes amb `p-4 rounded-lg`.

## 6. Visibilitat condicional del botó

Identificar on hi ha el link cap a `/admin/moderacio` (probablement `Ajustes.tsx` o `Perfil.tsx`). Embolcallar amb `useMyRole()`:

```tsx
const { isAdmin, isModerator } = useMyRole();
{(isAdmin || isModerator) && <Link to="/admin/moderacio">Moderació</Link>}
```

Si no apareix avui al menú lateral, l'afegeixo a `Ajustes.tsx`.

## 7. Auditoria automàtica

`decideChatFlag` fa dues operacions dins el handler:
1. `update room_chat_flags set status, decided_by=userId, decided_at=now(), moderator_note=note where id=flagId`.
2. `insert into room_chat_flags_audit (flag_id, decision, decided_by, decided_at, reason) values (...)`.

Si la primera falla, no fa la segona. Si la segona falla, retorna `auditError` (com ja fa l'admin existent).

## 8. Compatibilitat amb el panell antic

Mantinc el path `/admin/moderacio` (catalan). L'usuari haurà d'eliminar manualment `useAdminPassword` del localStorage si vol; sinó simplement s'ignora.

## Fitxers que es crearan / modificaran

**Nou:**
- `docs/roles-and-moderation-inbox-schema.sql`
- `src/online/moderation.functions.ts`
- `src/hooks/useMyRole.ts`

**Modificat:**
- `src/pages/admin/Moderacio.tsx` — reescriptura completa.
- `src/pages/Ajustes.tsx` (o on hi hagi avui el link) — visibilitat condicional.

## Passos manuals que demanaré a l'usuari

1. Executar la migració SQL a Supabase.
2. Executar `insert into public.user_roles (user_id, role) values ('<el-teu-uuid>', 'admin');` amb el seu propi `auth.users.id` (li explico com trobar-lo a Authentication → Users).
3. Recarregar l'app: el botó "Moderació" apareixerà automàticament.

## Tècnic clau

- Mai posar `role` a la taula `profiles` — sempre `user_roles` separada (evita escalada de privilegis).
- `has_role` SECURITY DEFINER per evitar recursió RLS.
- Tots els checks de rol al servidor; el frontend només amaga UI per UX.
- `_authenticated/route.tsx` ja existeix i gestiona la sessió; aquesta pàgina viu sota `/admin/...` però fa el guard manualment amb `useMyRole` perquè l'estructura actual no la té sota `_authenticated`.
