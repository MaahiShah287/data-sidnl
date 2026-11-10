// edge-functions/alert-dispatch/index.ts
// Gap 4 delivery worker: claims pending outbox rows and posts to Slack.
// Deploy:  supabase functions deploy alert-dispatch
// Secrets (set YOURSELF, never commit):
//   supabase secrets set SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
// Cron sidnl-alerts (or the external monitor) POSTs here every minute.

declare const Deno: {
  env: {
    get: (key: string) => string | undefined;
  };
  serve: (handler: () => Promise<Response> | Response) => void;
};

Deno.serve(async () => {
  const webhook = Deno.env.get("SLACK_WEBHOOK_URL");
  if (!webhook) {
    return new Response(JSON.stringify({ ok: false, error: "SLACK_WEBHOOK_URL not set" }), {
      status: 500, headers: { "content-type": "application/json" } });
  }

  // @ts-ignore: URL import resolved natively by Deno runtime at deployment
  const { createClient } = (await import("https://esm.sh/@supabase/supabase-js@2")) as any;
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { db: { schema: "ops" } },
  );

  const { data: alerts, error: claimErr } = await admin.rpc("alert_claim", { p_limit: 10 });
  if (claimErr) {
    return new Response(JSON.stringify({ ok: false, error: claimErr.message }), {
      status: 500, headers: { "content-type": "application/json" } });
  }
  if (!alerts || alerts.length === 0) {
    return new Response(JSON.stringify({ ok: true, delivered: 0 }), {
      headers: { "content-type": "application/json" } });
  }

  let delivered = 0;
  let failed = 0;
  for (const a of alerts) {
    let ok = false, err: string | null = null;
    try {
      const res = await fetch(webhook, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          text: `*[SIDNL ${a.severity}*] ${a.title}\n${a.body ?? ""} (source: ${a.source})`,
        }),
      });
      ok = res.ok;
      if (!ok) err = `slack responded ${res.status}`;
    } catch (e) {
      err = String(e);
    }
    const { error: markErr } = await admin.rpc("alert_mark", {
      p_alert_id: a.alert_id, p_ok: ok, p_err: err });
    if (ok && !markErr) delivered++;
    else failed++;
    if (markErr) console.error(`Could not record alert ${a.alert_id}: ${markErr.message}`);
  }

  return new Response(JSON.stringify({ ok: failed === 0, delivered, failed }), {
    status: failed === 0 ? 200 : 502,
    headers: { "content-type": "application/json" } });
});
