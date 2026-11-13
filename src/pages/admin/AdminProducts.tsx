/**
 * «المنتجات» (the guest journey, W1; migration 0068): the products a guest in their room can order — from WhatsApp or
 * through the reception — in categories, with a price and no stock. Each product is offered in the branches the owner
 * (or a manager, in their own branches) makes it available in. An order keeps the name and the price it was placed
 * with; changing a product here reaches the next orders only.
 */
import { useEffect, useState } from "react";
import { Package, Plus, Pencil, Tags } from "lucide-react";
import { productsApi, toArabicError, type ProductsAdmin, type ProductRow, type ProductCategoryRow } from "../../lib/api";
import { SectionTitle, Card, Badge, Spinner, LoadErrorCard, EmptyState } from "../../components/ui";
import { Field, Modal, ActionForm, Submit, Toggle, MoneyInput } from "../../components/forms";
import { formatCurrency } from "../../lib/utils";

const sar = (h: number) => formatCurrency(h / 100);
/** Arabic counting: لا منتجات، منتج واحد، منتجان، 3–10 منتجات، 11+ منتجًا */
export const productsCount = (n: number) => (n === 0 ? "لا منتجات" : n === 1 ? "منتج واحد" : n === 2 ? "منتجان" : n <= 10 ? `${n} منتجات` : `${n} منتجًا`);

export default function AdminProducts() {
  const [data, setData] = useState<ProductsAdmin | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const [product, setProduct] = useState<Partial<ProductRow> | null>(null);
  const [category, setCategory] = useState<Partial<ProductCategoryRow> | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [rowErr, setRowErr] = useState<string | null>(null);
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
          <button type="button" className="btn-outline text-sm" onClick={() => setCategory({ name: "" })}><Tags className="h-4 w-4" /> فئة جديدة</button>
          <button type="button" className="btn-primary text-sm" disabled={categories.length === 0} title={categories.length === 0 ? "أضف فئة أولًا" : undefined}
            onClick={() => setProduct({ name: "", category_id: categories.find((c) => c.is_active)?.id ?? categories[0]?.id, taxable: true, price_halalas: null as unknown as number })}><Plus className="h-4 w-4" /> منتج جديد</button>
        </div>} />
      <p className="mb-4 rounded-xl border border-ink-100 bg-ink-50 p-3 text-sm text-ink-700" role="note">
        يطلب النزيل بإرسال «المنتجات» في واتساب الفرع، ويدفع لدى الاستقبال؛ عند الدفع يُصدر سند القبض وتُنشأ مهمة التسليم لغرفته. إيراد الطلبات في حساب «إيراد المنتجات».
      </p>
      {rowErr && <p className="mb-3 text-sm text-danger-600" role="alert">{rowErr}</p>}
      {categories.length === 0 ? (
        <EmptyState icon={<Package className="h-10 w-10" />} title="لا منتجات بعد" description="ابدأ بفئة مثل «مشروبات» أو «مستلزمات شخصية»، ثم أضف منتجاتها بأسعارها، ثم أتحها للفروع." />
      ) : (
        <div className="space-y-6" data-testid="product-catalogue">
          {categories.map((c) => {
            const items = products.filter((p) => p.category_id === c.id);
            return (
              <section key={c.id} aria-label={c.name} data-testid="product-category">
                <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <h2 className={`text-base font-semibold ${c.is_active ? "text-ink-800" : "text-ink-400 line-through"}`}>{c.name}</h2>
                    <Badge className="bg-ink-100 text-ink-600">{productsCount(items.length)}</Badge>
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
                          <button type="button" onClick={() => setProduct(p)} className="btn-ghost p-1.5" aria-label={`تعديل ${p.name}`} title="تعديل"><Pencil className="h-4 w-4" /></button>
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
                                  className={`min-h-[36px] rounded-full border px-3 text-xs transition ${on ? "border-brand-500 bg-brand-50 font-medium text-brand-700" : "border-ink-100 text-ink-500 hover:border-ink-200"} disabled:cursor-not-allowed disabled:opacity-60`}>
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
