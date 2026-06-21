import { supabase } from "@/integrations/supabase/client";

export type FlagStatus = "pending" | "approved" | "dismissed";
export type FlagDecision = FlagStatus | "forgiven";

export interface InboxFlag {
  id: number;
  roomId: string;
  targetDeviceId: string;
  reporterDeviceId: string;
  reason: string | null;
  messageId: number | null;
  messageText: string | null;
  status: FlagStatus;
  createdAt: string;
  expiresAt: string;
  decidedAt: string | null;
  decidedBy: string | null;
  /** local-blacklist | openai-moderation | <device id de l'usuari> */
  source: "local-blacklist" | "openai-moderation" | "user";
  /** Pes calculat a partir de reason (1=lleu, 2=greu). */
  weight: number;
}

export interface AuditEntry {
  id: number;
  flagId: number;
  roomId: string | null;
  targetDeviceId: string | null;
  reporterDeviceId: string | null;
  messageText: string | null;
  reason: string | null;
  decision: FlagDecision;
  decidedBy: string | null;
  moderatorTag: string | null;
  moderatorNote: string | null;
  decidedAt: string;
}

function weightFor(reason: string | null): number {
  if (!reason) return 1;
  const r = reason.toLowerCase();
  if (r.includes("llenguatge") || r.includes("amenaça") || r.includes("amenaza")) return 2;
  return 1;
}

function sourceFor(deviceId: string): InboxFlag["source"] {
  if (deviceId === "local-blacklist") return "local-blacklist";
  if (deviceId === "openai-moderation") return "openai-moderation";
  return "user";
}

function normalize(row: any): InboxFlag {
  return {
    id: row.id,
    roomId: row.room_id,
    targetDeviceId: row.target_device_id,
    reporterDeviceId: row.reporter_device_id,
    reason: row.reason ?? null,
    messageId: row.message_id ?? null,
    messageText: row.message_text ?? null,
    status: row.status as FlagStatus,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    decidedAt: row.decided_at ?? null,
    decidedBy: row.decided_by ?? null,
    source: sourceFor(row.reporter_device_id),
    weight: weightFor(row.reason),
  };
}

export async function listInboxFlags(status: FlagStatus | "all"): Promise<InboxFlag[]> {
  let q = (supabase as any)
    .from("room_chat_flags")
    .select("*")
    .order("created_at", { ascending: false })
    .limit(200);
  if (status !== "all") q = q.eq("status", status);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return (data ?? []).map(normalize);
}

export async function listAuditEntries(): Promise<AuditEntry[]> {
  const { data, error } = await (supabase as any)
    .from("room_chat_flags_audit")
    .select("*")
    .order("decided_at", { ascending: false })
    .limit(200);
  if (error) throw new Error(error.message);
  return (data ?? []).map((row: any) => ({
    id: row.id,
    flagId: row.flag_id,
    roomId: row.room_id ?? null,
    targetDeviceId: row.target_device_id ?? null,
    reporterDeviceId: row.reporter_device_id ?? null,
    messageText: row.message_text ?? null,
    reason: row.reason ?? null,
    decision: row.decision,
    decidedBy: row.decided_by ?? null,
    moderatorTag: row.moderator_tag ?? null,
    moderatorNote: row.moderator_note ?? null,
    decidedAt: row.decided_at,
  }));
}

export interface DecideOptions {
  flag: InboxFlag;
  decision: FlagDecision;
  userId: string;
  moderatorTag: string;
  note?: string;
}

/**
 * Aplica una decisió a un flag:
 *   - approved  → manté el silenciament (Aprovar baneig).
 *   - dismissed → archiva com fals positiu.
 *   - forgiven  → només admin; equival a dismissed però registra "forgiven".
 *   - pending   → reobre.
 * Sempre escriu una entrada a room_chat_flags_audit.
 */
export async function decideFlag(opts: DecideOptions): Promise<{ auditError: string | null }> {
  const { flag, decision, userId, moderatorTag, note } = opts;

  // 1) Actualitzar el flag (forgiven → status='dismissed' a la taula original)
  const newStatus: FlagStatus = decision === "approved" ? "approved"
    : decision === "pending" ? "pending"
    : "dismissed";

  const { error: updateError } = await (supabase as any)
    .from("room_chat_flags")
    .update({
      status: newStatus,
      decided_at: decision === "pending" ? null : new Date().toISOString(),
      decided_by: decision === "pending" ? null : userId,
    })
    .eq("id", flag.id);

  if (updateError) throw new Error(updateError.message);

  // 2) Inserir registre d'auditoria (no bloca si falla)
  const { error: auditError } = await (supabase as any)
    .from("room_chat_flags_audit")
    .insert({
      flag_id: flag.id,
      room_id: flag.roomId,
      target_device_id: flag.targetDeviceId,
      reporter_device_id: flag.reporterDeviceId,
      message_id: flag.messageId,
      message_text: flag.messageText,
      reason: flag.reason,
      decision,
      decided_by: userId,
      moderator_tag: moderatorTag,
      moderator_note: note ?? null,
      flag_created_at: flag.createdAt,
      flag_expires_at: flag.expiresAt,
    });

  return { auditError: auditError ? auditError.message : null };
}