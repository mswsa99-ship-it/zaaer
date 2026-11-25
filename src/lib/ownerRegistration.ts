export interface OwnerRegistrationDraft { full_name:string; name_ar:string }
export const emptyOwnerDraft=():OwnerRegistrationDraft=>({full_name:"",name_ar:""});
export function ownerPasswordProblem(password:string,confirm:string):string|null {
 if(new TextEncoder().encode(password).length>72)return "كلمة المرور أطول من 72 بايت.";
 if(password.length<12||!/[a-z]/.test(password)||!/[A-Z]/.test(password)||!/[0-9]/.test(password)||!Array.from(password).some(c=>"!@#$%^&*()_+={}[]:;,.?~-".includes(c))||/\s/.test(password))return "استخدم 12 حرفًا على الأقل، بحروف إنجليزية كبيرة وصغيرة وأرقام ورمز، دون مسافات.";
 return password!==confirm?"كلمتا المرور غير متطابقتين.":null;
}
export const OWNER_DRAFT_KEY="roomai.owner.registration.v1";
