package sa.fivehours.relay.app;

import android.app.Notification;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import sa.fivehours.relay.core.Config;

/**
 * A notification of the bank's app (the owner allows it in the phone's settings): the app's name, or its package name,
 * must be one of the allowed senders, then the same rule as an SMS. Only reads; it never answers, opens or clears one.
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
        String pkg = sbn.getPackageName(), label = pkg;
        try {
            PackageManager pm = getPackageManager();
            ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
            label = String.valueOf(pm.getApplicationLabel(ai));
        } catch (PackageManager.NameNotFoundException ignored) { }
        String sender = c.allows(label) ? label : c.allows(pkg) ? pkg : null;
        if (sender == null) return;
        final String body = text.toString();
        final long at = sbn.getPostTime();
        new Thread(() -> {
            try { s.relayer().accept(c, s.key(), sender, at, "notification", body); } catch (Exception ignored) { }
            SendJob.schedule(getApplicationContext());
        }, "relay-notification").start();
    }
}
