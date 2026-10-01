-- ============================================================
-- Smart Academy — schedule-reminder-cron.sql
-- ============================================================
--
-- ============================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
    'notify-upcoming-classes-every-minute',
    '* * * * *',
    $$
    select net.http_post(
        url := 'https://sxobsikdlgxpwnqazqtj.supabase.co/functions/v1/notify-upcoming-classes',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer sb_publishable_7Q98XUZ5hjMMJKfOW4LBfw_WuBAqk-B'
        ),
        body := '{}'::jsonb
    );
    $$
);

-- select * from cron.job where jobname = 'notify-upcoming-classes-every-minute';

-- select cron.unschedule('notify-upcoming-classes-every-minute');

-- select * from cron.job_run_details
-- where jobid = (select jobid from cron.job where jobname = 'notify-upcoming-classes-every-minute')
-- order by start_time desc limit 20;
