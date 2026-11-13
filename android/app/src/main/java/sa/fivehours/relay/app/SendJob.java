package sa.fivehours.relay.app;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import sa.fivehours.relay.core.Config;
import sa.fivehours.relay.core.Relayer;
import sa.fivehours.relay.core.Smtp;

/**
 * Sends the outbox when the phone has internet. The system runs it once a network is up, and runs it again (30
 * seconds, then longer, up to a few hours) while something is still waiting — after a restart too.
 */
public final class SendJob extends JobService {
    private static final int ID = 1;

    /** after a new message: a send is arranged unless one is already waiting or running (it checks the outbox again
     *  when it ends) */
    static void schedule(Context ctx) {
        JobScheduler js = (JobScheduler) ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if (js == null || js.getPendingJob(ID) != null) return;
        js.schedule(job(ctx));
    }

    /** the owner saved new settings or asked to send now: a fresh send, without waiting out an earlier back-off */
    static void now(Context ctx) {
        JobScheduler js = (JobScheduler) ctx.getSystemService(Context.JOB_SCHEDULER_SERVICE);
        if (js == null) return;
        js.cancel(ID);
        js.schedule(job(ctx));
    }

    private static JobInfo job(Context ctx) {
        return new JobInfo.Builder(ID, new ComponentName(ctx, SendJob.class))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .setBackoffCriteria(30_000, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .build();
    }

    @Override public boolean onStartJob(JobParameters params) {
        new Thread(() -> {
            Store s = new Store(this);
            Config c = s.config();
            String pw = s.password();
            boolean again = false;
            if (c != null && pw != null && s.outbox().size() > 0) {
                Relayer.Result r = s.relayer().flush(c, Smtp.forServer(c.smtpHost, c.smtpPort, c.user, pw));
                s.result(r);
                again = r.waiting > 0;
            }
            jobFinished(params, again);
            // a message queued while this send was finishing is not left waiting for the next one
            if (!again && c != null && pw != null && s.outbox().size() > 0) now(getApplicationContext());
        }, "relay-send").start();
        return true;
    }

    @Override public boolean onStopJob(JobParameters params) { return true; }
}
