import { useCallback, useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import {
  Loader2,
  LogOut,
  RefreshCw,
  ShieldCheck,
  ShieldX,
  Inbox,
  History,
  MessageSquare,
  HandHeart,
  AlertTriangle,
  ShieldAlert,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { toast } from "sonner";
import { useAuth } from "@/hooks/useAuth";
import { useMyRole } from "@/hooks/useMyRole";
import { ShareAppButton } from "@/components/ShareAppButton";
import {
  listInboxFlags,
  listAuditEntries,
  decideFlag,
  type InboxFlag,
  type AuditEntry,
  type FlagDecision,
  type FlagStatus,
} from "@/online/moderationInbox";

const TABS: { value: FlagStatus | "all"; label: string }[] = [
  { value: "pending", label: "Pendents" },
  { value: "approved", label: "Aprovats" },
  { value: "dismissed", label: "Desestimats" },
  { value: "all", label: "Tots" },
];

function formatDate(iso: string | null): string {
  if (!iso) return "—";
  try {
    return new Date(iso).toLocaleString("ca-ES", { dateStyle: "short", timeStyle: "short" });
  } catch {
    return iso;
  }
}

function truncate(s: string, n = 14): string {
  return s.length <= n ? s : `${s.slice(0, n)}…`;
}

function SourceBadge({ source }: { source: InboxFlag["source"] }) {
  if (source === "local-blacklist") {
    return (
      <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-[10px] font-medium bg-orange-500/15 text-orange-600 border border-orange-500/30">
        Blacklist local
      </span>
    );
  }
  if (source === "openai-moderation") {
    return (
      <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-[10px] font-medium bg-violet-500/15 text-violet-600 border border-violet-500/30">
        OpenAI
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-[10px] font-medium bg-slate-500/15 text-slate-600 border border-slate-500/30">
      Jugador
    </span>
  );
}

function StatusBadge({ status }: { status: FlagStatus }) {
  if (status === "pending")
    return <span className="text-[10px] px-2 py-0.5 rounded bg-amber-500/15 text-amber-600 border border-amber-500/30">Pendent</span>;
  if (status === "approved")
    return <span className="text-[10px] px-2 py-0.5 rounded bg-destructive/15 text-destructive border border-destructive/30">Aprovat</span>;
  return <span className="text-[10px] px-2 py-0.5 rounded bg-emerald-500/15 text-emerald-600 border border-emerald-500/30">Desestimat</span>;
}

export default function Moderacio() {
  const navigate = useNavigate();
  const { user, ready: authReady } = useAuth();
  const { role, isAdmin, isModerator, ready: roleReady } = useMyRole();

  const [status, setStatus] = useState<FlagStatus | "all">("pending");
  const [flags, setFlags] = useState<InboxFlag[]>([]);
  const [audit, setAudit] = useState<AuditEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [loadingAudit, setLoadingAudit] = useState(false);
  const [working, setWorking] = useState<number | null>(null);
  const [notes, setNotes] = useState<Record<number, string>>({});

  useEffect(() => {
    document.title = "Moderació · Truc Valencià";
  }, []);

  // Route guard ------------------------------------------------------------
  useEffect(() => {
    if (!authReady || !roleReady) return;
    if (!user || !isModerator) {
      navigate("/", { replace: true });
    }
  }, [authReady, roleReady, user, isModerator, navigate]);

  const refresh = useCallback(async () => {
    if (!isModerator) return;
    setLoading(true);
    try {
      const list = await listInboxFlags(status);
      setFlags(list);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [isModerator, status]);

  const refreshAudit = useCallback(async () => {
    if (!isModerator) return;
    setLoadingAudit(true);
    try {
      const entries = await listAuditEntries();
      setAudit(entries);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : String(e));
    } finally {
      setLoadingAudit(false);
    }
  }, [isModerator]);

  useEffect(() => {
    if (isModerator) void refresh();
  }, [isModerator, refresh]);

  // Auto-refresh pendents cada 20s
  useEffect(() => {
    if (!isModerator || status !== "pending") return;
    const id = window.setInterval(() => { void refresh(); }, 20000);
    return () => window.clearInterval(id);
  }, [isModerator, status, refresh]);

  const counts = useMemo(() => {
    const c = { pending: 0, approved: 0, dismissed: 0 };
    for (const f of flags) c[f.status]++;
    return c;
  }, [flags]);

  if (!authReady || !roleReady) {
    return (
      <main className="min-h-screen flex items-center justify-center">
        <Loader2 className="w-6 h-6 animate-spin text-primary" />
      </main>
    );
  }

  if (!user || !isModerator) {
    // El useEffect ja redirigeix; aquest fallback evita parpadeig.
    return null;
  }

  async function handleDecide(flag: InboxFlag, decision: FlagDecision) {
    if (decision === "forgiven" && !isAdmin) {
      toast.error("Només l'administrador pot perdonar punts.");
      return;
    }
    setWorking(flag.id);
    try {
      const tag = user?.email ?? user?.id ?? "moderator";
      const res = await decideFlag({
        flag,
        decision,
        userId: user!.id,
        moderatorTag: tag,
        note: notes[flag.id]?.trim() || undefined,
      });
      const label =
        decision === "approved" ? "Baneig aprovat — silenciament mantingut."
        : decision === "forgiven" ? "Punts perdonats — flag arxivat."
        : decision === "dismissed" ? "Flag desestimat."
        : "Flag reobert.";
      toast.success(label);
      if (res.auditError) {
        toast.warning(`Decisió aplicada però l'auditoria ha fallat: ${res.auditError}`);
      }
      await refresh();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : String(e));
    } finally {
      setWorking(null);
    }
  }

  return (
    <main className="min-h-screen px-4 py-6 bg-background text-foreground">
      <div className="w-full max-w-4xl mx-auto flex flex-col gap-5">
        <header className="flex items-center justify-between gap-3 flex-wrap">
          <div className="flex items-center gap-2">
            <ShieldAlert className="w-6 h-6 text-primary" />
            <div>
              <h1 className="font-display font-black italic text-gold text-2xl md:text-3xl leading-none">
                Moderació
              </h1>
              <p className="text-xs text-muted-foreground mt-0.5">
                Bandeja de reports de xat · rol:{" "}
                <span className={cn(
                  "font-medium",
                  isAdmin ? "text-destructive" : "text-amber-600",
                )}>
                  {role}
                </span>
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <ShareAppButton />
            <Button asChild size="sm" variant="ghost" title="Tornar">
              <Link to="/"><LogOut className="w-4 h-4" /></Link>
            </Button>
          </div>
        </header>

        <Tabs defaultValue="inbox" className="w-full">
          <TabsList className="grid w-full grid-cols-2">
            <TabsTrigger value="inbox" className="gap-1.5">
              <Inbox className="w-4 h-4" /> Alertes actives
              {counts.pending > 0 && (
                <span className="ml-1 inline-flex items-center justify-center min-w-[18px] h-[18px] px-1 rounded-full bg-destructive text-[10px] text-destructive-foreground">
                  {counts.pending}
                </span>
              )}
            </TabsTrigger>
            <TabsTrigger value="audit" className="gap-1.5" onClick={() => void refreshAudit()}>
              <History className="w-4 h-4" /> Historial
            </TabsTrigger>
          </TabsList>

          {/* === INBOX ============================================== */}
          <TabsContent value="inbox" className="mt-4 flex flex-col gap-4">
            <div className="flex flex-wrap items-center gap-2">
              {TABS.map((t) => (
                <button
                  key={t.value}
                  type="button"
                  onClick={() => setStatus(t.value)}
                  className={cn(
                    "h-8 px-3 rounded-md text-xs font-medium border transition-colors",
                    status === t.value
                      ? "bg-primary text-primary-foreground border-primary"
                      : "bg-background border-border hover:bg-muted",
                  )}
                >
                  {t.label}
                </button>
              ))}
              <span className="ml-auto text-xs text-muted-foreground">
                {flags.length} flag{flags.length === 1 ? "" : "s"}
              </span>
              <Button onClick={() => void refresh()} size="sm" variant="outline" disabled={loading}>
                <RefreshCw className={cn("w-4 h-4", loading && "animate-spin")} />
              </Button>
            </div>

            {loading && flags.length === 0 ? (
              <div className="flex justify-center py-10"><Loader2 className="w-5 h-5 animate-spin text-primary" /></div>
            ) : flags.length === 0 ? (
              <p className="text-center text-sm text-muted-foreground py-10">
                Cap alerta {status === "all" ? "" : `(${TABS.find((t) => t.value === status)?.label.toLowerCase()})`}.
              </p>
            ) : (
              <ul className="flex flex-col gap-3">
                {flags.map((f) => {
                  const isWorking = working === f.id;
                  const isSevere = f.weight >= 2;
                  return (
                    <li
                      key={f.id}
                      className={cn(
                        "rounded-lg border p-3 flex flex-col gap-2 shadow-sm",
                        f.status === "pending"
                          ? isSevere
                            ? "border-destructive/50 bg-destructive/5"
                            : "border-orange-500/40 bg-orange-500/5"
                          : "border-border bg-card/40",
                      )}
                    >
                      <div className="flex items-start justify-between gap-2 flex-wrap">
                        <div className="flex items-center gap-2 flex-wrap">
                          <StatusBadge status={f.status} />
                          <SourceBadge source={f.source} />
                          <span className={cn(
                            "text-[10px] px-2 py-0.5 rounded border",
                            isSevere
                              ? "bg-destructive/10 text-destructive border-destructive/30"
                              : "bg-amber-500/10 text-amber-700 border-amber-500/30",
                          )}>
                            {f.reason ?? "sense motiu"} · pes {f.weight}
                          </span>
                        </div>
                        <span className="text-[11px] text-muted-foreground">{formatDate(f.createdAt)}</span>
                      </div>

                      {f.messageText ? (
                        <div className={cn(
                          "rounded-md p-2 border flex items-start gap-2",
                          isSevere
                            ? "bg-destructive/10 border-destructive/30 text-destructive"
                            : "bg-orange-500/10 border-orange-500/30 text-orange-800 dark:text-orange-300",
                        )}>
                          {isSevere
                            ? <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                            : <MessageSquare className="w-4 h-4 mt-0.5 shrink-0" />}
                          <p className="text-sm font-medium break-words italic">"{f.messageText}"</p>
                        </div>
                      ) : (
                        <p className="text-xs text-muted-foreground italic">(sense missatge concret)</p>
                      )}

                      <div className="text-xs text-muted-foreground flex flex-wrap gap-x-3 gap-y-1">
                        <span>
                          <span className="font-medium text-foreground/80">Infractor:</span>{" "}
                          <code className="text-[11px]">{truncate(f.targetDeviceId, 18)}</code>
                        </span>
                        <span>
                          <span className="font-medium text-foreground/80">Sala:</span>{" "}
                          <code className="text-[11px]">{truncate(f.roomId, 8)}</code>
                        </span>
                        {f.decidedAt && (
                          <span>Decidit {formatDate(f.decidedAt)}</span>
                        )}
                      </div>

                      {f.status === "pending" && (
                        <Input
                          value={notes[f.id] ?? ""}
                          onChange={(e) => setNotes((p) => ({ ...p, [f.id]: e.target.value.slice(0, 500) }))}
                          placeholder="Nota interna (opcional)"
                          disabled={isWorking}
                          className="h-8 text-xs"
                          maxLength={500}
                        />
                      )}

                      <div className="flex items-center gap-2 pt-1 flex-wrap">
                        {f.status !== "approved" && (
                          <Button size="sm" variant="destructive" disabled={isWorking}
                            onClick={() => void handleDecide(f, "approved")}>
                            <ShieldCheck className="w-3.5 h-3.5 mr-1" /> Aprovar baneig
                          </Button>
                        )}
                        {f.status !== "dismissed" && (
                          <Button size="sm" variant="outline" disabled={isWorking}
                            onClick={() => void handleDecide(f, "dismissed")}>
                            <ShieldX className="w-3.5 h-3.5 mr-1" /> Desestimar
                          </Button>
                        )}
                        {isAdmin && f.status !== "dismissed" && (
                          <Button size="sm" variant="ghost" disabled={isWorking}
                            className="text-emerald-600 hover:text-emerald-700 hover:bg-emerald-500/10"
                            onClick={() => void handleDecide(f, "forgiven")}>
                            <HandHeart className="w-3.5 h-3.5 mr-1" /> Perdonar punts
                          </Button>
                        )}
                        {f.status !== "pending" && (
                          <Button size="sm" variant="ghost" disabled={isWorking}
                            onClick={() => void handleDecide(f, "pending")}>
                            Reobrir
                          </Button>
                        )}
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
          </TabsContent>

          {/* === AUDIT ============================================== */}
          <TabsContent value="audit" className="mt-4 flex flex-col gap-3">
            <div className="flex items-center justify-between">
              <p className="text-xs text-muted-foreground">
                Historial de decisions de moderació ({audit.length} entrades)
              </p>
              <Button onClick={() => void refreshAudit()} size="sm" variant="outline" disabled={loadingAudit}>
                <RefreshCw className={cn("w-4 h-4", loadingAudit && "animate-spin")} />
              </Button>
            </div>
            {loadingAudit && audit.length === 0 ? (
              <div className="flex justify-center py-10"><Loader2 className="w-5 h-5 animate-spin text-primary" /></div>
            ) : audit.length === 0 ? (
              <p className="text-center text-sm text-muted-foreground py-10">
                Cap decisió registrada encara.
              </p>
            ) : (
              <ul className="flex flex-col gap-2">
                {audit.map((a) => (
                  <li key={a.id} className="rounded-md border border-border bg-card/40 p-2.5 text-sm flex flex-col gap-1">
                    <div className="flex items-center justify-between gap-2 flex-wrap">
                      <span className={cn(
                        "text-[11px] font-semibold px-2 py-0.5 rounded",
                        a.decision === "approved" && "bg-destructive/15 text-destructive",
                        a.decision === "dismissed" && "bg-emerald-500/15 text-emerald-600",
                        a.decision === "forgiven" && "bg-blue-500/15 text-blue-600",
                        a.decision === "pending" && "bg-amber-500/15 text-amber-600",
                      )}>
                        {a.decision}
                      </span>
                      <span className="text-[11px] text-muted-foreground">{formatDate(a.decidedAt)}</span>
                    </div>
                    {a.messageText && (
                      <p className="text-xs italic break-words">"{a.messageText}"</p>
                    )}
                    <div className="text-[11px] text-muted-foreground flex flex-wrap gap-x-3">
                      <span>flag #{a.flagId}</span>
                      {a.reason && <span>motiu: {a.reason}</span>}
                      {a.moderatorTag && <span>per: <code>{truncate(a.moderatorTag, 24)}</code></span>}
                    </div>
                    {a.moderatorNote && (
                      <p className="text-[11px] text-foreground/80">📝 {a.moderatorNote}</p>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </TabsContent>
        </Tabs>
      </div>
    </main>
  );
}