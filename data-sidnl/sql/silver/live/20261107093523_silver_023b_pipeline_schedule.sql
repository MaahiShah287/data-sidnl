update silver.sidnl_config set value_num = 600,
       description = 'run_pipeline() will not start again sooner than this after the previous run (refresh_brand re-reads full history, ~90 s today)'
 where key = 'pipeline_min_interval_seconds';

create extension if not exists pg_cron;

select cron.schedule('sidnl-pipeline', '* * * * *', $cron$select silver.run_pipeline(false, 'cron')$cron$);
select cron.schedule('sidnl-pipeline-daily', '35 18 * * *', $cron$select silver.run_pipeline(true, 'cron-daily')$cron$);