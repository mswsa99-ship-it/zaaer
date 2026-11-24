/**
 * 6.12 (U5 سرعة المساعد): وعد بحد زمني أعلى واضح. بعد `ms` يحصل المستدعي على قيمة `onTimeoutValue` مرة واحدة؛
 * الرد المتأخر بعد الحد يُهمل (المستدعي سمع رسالة الحد فعلًا) ولا يُحدث رفضًا غير معالَج.
 */
export function withTimeout<T>(p: Promise<T>, ms: number, onTimeoutValue: () => T, onTimeout?: () => void): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { onTimeout?.(); } catch { /* the timeout value still reaches the caller */ }
      resolve(onTimeoutValue());
    }, ms);
    p.then(
      (v) => { if (settled) return; settled = true; clearTimeout(timer); resolve(v); },
      (e) => { if (settled) return; settled = true; clearTimeout(timer); reject(e); },
    );
  });
}
