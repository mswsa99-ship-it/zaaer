/**
 * Plan 3.3 — صفحة معرض المكوّنات: every approved base component (src/components/roomai.tsx over the rai-
 * classes) with its states, on the demo build only, at desktop and phone width. The owner reviews one screen;
 * the visual-comparison shots of the acceptance come from here. All content is invented.
 */
import { useState } from "react";
import { RaiButton, RaiField, RaiInput, RoomStatusPill, StatTile, AISuggestion, Notice, GuestFooter, ROOM_STATES, type RoomState } from "../components/roomai";
import { PRODUCT_NAME } from "../lib/designTokens";

function Section({ title, testId, children }: { title: string; testId: string; children: React.ReactNode }) {
  return (
    <section className="mb-8" data-testid={`gallery-${testId}`}>
      <h2 style={{ fontFamily: "var(--font-display)", fontSize: "20px", lineHeight: "28px", fontWeight: 600, margin: "0 0 12px" }}>{title}</h2>
      {children}
    </section>
  );
}

export default function DesignGallery() {
  const [dismissed, setDismissed] = useState(false);
  return (
    <div className="rai-page">
      <div className="rai-col" style={{ maxWidth: 720, margin: "0 auto" }}>
        <header>
          <h1 style={{ fontFamily: "var(--font-display)", fontSize: "24px", lineHeight: "32px", fontWeight: 600, margin: 0 }}>معرض مكوّنات {PRODUCT_NAME}</h1>
          <p style={{ color: "var(--ink-muted)", fontSize: "12px", margin: "4px 0 0" }}>المكوّنات الأساسية المعتمدة وحالاتها — بيانات مختلقة للعرض (البند 3.3)</p>
        </header>

        <Section title="الأزرار" testId="buttons">
          <div className="rai-row" style={{ padding: 0 }}>
            <RaiButton variant="primary">سجّل الوصول</RaiButton>
            <RaiButton>افتح الحجز</RaiButton>
            <RaiButton variant="quiet">تجاهل</RaiButton>
            <RaiButton variant="danger">احذف المسودة</RaiButton>
            <RaiButton variant="ai">اسأل المساعد</RaiButton>
            <RaiButton disabled>يُحفظ…</RaiButton>
            <RaiButton touch>هدف لمس ٤٤</RaiButton>
          </div>
        </Section>

        <Section title="الحقول" testId="fields">
          <div className="rai-row" style={{ padding: 0, alignItems: "flex-start" }}>
            <RaiField label="اسم النزيل" hint="كما في وثيقة الهوية">
              <RaiInput placeholder="مثال: سارة العتيبي" />
            </RaiField>
            <RaiField label="رقم الجوال" error="أضف إلى الجوال الرقم الناقص">
              <RaiInput defaultValue="050123" />
            </RaiField>
            <RaiField label="رقم الترخيص" locked hint="يقرؤه المالك والمدير فقط">
              <RaiInput defaultValue="HSP-DEMO-001" />
            </RaiField>
            <RaiField label="رقم الحجز" ltr>
              <RaiInput defaultValue="RSV-2026-00143" />
            </RaiField>
          </div>
        </Section>

        <Section title="حالات الوحدة" testId="pills">
          <div className="rai-row" style={{ padding: 0 }}>
            {(Object.keys(ROOM_STATES) as RoomState[]).map((s) => <RoomStatusPill key={s} state={s} />)}
          </div>
        </Section>

        <Section title="بلاطات الإحصاء" testId="stats">
          <div className="rai-row" style={{ padding: 0, alignItems: "stretch" }}>
            <StatTile label="الوصول اليوم" value={12} note="3 وصلوا حتى الآن" onOpen={() => {}} />
            <StatTile label="وحدات بانتظار التنظيف" value={5} note="أقدمها منذ 40 دقيقة" warning onOpen={() => {}} />
          </div>
        </Section>

        <Section title="اقتراح المساعد" testId="ai">
          {dismissed ? (
            <Notice kind="info">تم تجاهل الاقتراح. يبقى القرار للموظف دائمًا.</Notice>
          ) : (
            <AISuggestion
              body="الوحدة 204 متأخرة في التنظيف 40 دقيقة. هل أُبلغ المشرف؟"
              source="لوحة الوحدات، آخر تحديث قبل 5 دقائق"
              actLabel="أبلغ المشرف"
              onAct={() => setDismissed(true)}
              onIgnore={() => setDismissed(true)}
            />
          )}
        </Section>

        <Section title="التنبيهات" testId="notices">
          <div className="rai-col" style={{ padding: 0 }}>
            <Notice kind="success"><span><b>تم تسجيل الوصول.</b> دُفع المبلغ كاملًا، والرمز مع النزيل.</span></Notice>
            <Notice kind="warning"><span><b>بقي 300 ر.س.</b> على الحجز 1042 لم تُحصَّل بعد. حصّلها قبل تسليم الرمز.</span></Notice>
            <Notice kind="danger"><span><b>لم يُسجَّل الوصول.</b> على الحجز 300 ر.س لم تُحصَّل. حصّلها أو اطلب اعتماد الآجل من المدير.</span></Notice>
            <Notice kind="info"><span><b>نصيحة.</b> يمكنك تصدير قائمة اليوم من أعلى الصفحة.</span></Notice>
          </div>
        </Section>

        <Section title="بطاقة وجدول" testId="table">
          <div className="rai-card" style={{ padding: 0, overflow: "hidden" }}>
            <table style={{ width: "100%", fontSize: "14px", borderCollapse: "collapse" }}>
              <thead style={{ background: "var(--surface-sunken)", color: "var(--ink-muted)", fontSize: "12px" }}>
                <tr>
                  <th style={{ padding: "8px 12px", textAlign: "start", fontWeight: 500 }}>الوحدة</th>
                  <th style={{ padding: "8px 12px", textAlign: "start", fontWeight: 500 }}>الحالة</th>
                  <th style={{ padding: "8px 12px", textAlign: "start", fontWeight: 500 }}>السعر</th>
                </tr>
              </thead>
              <tbody>
                <tr style={{ borderTop: "1px solid var(--line)" }}>
                  <td style={{ padding: "8px 12px" }} className="rai-num">101</td>
                  <td style={{ padding: "8px 12px" }}><RoomStatusPill state="available" /></td>
                  <td style={{ padding: "8px 12px" }} className="rai-num">350.00 ر.س</td>
                </tr>
                <tr style={{ borderTop: "1px solid var(--line)" }}>
                  <td style={{ padding: "8px 12px" }} className="rai-num">102</td>
                  <td style={{ padding: "8px 12px" }}><RoomStatusPill state="occupied" /></td>
                  <td style={{ padding: "8px 12px" }} className="rai-num">420.00 ر.س</td>
                </tr>
              </tbody>
            </table>
          </div>
        </Section>

        <Section title="قاعدة النزيل" testId="guest">
          <div className="rai-guest" style={{ maxWidth: 390 }}>
            <div className="rai-guest-hero">
              <p className="rai-guest-hotel">فايف اورز</p>
              <p className="rai-guest-welcome">أهلًا بك. وحدتك جاهزة من الساعة 3 عصرًا.</p>
            </div>
            <div className="rai-guest-body">
              <div className="rai-card">بطاقة فوق أرضية النزيل تبقى surface.</div>
            </div>
            <GuestFooter />
          </div>
        </Section>
      </div>
    </div>
  );
}
