import { useState } from "react";
import { Navigate } from "react-router-dom";
import { useAuth } from "../../lib/auth";
import { supabase } from "../../lib/supabase";
import { Card, ErrorBanner, LoadingScreen } from "../../components/ui";
import { homeFor } from "../../lib/nav";
import { roomaiAsset } from "../../lib/brand";

export default function OwnerSetup() {
 const { session, profile, loading, isPlatformOperator, refreshProfile, signOut } = useAuth();
 const [form,setForm]=useState({full_name:"",name_ar:"",branch_name:"",slug:""});
 const [busy,setBusy]=useState(false);const [error,setError]=useState<string|null>(null);
 if(loading)return <LoadingScreen/>;
 if(!session)return <Navigate to="/staff/login" replace/>;
 if(isPlatformOperator)return <Navigate to="/platform" replace/>;
 if(profile)return <Navigate to={homeFor(profile.role)} replace/>;
 async function submit(e:React.FormEvent){e.preventDefault();setBusy(true);setError(null);
  const {error:e2}=await supabase.rpc("fn_owner_create_hotel",{p:form});
  if(e2){setError(/EMAIL_NOT_CONFIRMED/.test(e2.message)?"أكّد بريدك الإلكتروني أولًا ثم سجّل الدخول من جديد.":/ACCOUNT_PENDING_LINK/.test(e2.message)?"هذا البريد مرتبط بملف داخل فندق. تواصل مع مالكه لإكمال الربط.":"لم يُنشأ الفندق. تحقق من البيانات واسم الموقع، ثم أعد المحاولة.");}else await refreshProfile();
  setBusy(false);
 }
 return <main dir="rtl" className="min-h-screen bg-ink-50 px-4 py-10"><div className="mx-auto max-w-lg"><img src={roomaiAsset("roomai-logo.svg")} alt="RoomAI" className="mx-auto mb-6 h-12"/><Card><h1 className="text-xl font-bold">إنشاء فندقك</h1><p className="my-3 text-sm text-ink-500">بعد تأكيد بريدك، أنشئ فندقك وأول فرع. ستكون مالكه، ومن داخله تدعو إدارة الفروع. هذا النموذج لفندق جديد، ولا يتيح الدخول إلى فندق قائم.</p>{error&&<ErrorBanner message={error}/>}<form onSubmit={submit} className="grid gap-4">{([{key:"full_name",label:"اسم المالك الكامل",min:3},{key:"name_ar",label:"اسم الفندق",min:2},{key:"branch_name",label:"اسم أول فرع",min:2},{key:"slug",label:"اسم موقع الفندق (حروف لاتينية)",min:3}] as const).map(f=><label key={f.key} className="grid gap-1 text-sm">{f.label}<input className="input" required minLength={f.min} maxLength={f.key==="slug"?63:120} pattern={f.key==="slug"?"[a-z0-9][a-z0-9\\-]{2,62}":undefined} dir={f.key==="slug"?"ltr":undefined} value={form[f.key]} onChange={e=>setForm({...form,[f.key]:e.target.value})}/></label>)}<button className="btn-primary" disabled={busy}>{busy?"جارٍ الإنشاء…":"إنشاء الفندق وأول فرع"}</button></form><button className="btn-ghost mt-4" onClick={()=>void signOut()}>تسجيل الخروج</button></Card></div></main>;
}
