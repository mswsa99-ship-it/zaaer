package sa.fivehours.relay.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;
import java.util.LinkedHashMap;
import java.util.Map;

/** A new SMS: its parts joined per sender, then the same rule as everything else (Relayer.accept). Only reads. */
public final class SmsReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context ctx, Intent intent) {
        if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) return;
        SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        if (parts == null || parts.length == 0) return;
        Map<String, StringBuilder> texts = new LinkedHashMap<>();
        Map<String, Long> times = new LinkedHashMap<>();
        for (SmsMessage m : parts) {
            if (m == null) continue;
            String from = m.getDisplayOriginatingAddress();
            texts.computeIfAbsent(from, k -> new StringBuilder()).append(m.getDisplayMessageBody());
            times.putIfAbsent(from, m.getTimestampMillis());
        }
        PendingResult done = goAsync();
        Context app = ctx.getApplicationContext();
        new Thread(() -> {
            try {
                Store s = new Store(app);
                for (Map.Entry<String, StringBuilder> e : texts.entrySet()) {
                    try { s.relayer().accept(s.config(), s.key(), e.getKey(), times.get(e.getKey()), "sms", e.getValue().toString()); }
                    catch (Exception ignored) { /* a full disk: nothing else to do here */ }
                }
                SendJob.schedule(app);
            } finally {
                done.finish();
            }
        }, "relay-sms").start();
    }
}
