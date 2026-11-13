-- dash_014: re-register cron job sidnl-competitors.
-- dash_013 created the job inside its own long transaction (the first refresh ran in it, 27 s). On 2026-11-13 the job row
-- exists and is active, but pg_cron never started it: 0 runs at the 06:40 and 06:50 ticks while every other */10 job
-- (sidnl-context, sidnl-fp-ads, sidnl-auto-match, sidnl-store-city) ran. Jobs created by earlier migrations all ran on
-- their first tick. Registering it again in a short transaction of its own makes the scheduler load it.
-- dash.refresh_competitors() already ran by hand at 06:43 (16,321 + 3,200 rows), so no data is missing in the meantime.

do $cron$
begin
    if exists (select 1 from cron.job where jobname = 'sidnl-competitors') then
        perform cron.unschedule('sidnl-competitors');
    end if;
    perform cron.schedule('sidnl-competitors', '*/10 * * * *',
        $$set statement_timeout = '300s'; select dash.refresh_competitors()$$);
end
$cron$;
