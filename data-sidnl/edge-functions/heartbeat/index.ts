// edge-functions/heartbeat/index.ts
// Gap 5: external uptime monitor (UptimeRobot etc.) polls this every 5 min.
// 200 = nothing overdue; 503 = something overdue OR database unreachable.
// Deploy:  supabase functions deploy heartbeat --no-verify-jwt
//
// ops.v_heartbeat is in the 'ops' schema; supabase-js .from() defaults to
// the public schema, so we pass { db: { schema: 'ops' } } to the client.

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

    const { createClient } = await import("https://esm.sh/@supabase/supabase-js@2");
    const admin = createClient(supabaseUrl, serviceRoleKey, { db: { schema: "ops" } });
    // .from() now resolves to ops.v_heartbeat (schema set above)
    const { data, error } = await admin.from("v_heartbeat").select("*");
    if (error) throw new Error(error.message);

    // v_heartbeat rows: jobname, active, last_start, last_status, expected_by
    const isOverdue = (r: (typeof data)[number]) =>
      r.active === false ||
      !r.last_start ||
      r.last_status === "failed" ||
      new Date(r.last_start) < new Date(r.expected_by);
    const overdue = (data ?? []).filter(isOverdue);

    const body = {
      ok: overdue.length === 0,
      // expose only job names, timestamps and ok/overdue flag — no data values
      jobs: (data ?? []).map((r: (typeof data)[number]) => ({
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
