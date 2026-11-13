package sa.fivehours.relay.app;

import android.app.Notification;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import sa.fivehours.relay.core.AccountRules;
import sa.fivehours.relay.core.Config;

/**
 * A notification of the bank's app (the owner allows it in the phone's settings): its package name (e.g. the bank app's
 * «com.…») must be one of the allowed senders — an app's display name is not trusted, any app can take it — then the
 * same rule as an SMS. An app that is not allowed but whose notification carries an account number is noted by its
 * package name only, for the owner to add. Only reads; it never answers, opens or clears a notification.
 */
public final class BankNotifications extends NotificationListenerService {
    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        if (sbn == null || getPackageName().equals(sbn.getPackageName())) return;
        Notification n = sbn.getNotification();
        if (n == null || (n.flags & Notification.FLAG_GROUP_SUMMARY) != 0) return;
        Bundle x = n.extras;
        CharSequence text = x == null ? null : x.getCharSequence(Notification.EXTRA_BIG_TEXT);
        if (text == null && x != null) text = x.getCharSequence(Notification.EXTRA_TEXT);
        if (text == null) return;
        Store s = new Store(this);
        Config c = s.config();
        if (c == null) return;
        String pkg = sbn.getPackageName();
        final String body = text.toString();
        if (!c.allows(pkg)) {
            if (AccountRules.matches(body, c.accounts)) s.noteUnknownApp(pkg);
            return;
        }
        final String sender = pkg;
        final long at = sbn.getPostTime();
        new Thread(() -> {
            try { s.relayer().accept(c, s.key(), sender, at, "notification", body); } catch (Exception ignored) { }
            SendJob.schedule(getApplicationContext());
        }, "relay-notification").start();
    }
}
