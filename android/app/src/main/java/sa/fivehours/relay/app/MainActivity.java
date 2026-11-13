package sa.fivehours.relay.app;

import android.Manifest;
import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.Insets;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.InputType;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.text.DateFormat;
import java.util.Date;
import sa.fivehours.relay.core.AccountRules;
import sa.fivehours.relay.core.Config;

/**
 * The only screen: is the app set up and allowed to read, what waits to be sent and how the last try went, and the
 * settings (the setup text from «بريد البنك» in the system, and the mailbox password typed here). It shows no message.
 */
public final class MainActivity extends Activity {
    private Store store;
    private LinearLayout root;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        store = new Store(this);
        ScrollView sv = new ScrollView(this);
        root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setLayoutDirection(View.LAYOUT_DIRECTION_RTL);
        int pad = dp(16);
        root.setPadding(pad, pad, pad, pad);
        // Android 15 draws apps under the status and navigation bars: keep the content clear of them
        sv.setOnApplyWindowInsetsListener((v, insets) -> { pad(v, insets); return insets; });
        sv.addView(root);
        setContentView(sv);
    }

    @Override protected void onResume() { super.onResume(); render(); }

    private void render() {
        root.removeAllViews();
        Config c = store.config();
        boolean sms = checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED;
        boolean notes = notificationAccess();
        boolean ready = c != null && store.key() != null && store.password() != null;

        title("ناقل رسائل البنك — فايف اورز");
        text("ينقل رسالة البنك التي تحمل رقم أحد حسابات الفروع كما هي إلى بريد النظام، ولا يرسل غير ذلك.", 14, 0xFF5B6472);

        section("الحالة");
        line(ready ? "مُعدّ" : "غير مُعدّ بعد: الصق نص الإعداد واكتب كلمة مرور البريد", ready);
        line(sms ? "قراءة الرسائل النصية: مسموحة" : "قراءة الرسائل النصية: غير مسموحة", sms);
        if (!sms) button("السماح بقراءة الرسائل", v -> requestPermissions(new String[] { Manifest.permission.RECEIVE_SMS }, 1));
        line(notes ? "قراءة إشعارات تطبيق البنك: مسموحة" : "قراءة إشعارات تطبيق البنك: غير مسموحة", notes);
        if (!notes) {
            text("إن ظهر أن الإعداد مقيّد: افتح «معلومات التطبيق» ← ⋮ ← «السماح بالإعدادات المقيدة»، ثم ارجع هنا.", 13, 0xFF5B6472);
            button("فتح إعداد الإشعارات", v -> startActivity(new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)));
            button("معلومات التطبيق", v -> startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:" + getPackageName()))));
        }
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        boolean free = pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
        line(free ? "توفير البطارية: لا يؤخّر التطبيق" : "توفير البطارية قد يؤخّر الإرسال ساعات: اجعل التطبيق «غير مقيّد»", free);
        if (!free) button("إعداد البطارية", v -> startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)));
        int waiting = store.outbox().size();
        text("بانتظار الإرسال: " + waiting, 16, 0xFF1F2937);
        long last = store.lastSent();
        text("آخر إرسال ناجح: " + (last == 0 ? "لا يوجد بعد" : DateFormat.getDateTimeInstance().format(new Date(last))), 14, 0xFF5B6472);
        String err = store.error();
        if ("refused".equals(err)) line("رفض خادم البريد الدخول: صحّح كلمة مرور التطبيق (أو اسم الدخول في نص الإعداد) ثم احفظ.", false);
        else if ("network".equals(err)) line("تعذّر الوصول لخادم البريد؛ سيُعاد الإرسال تلقائيًا عند توفر الإنترنت.", false);
        if (store.setAside() > 0) line("رسائل رفضها خادم البريد وتُركت جانبًا: " + store.setAside() + " (راجع البريد المخصّص)", false);
        String unknown = store.unknownApps();
        if (!unknown.isEmpty()) text("تطبيقات وصل منها إشعار فيه رقم حساب ولم تُسمح (أضف تطبيق البنك منها إلى «المرسلون المسموحون» في النظام ثم انسخ نص الإعداد من جديد): " + unknown.replace(",", "، "), 13, 0xFFB54708);
        if (waiting > 0 && ready) button("أرسل المنتظر الآن", v -> { SendJob.now(this); render(); });

        section("الإعداد");
        if (c != null) {
            StringBuilder s = new StringBuilder();
            s.append("البريد: ").append(c.mailbox).append(c.user.equals(c.mailbox) ? "" : "\nاسم الدخول: " + c.user).append("\nالخادم: ").append(c.smtpHost).append(':').append(c.smtpPort)
             .append("\nالمرسلون: ").append(TextUtils.join("، ", c.senders)).append("\nالحسابات: ");
            for (int i = 0; i < c.accounts.size(); i++) { AccountRules.Rule r = c.accounts.get(i); s.append(i == 0 ? "" : "، ").append('⁦').append(r.toString()).append('⁩'); }
            String end = store.keyEnd();
            s.append("\nمفتاح النقل: ").append(end == null ? "غير مضبوط" : "ينتهي بـ " + end);
            text(s.toString(), 14, 0xFF1F2937);
        }
        EditText setup = input("نص الإعداد من «بريد البنك» في النظام", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        setup.setMinLines(4);
        setup.setGravity(Gravity.TOP | Gravity.START);
        setup.setTextDirection(View.TEXT_DIRECTION_LTR);
        EditText pw = input(store.password() == null ? "كلمة مرور تطبيق البريد" : "كلمة مرور تطبيق البريد (اتركها فارغة لإبقاء الحالية)",
            InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        TextView msg = text("", 14, 0xFFB42318);
        button("حفظ", v -> {
            String t = setup.getText().toString().trim();
            String p = pw.getText().toString();
            try {
                Config nc = t.isEmpty() ? c : Config.parse(t);
                if (nc == null) { msg.setText("الصق نص الإعداد أولًا."); return; }
                if (nc.key == null && store.key() == null) { msg.setText("نص الإعداد بلا مفتاح النقل. أنشئ مفتاحًا في «بريد البنك» وانسخ النص الذي يظهر معه."); return; }
                if (p.isEmpty() && store.password() == null) { msg.setText("اكتب كلمة مرور تطبيق البريد."); return; }
                store.save(nc, p.isEmpty() ? null : p);
                SendJob.now(this);
                render();
            } catch (Config.Invalid e) {
                msg.setText("نص الإعداد غير صالح (" + e.field + "). انسخه كاملًا من «بريد البنك».");
            }
        });
        text("كلمة المرور تُحفظ مشفّرة في هذا الجوال ولا تُرسل إلا لخادم البريد. لا يحفظ التطبيق الرسائل بعد إرسالها.", 12, 0xFF5B6472);
    }

    @SuppressWarnings("deprecation")
    private static void pad(View v, WindowInsets insets) {
        if (Build.VERSION.SDK_INT >= 30) {
            Insets i = insets.getInsets(WindowInsets.Type.systemBars());
            v.setPadding(i.left, i.top, i.right, i.bottom);
        } else {
            v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
        }
    }

    private boolean notificationAccess() {
        String flat = Settings.Secure.getString(getContentResolver(), "enabled_notification_listeners");
        return flat != null && flat.contains(new ComponentName(this, BankNotifications.class).flattenToString());
    }

    // ---- small views
    private int dp(int v) { return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()); }

    private TextView text(String s, int sp, int color) {
        TextView t = new TextView(this);
        t.setText(s); t.setTextSize(sp); t.setTextColor(color); t.setPadding(0, dp(4), 0, dp(4));
        t.setTextAlignment(View.TEXT_ALIGNMENT_VIEW_START);
        root.addView(t);
        return t;
    }

    private void title(String s) { TextView t = text(s, 22, 0xFF0F3B4C); t.setTypeface(Typeface.DEFAULT_BOLD); }

    private void section(String s) { TextView t = text(s, 18, 0xFF0F3B4C); t.setTypeface(Typeface.DEFAULT_BOLD); t.setPadding(0, dp(20), 0, dp(4)); }

    private void line(String s, boolean ok) { text((ok ? "✓ " : "• ") + s, 15, ok ? 0xFF067647 : 0xFFB54708); }

    private EditText input(String hint, int type) {
        TextView label = text(hint, 14, 0xFF1F2937);
        label.setPadding(0, dp(12), 0, dp(2));
        EditText e = new EditText(this);
        e.setInputType(type); e.setMinHeight(dp(48)); e.setTextColor(Color.BLACK);
        e.setContentDescription(hint);
        root.addView(e);
        return e;
    }

    private void button(String s, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(s); b.setMinHeight(dp(48)); b.setAllCaps(false);
        b.setOnClickListener(l);
        root.addView(b);
    }
}
