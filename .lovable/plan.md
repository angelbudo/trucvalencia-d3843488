# Sistema de Penalización por Abandono (Leaver Penalty)

Sistema **totalmente independiente** del de moderación por comportamiento/IA. Vive en sus propias tablas y nunca contribuye al baneo definitivo.

## 1. Base de datos (migración nueva)

### Tabla `public.leaver_penalty`
Una fila por jugador (clave compuesta: una por dispositivo, otra por cuenta — igual que el sistema de moderación existente, para que el castigo siga al usuario aunque cambie de móvil).

```
device_id            text PRIMARY KEY        -- o user_id en la variante account
leave_count          int not null default 0  -- contador 0..3
ban_count            int not null default 0  -- nº veces que ha llegado a baneo (informativo)
banned_until         timestamptz             -- null si no está baneado
last_leave_at        timestamptz             -- referencia para la recuperación
updated_at           timestamptz not null default now()
```

Dos tablas gemelas: `leaver_penalty_device` (device_id) y `leaver_penalty_account` (user_id), idénticas en forma. Como en el sistema actual de moderación.

GRANTs: `select` a `authenticated`, `all` a `service_role`. RLS activado con policy de lectura `using (true)` para que el cliente pueda mostrar el estado.

Añadidas a `supabase_realtime` para que el OnlineBanGate reaccione al instante.

### Función `public._apply_leaver_step(_table, _key_col, _key_val)`
- Incrementa `leave_count`.
- Si llega a 3 → `banned_until = now() + 24h`, `ban_count += 1`, `leave_count = 0`.
- Actualiza `last_leave_at = now()`.

### Función `public.register_leave(p_device_id text, p_user_id uuid, p_room_id uuid)`
RPC `security definer` que llama el cliente (o el server) al detectar abandono. Aplica el step al device y, si hay user_id, también a la cuenta.

### Función `public.decay_leaver_counters()`
- Para cada fila con `leave_count > 0` y `last_leave_at < now() - interval '24 hours'` y sin baneo activo: `leave_count = greatest(leave_count - 1, 0)` y empuja `last_leave_at = now()` para que el siguiente decay sea otras 24h después.
- Programada con `pg_cron` cada hora (si está disponible) — si no, se invoca de forma oportunista al cargar el estado del jugador.

## 2. Detección de abandono (cliente + RPC)

El proyecto ya tiene flujo de salas en `supabase/functions/rooms-rpc/index.ts` y hooks `useRoomRealtime`/`useMyActiveRooms`. El abandono cuenta cuando:
- El jugador deja la sala con partida **en curso** (no en lobby, no antes del reparto, no al terminar).
- Desconexión sostenida (>X segundos) durante partida en curso → ya hay heurística de presencia.

Se añade en `rooms-rpc`:
- En el RPC existente `leaveRoom` (o equivalente), si el estado de la partida es "in_progress", invocar `register_leave` con `device_id` + `user_id` antes de quitar al jugador.
- En la limpieza por timeout de presencia (si existe) hacer lo mismo.

(Solo se toca la rama de partida en curso — abandonar la sala antes de empezar no penaliza.)

## 3. Frontend

### Nuevo hook `src/online/useLeaverPenalty.ts`
Análogo a `useDeviceModeration`: suscribe a `leaver_penalty_device` por device_id y `leaver_penalty_account` por user_id, devuelve estado fusionado `{ leaveCount, bannedUntil, isBanned, loaded }`.

### `OnlineBanGate` — extender
Hoy bloquea por `useDeviceModeration`. Se añade comprobación paralela del leaver penalty:
- Si `useDeviceModeration.isBanned` → mensaje actual (comportamiento).
- Si `useLeaverPenalty.isBanned` → **nuevo mensaje**: "Has sido suspendido 24 horas por **abandono reiterado de partidas online**. Podrás volver a jugar en HH:MM:SS." (traducido a ca / val / es).
- Botón "Tancar aplicació" igual que el resto.

Importante: el leaver penalty **solo bloquea la sección online**. El OnlineBanGate ya envuelve únicamente las rutas online, así que con esto basta — el menú offline / juego local sigue accesible. Si se ve que el gate envuelve toda la app, lo limitamos a las rutas `/online/*`.

### Aviso adicional en la bandeja
`src/lib/messagesInbox.ts` / `MessagesInbox.tsx`: al activarse el baneo (trigger DB) se inserta también un mensaje en la bandeja del jugador indicando motivo y fin del baneo. Lo hacemos desde `_apply_leaver_step` cuando se llega a baneo.

## 4. i18n
Nuevas claves en `src/i18n/dict.ts`:
- `leaverBanTitle`
- `leaverBanBody` (con placeholder de tiempo restante)
- `leaverBanReason` ("Abandono reiterado de partidas online" / "Abandonament reiterat de partides en línia" / valenciano)
- `leaverInboxNotice`

## 5. Independencia garantizada
- Tablas separadas (`leaver_penalty_*`), nunca tocan `device_moderation` ni `account_moderation`.
- Triggers separados, no llaman a `_apply_moderation_step`.
- `OnlineBanGate` evalúa los dos sistemas por separado y muestra el mensaje que corresponda. El leaver penalty caduca por tiempo y resetea el contador a 0; no acumula hacia baneo permanente.

## 6. Detalles técnicos clave
- Migración SQL con CREATE TABLE + GRANT + RLS + POLICY + funciones + trigger de publicación realtime, en este orden.
- `register_leave` es `security definer` y devuelve el nuevo estado; el cliente puede mostrar inmediatamente "1/3 abandonos".
- El decay también se ejecuta dentro de `register_leave` antes de incrementar, para que un jugador que vuelve tras >24h sin abandonar empiece a contar desde 0 incluso si no hay pg_cron.
- Sin cambios en el sistema de moderación existente.

## Archivos a crear / modificar
- **Nuevo** `supabase/migrations/<ts>_leaver_penalty.sql`
- **Nuevo** `src/online/useLeaverPenalty.ts`
- Editar `src/components/OnlineBanGate.tsx` (añadir rama leaver)
- Editar `src/i18n/dict.ts` (claves nuevas)
- Editar `supabase/functions/rooms-rpc/index.ts` (llamar `register_leave` al abandonar partida en curso)
- (Opcional) Editar `src/App.tsx` si el gate envuelve rutas no-online y conviene limitarlo

## Preguntas antes de implementar
1. **¿Cuándo cuenta exactamente como abandono?** Mi propuesta: salir de la sala o desconectarse >60s durante una partida ya iniciada (no en lobby, no al terminar). ¿OK o prefieres otro umbral?
2. **¿Quieres que también se envíe un mensaje a la bandeja** cuando se activa el baneo, además del cartel del gate? (Recomendado: sí.)
3. **pg_cron para el decay:** si no está habilitado en tu proyecto, ¿OK con la versión "decay oportunista al cargar"? (Funciona igual de bien para el usuario.)