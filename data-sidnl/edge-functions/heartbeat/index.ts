// edge-functions/heartbeat/index.ts
// Gap 5: external uptime monitor (UptimeRobot etc.) polls this every 5 min.
// 200 = nothing overdue; 503 = something overdue OR database unreachable.
// Deploy:  supabase functions deploy heartbeat --no-verify-jwt

Deno.serve(async () => {
  const { createClient } = await import("https://esm.sh/@supabase/supabase-js@2");
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  try {
    const { data, error } = await admin.from("v_heartbeat").select("*");
    if (error) throw new Error(error.message);

    // v_heartbeat rows: jobname, active, last_start, last_status, expected_by
    const overdue = (data ?? []).filter((r: any) => {
      if (r.active === false) return true;                       // paused job
      if (!r.last_start) return true;                            // never ran
      return new Date(r.last_start) < new Date(r.expected_by);   // stale
    });

    const body = {
      ok: overdue.length === 0,
      jobs: (data ?? []).map((r: any) => ({
        job: r.jobname, active: r.active,
        last_start: r.last_start, last_status: r.last_status })),
    };

    return new Response(JSON.stringify(body), {
      status: overdue.length === 0 ? 200 : 503,
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    // database unreachable or view missing -> 503 so the monitor alerts
    return new Response(JSON.stringify({ ok: false, error: String(e) }), {
      status: 503, headers: { "content-type": "application/json" } });
  }
});
