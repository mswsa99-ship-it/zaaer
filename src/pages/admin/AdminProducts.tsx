/**
 * «المنتجات» (the guest journey, W1; migration 0068): the products a guest in their room can order — from WhatsApp or
 * through the reception — in categories, with a price and no stock. Each product is offered in the branches the owner
 * (or a manager, in their own branches) makes it available in. An order keeps the name and the price it was placed
 * with; changing a product here reaches the next orders only.
 */
import { useEffect, useMemo, useRef, useState } from "react";
import { Package, Plus, Pencil, Tags, ListPlus } from "lucide-react";
import { productsApi, toArabicError, type ProductsAdmin, type ProductRow, type ProductCategoryRow } from "../../lib/api";
import { SectionTitle, Card, Badge, Spinner, LoadErrorCard, EmptyState } from "../../components/ui";
import { Field, Modal, ActionForm, Submit, Toggle, MoneyInput } from "../../components/forms";
import { formatCurrency, COUNT } from "../../lib/utils";
import { parseProductList } from "../../lib/productImport";

const sar = (h: number) => formatCurrency(h / 100);


export default function AdminProducts() {
  const [data, setData] = useState<ProductsAdmin | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [product, setProduct] = useState<Partial<ProductRow> | null>(null);
  const [category, setCategory] = useState<Partial<ProductCategoryRow> | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [rowErr, setRowErr] = useState<string | null>(null);
  const [importing, setImporting] = useState(false);
  const reload = () => setTick((t) => t + 1);

  useEffect(() => {
    let alive = true; setError(null);
    productsApi.admin().then((d) => { if (alive) setData(d); }, (e) => { if (alive) setError(toArabicError(e)); });
    return () => { alive = false; };
  }, [tick]);

  async function toggleBranch(p: ProductRow, branchId: string, available: boolean) {
    setBusy(`${p.id}:${branchId}`); setRowErr(null);
    try { await productsApi.setBranch(p.id, branchId, available); reload(); } catch (e) { setRowErr(toArabicError(e)); } finally { setBusy(null); }
  }

  if (error && !data) return <LoadErrorCard message={error} onRetry={reload} />;
  if (!data) return <div className="py-10 text-center"><Spinner /></div>;
  const { categories, products, branches } = data;
  return (
    <div>
      <SectionTitle title="المنتجات" subtitle="منتجات بلا مخزون يطلبها النزيل المقيم من واتساب أو يطلبها له الاستقبال، ويُتاح كل منتج في الفروع التي تختارها" action={
        <div className="flex flex-wrap items-center gap-2">
          <button type="button" className="btn-outline text-sm" onClick={() => setImporting(true)}><ListPlus className="h-4 w-4" /> استيراد قائمة</button>
          <button type="button" className="btn-outline text-sm" onClick={() => setCategory({ name: "" })}><Tags className="h-4 w-4" /> فئة جديدة</button>
          <button type="button" className="btn-primary text-sm" disabled={categories.length === 0} title={categories.length === 0 ? "أضف فئة أولًا" : undefined}
            onClick={() => setProduct({ name: "", category_id: categories.find((c) => c.is_active)?.id ?? categories[0]?.id, taxable: true, price_halalas: null as unknown as number })}><Plus className="h-4 w-4" /> منتج جديد</button>
        </div>} />
      <p className="mb-4 rounded-xl border border-ink-100 bg-ink-50 p-3 text-sm text-ink-700" role="note">
        يطلب النزيل بإرسال «المنتجات» في واتساب الفرع، ويدفع لدى الاستقبال؛ عند الدفع يُصدر سند القبض وتُنشأ مهمة التسليم لغرفته. إيراد الطلبات في حساب «إيراد المنتجات».
      </p>
      {rowErr && <p className="mb-3 text-sm text-danger-600" role="alert">{rowErr}</p>}
      {categories.length === 0 ? (
        <EmptyState icon={<Package className="h-10 w-10" />} title="لا منتجات بعد" description="الصق قائمتك بزر «استيراد قائمة» (سطر لكل منتج: الفئة، المنتج، السعر)، أو ابدأ بفئة مثل «مشروبات» ثم أضف منتجاتها، ثم أتحها للفروع." />
      ) : (
        <div className="space-y-6" data-testid="product-catalogue">
          {categories.map((c) => {
            const items = products.filter((p) => p.category_id === c.id);
            return (
              <section key={c.id} aria-label={c.name} data-testid="product-category">
                <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <h2 className={`text-base font-semibold ${c.is_active ? "text-ink-800" : "text-ink-400 line-through"}`}>{c.name}</h2>
                    <Badge className="bg-ink-100 text-ink-600">{COUNT.product(items.length)}</Badge>
                    {!c.is_active && <Badge className="bg-warning-500/10 text-warning-700">موقوفة — لا تظهر للنزلاء</Badge>}
                  </div>
                  <button type="button" className="btn-ghost min-h-[44px] text-xs" onClick={() => setCategory(c)} aria-label={`تعديل الفئة ${c.name}`}><Pencil className="h-3.5 w-3.5" /> تعديل الفئة</button>
                </div>
                {items.length === 0 ? <p className="rounded-xl border border-dashed border-ink-200 p-3 text-sm text-ink-500">لا منتجات في هذه الفئة.</p> : (
                  <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                    {items.map((p) => (
                      <Card key={p.id} className={p.is_active ? "" : "opacity-60"} data-testid="product-card">
                        <div className="flex items-start justify-between gap-2">
                          <div className="min-w-0">
                            <div className="flex flex-wrap items-center gap-2"><h3 className="font-semibold text-ink-800">{p.name}</h3>{!p.is_active && <Badge className="bg-warning-500/10 text-warning-700">موقوف</Badge>}</div>
                            <p className="text-sm text-ink-700"><span dir="ltr" className="tabular-nums">{sar(p.price_halalas)}</span> <span className="text-xs text-ink-400">· {p.taxable ? "خاضع للضريبة" : "بدون ضريبة"}</span></p>
                            {p.description && <p className="mt-1 text-xs text-ink-500">{p.description}</p>}
                          </div>
                          <button type="button" onClick={() => setProduct(p)} className="btn-ghost min-h-[44px] min-w-[44px] justify-center p-0" aria-label={`تعديل ${p.name}`} title="تعديل"><Pencil className="h-4 w-4" /></button>
                        </div>
                        <fieldset className="mt-3 border-t border-ink-50 pt-2">
                          <legend className="sr-only">إتاحة {p.name} في الفروع</legend>
                          <p className="mb-1 text-xs text-ink-500">متاح في:</p>
                          <div className="flex flex-wrap gap-1">
                            {branches.map((b) => {
                              const on = p.branches.includes(b.id);
                              return (
                                <button key={b.id} type="button" role="switch" aria-checked={on} disabled={!b.mine || busy === `${p.id}:${b.id}`}
                                  title={b.mine ? undefined : "فرع لا تديره"} onClick={() => toggleBranch(p, b.id, !on)}
                                  className={`min-h-[44px] rounded-full border px-3 text-xs transition ${on ? "border-brand-500 bg-brand-50 font-medium text-brand-700" : "border-ink-100 text-ink-500 hover:border-ink-200"} disabled:cursor-not-allowed disabled:opacity-60`}>
                                  {on ? "✓ " : ""}{b.name}
                                </button>
                              );
                            })}
                          </div>
                        </fieldset>
                      </Card>
                    ))}
                  </div>
                )}
              </section>
            );
          })}
        </div>
      )}
      <Modal open={importing} title="استيراد قائمة منتجات" onClose={() => { setImporting(false); reload(); }} wide>
        {importing && <ImportForm data={data} onDone={() => { setImporting(false); reload(); }} />}
      </Modal>
      <Modal open={!!category} title={category?.id ? "تعديل فئة" : "فئة جديدة"} onClose={() => setCategory(null)}>
        {category && (
          <ActionForm onSubmit={async () => {
            await productsApi.upsertCategory({ id: category.id, name: (category.name ?? "").trim(), ...(category.sort_order != null ? { sort_order: category.sort_order } : {}),
              ...(category.id ? { is_active: category.is_active, version: category.version } : {}) });
            setCategory(null); reload();
          }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="اسم الفئة" className="sm:col-span-2"><input className="input" maxLength={40} value={category.name ?? ""} onChange={(e) => setCategory({ ...category, name: e.target.value })} aria-label="اسم الفئة" placeholder="مثال: مشروبات" /></Field>
              <Field label="الترتيب (اختياري)" hint="الأصغر يظهر أولًا للنزيل."><input className="input" dir="ltr" inputMode="numeric" value={category.sort_order ?? ""} onChange={(e) => setCategory({ ...category, sort_order: e.target.value === "" ? undefined : Number(e.target.value.replace(/\D/g, "").slice(0, 4)) })} aria-label="الترتيب" /></Field>
            </div>
            {category.id && <div className="mt-3"><Toggle checked={category.is_active ?? true} onChange={(v) => setCategory({ ...category, is_active: v })} label="فعالة (تظهر للنزلاء)" /></div>}
            <Submit label="حفظ" onCancel={() => setCategory(null)} />
          </ActionForm>
        )}
      </Modal>
      <Modal open={!!product} title={product?.id ? "تعديل منتج" : "منتج جديد"} onClose={() => setProduct(null)}>
        {product && (
          <ActionForm onSubmit={async () => {
            if (!product.price_halalas || product.price_halalas <= 0) throw new Error("VALIDATION: product_price");
            await productsApi.upsertProduct({ id: product.id, category_id: product.category_id ?? "", name: (product.name ?? "").trim(), description: product.description?.trim() || null,
              price_halalas: product.price_halalas, taxable: product.taxable ?? true,
              ...(product.id ? { is_active: product.is_active, version: product.version } : {}) });
            setProduct(null); reload();
          }}>
            <div className="grid gap-3 sm:grid-cols-2">
              <Field label="اسم المنتج" className="sm:col-span-2"><input className="input" maxLength={40} value={product.name ?? ""} onChange={(e) => setProduct({ ...product, name: e.target.value })} aria-label="اسم المنتج" /></Field>
              <Field label="الفئة"><select className="input" value={product.category_id ?? ""} onChange={(e) => setProduct({ ...product, category_id: e.target.value })} aria-label="الفئة">
                {categories.map((c) => <option key={c.id} value={c.id}>{c.name}{c.is_active ? "" : " (موقوفة)"}</option>)}</select></Field>
              <Field label="السعر" hint="كما يراه النزيل؛ وضريبة الفرع عليه كما على خدمات الإقامة."><MoneyInput valueHalalas={product.price_halalas ?? null} onChange={(h) => setProduct({ ...product, price_halalas: h as number })} label="السعر" /></Field>
              <Field label="الوصف (اختياري)" className="sm:col-span-2" hint="سطر قصير يظهر للنزيل تحت الاسم (200 حرف على الأكثر)."><input className="input" maxLength={200} value={product.description ?? ""} onChange={(e) => setProduct({ ...product, description: e.target.value })} aria-label="الوصف" /></Field>
            </div>
            <div className="mt-3 flex flex-wrap gap-4">
              <Toggle checked={product.taxable ?? true} onChange={(v) => setProduct({ ...product, taxable: v })} label="خاضع للضريبة" />
              {product.id && <Toggle checked={product.is_active ?? true} onChange={(v) => setProduct({ ...product, is_active: v })} label="فعال (يظهر للنزلاء)" />}
            </div>
            {!product.id && <p className="mt-3 text-xs text-ink-500">بعد الحفظ أتح المنتج للفروع من بطاقته.</p>}
            <Submit label="حفظ" onCancel={() => setProduct(null)} />
          </ActionForm>
        )}
      </Modal>
    </div>
  );
}

/** «استيراد قائمة»: the owner pastes the list once; the categories that do not exist yet are made, then the products,
 *  then each is made available in the branches ticked. Every step goes through the same functions (and the same log)
 *  as the forms above; a line that fails says why, the others stay done. */
function ImportForm({ data, onDone }: { data: ProductsAdmin; onDone: () => void }) {
  const [text, setText] = useState("");
  const mine = data.branches.filter((b) => b.mine);
  const [branches, setBranches] = useState<string[]>(mine.map((b) => b.id));
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<Record<number, string | true>>({});
  const lines = useMemo(() => parseProductList(text, data.products.map((p) => p.name)), [text, data.products]);
  // what an earlier run of this list already made: a retry goes on from there
  const made = useRef({ cats: new Map<string, string>(), products: new Map<number, string>(), branches: new Set<string>() });
  const todo = lines.filter((l) => !l.problem && !l.existing && results[l.n] !== true);
  const known = new Set(data.categories.map((c) => c.name.trim().toLowerCase()));
  const newCats = [...new Map(todo.filter((l) => !known.has(l.category.toLowerCase())).map((l) => [l.category.toLowerCase(), l.category] as const)).values()];
  const done = Object.values(results).filter((r) => r === true).length;
  const failed = Object.values(results).filter((r) => r !== true).length;

  async function run() {
    setBusy(true);
    const cats = new Map([...data.categories.map((c) => [c.name.trim().toLowerCase(), c.id] as const), ...made.current.cats]);
    const out: Record<number, string | true> = { ...results };
    for (const l of todo) {
      try {
        let cid = cats.get(l.category.toLowerCase());
        if (!cid) { cid = (await productsApi.upsertCategory({ name: l.category })).id; cats.set(l.category.toLowerCase(), cid); made.current.cats.set(l.category.toLowerCase(), cid); }
        let pid = made.current.products.get(l.n);
        if (!pid) { pid = (await productsApi.upsertProduct({ category_id: cid, name: l.name, price_halalas: l.price!, description: l.description, taxable: true })).id; made.current.products.set(l.n, pid); }
        for (const b of branches) if (!made.current.branches.has(`${pid}:${b}`)) { await productsApi.setBranch(pid, b, true); made.current.branches.add(`${pid}:${b}`); }
        out[l.n] = true;
      } catch (e) { out[l.n] = toArabicError(e); }
      setResults({ ...out });
    }
    setBusy(false);
    if (Object.values(out).every((r) => r === true)) onDone();
  }

  return (
    <div>
      <Field label="القائمة" hint="سطر لكل منتج: الفئة، اسم المنتج، السعر بالريال، ثم الوصف إن وُجد. مثال: مشروبات، ماء صغير، 2">
        <textarea className="input font-normal" rows={8} value={text} onChange={(e) => { setText(e.target.value); setResults({}); made.current.products.clear(); }} aria-label="القائمة"
          placeholder={"مشروبات، ماء صغير، 2\nمشروبات، قهوة، 5، ظرفان مع كوب\nمستلزمات شخصية، شاحن جوال، 25"} />
      </Field>
      {mine.length > 0 && (
        <fieldset className="mt-3">
          <legend className="mb-1 text-sm text-ink-700">أتح المنتجات المستوردة في:</legend>
          <div className="flex flex-wrap gap-3">
            {mine.map((b) => (
              <label key={b.id} className="flex min-h-[44px] items-center gap-2 text-sm">
                <input type="checkbox" checked={branches.includes(b.id)} onChange={(e) => setBranches((x) => (e.target.checked ? [...x, b.id] : x.filter((y) => y !== b.id)))} /> {b.name}
              </label>
            ))}
          </div>
        </fieldset>
      )}
      {lines.length > 0 && (
        <div className="mt-3" data-testid="import-preview">
          <p className="mb-2 text-sm text-ink-700">
            {todo.length ? `سيُضاف ${COUNT.product(todo.length)}.${newCats.length ? ` ${newCats.length === 1 ? "وتُنشأ فئة" : "وتُنشأ فئات"}: ${newCats.join("، ")}.` : ""}` : "لا شيء جديد للإضافة."}
            {lines.some((l) => l.existing) ? " الموجود من قبل يُترك كما هو." : ""}
          </p>
          <ul className="max-h-64 divide-y divide-ink-50 overflow-y-auto rounded-xl border border-ink-100 text-sm">
            {lines.map((l) => {
              const r = results[l.n];
              return (
                <li key={l.n} className="flex flex-wrap items-baseline justify-between gap-2 px-3 py-2" data-testid="import-line">
                  <span className="min-w-0"><span className="text-ink-400 tabular-nums" dir="ltr">{l.n}</span> {l.name || "—"} <span className="text-xs text-ink-500">· {l.category || "—"}</span></span>
                  <span className="text-xs">
                    {l.problem ? <span className="text-danger-600">{l.problem}</span>
                      : l.existing ? <span className="text-ink-500">موجود — يُترك</span>
                      : r === true ? <span className="text-success-700">أُضيف</span>
                      : r ? <span className="text-danger-600">{r}</span>
                      : <span dir="ltr" className="tabular-nums text-ink-700">{sar(l.price!)}</span>}
                  </span>
                </li>
              );
            })}
          </ul>
        </div>
      )}
      {failed > 0 && <p className="mt-2 text-sm text-danger-600" role="alert">أُضيف {COUNT.product(done)}، وتعذّر {COUNT.product(failed)}؛ سبب كل منها بجانبه. اضغط «استيراد» لإعادة المحاولة لما تعذّر فقط (ما أُضيف يُترك).</p>}
      <div className="mt-4 flex flex-wrap justify-end gap-2">
        <button type="button" className="btn-primary" disabled={busy || todo.length === 0} onClick={run}>{busy ? "جارٍ الاستيراد…" : todo.length ? `استيراد (${todo.length})` : "استيراد"}</button>
      </div>
    </div>
  );
}
