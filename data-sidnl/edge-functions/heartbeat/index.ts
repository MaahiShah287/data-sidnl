// edge-functions/heartbeat/index.ts
// Gap 5: external uptime monitor (UptimeRobot etc.) polls this every 5 min.
// 200 = nothing overdue; 503 = something overdue OR database unreachable.
// Deploy:  supabase functions deploy heartbeat --no-verify-jwt
//
// The data comes from ops.heartbeat() (SECURITY DEFINER, schema 'ops'), called with { db: { schema: 'ops' } }.
// Requires schema 'ops' in Dashboard > Project Settings > API > Exposed schemas.

declare const Deno: {
  env: {
    get: (key: string) => string | undefined;
  };
  serve: (handler: () => Promise<Response> | Response) => void;
};

Deno.serve(async () => {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be configured");
    }

    // @ts-ignore: URL import resolved natively by Deno runtime at deployment
    const { createClient } = (await import("https://esm.sh/@supabase/supabase-js@2")) as any;
    const admin = createClient(supabaseUrl, serviceRoleKey, { db: { schema: "ops" } });

    // service_role has no direct access to ops.v_heartbeat; read it through the SECURITY DEFINER function ops.heartbeat()
    const { data, error } = await admin.rpc("heartbeat");
    if (error) throw new Error(error.message);

    // v_heartbeat rows: jobname, active, schedule, last_start, last_status, expected_by
    // A job that has never run is only overdue if it should have run by now: daily jobs ("m h * * *") that have not
    // reached their first scheduled time yet are fine.
    const isDaily = (r: any) => /^\d+ \d+ \* \* \*$/.test(String(r.schedule ?? ""));
    const isOverdue = (r: any) =>
      r.active === false ||
      (!r.last_start && !isDaily(r)) ||
      r.last_status === "failed" ||
      (r.last_start && new Date(r.last_start) < new Date(r.expected_by));
    const overdue = (data ?? []).filter(isOverdue);

    const body = {
      ok: overdue.length === 0,
      // expose only job names, timestamps and ok/overdue flag — no data values
      jobs: (data ?? []).map((r: any) => ({
        job: r.jobname,
        active: r.active,
        last_start: r.last_start,
        last_status: r.last_status,
        overdue: isOverdue(r),
      })),
    };

    return new Response(JSON.stringify(body), {
      status: overdue.length === 0 ? 200 : 503,
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    // database unreachable or view missing -> 503 so the monitor alerts
    return new Response(JSON.stringify({ ok: false, error: String(e) }), {
      status: 503, headers: { "content-type": "application/json" },
    });
  }
});
