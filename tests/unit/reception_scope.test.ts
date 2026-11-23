import { describe,it,expect } from "vitest";
import { mayResumeConversation, bookingMatchesScope, aiBudgetAvailable } from "../../supabase/functions/_shared/reception_scope";
const a={organizationId:"A",branchId:"a1",guestToken:"token-a"};
const c={organization_id:"A",branch_id:"a1",guest_token:"token-a",client_fingerprint:"fp-a",channel:"screen"};
const p={trustedService:false,staff:false,fingerprint:"fp-a",channel:"screen"};
describe("two-hotel assistant context",()=>{
 it("allows a current capability only in its own hotel and branch",()=>{
  expect(mayResumeConversation(c,a,p)).toBe(true);
  expect(mayResumeConversation(c,{...a,organizationId:"B"},p)).toBe(false);
  expect(mayResumeConversation(c,{...a,branchId:"a2"},p)).toBe(false);
 });
 it("conversation id never supplies a booking token",()=>{
  expect(mayResumeConversation(c,{...a,guestToken:null},p)).toBe(false);
  expect(mayResumeConversation(c,{...a,guestToken:"token-b"},p)).toBe(false);
 });
 it("a service call cannot cross the authenticated branch",()=>{
  expect(mayResumeConversation(c,a,{...p,trustedService:true})).toBe(true);
  expect(mayResumeConversation(c,{...a,organizationId:"B"},{...p,trustedService:true})).toBe(false);
 });
 it("unverified conversations require the same browser and channel",()=>{
  expect(mayResumeConversation({...c,guest_token:null},a,p)).toBe(true);
  expect(mayResumeConversation({...c,guest_token:null},a,{...p,fingerprint:"fp-b"})).toBe(false);
  expect(mayResumeConversation(c,a,{...p,channel:"whatsapp"})).toBe(false);
 });
 it("a booking cannot enter another hotel context",()=>{
  expect(bookingMatchesScope({organization_id:"A",branch_id:"a1"},a)).toBe(true);
  expect(bookingMatchesScope({organization_id:"B",branch_id:"b1"},a)).toBe(false);
 });
 it("hotel A exhaustion never consumes hotel B counters",()=>{
  const settings={daily_request_limit:2,ops_daily_request_limit:1,daily_token_budget:100};
  expect(aiBudgetAvailable(settings,{requests:2,tokens_in:100})).toBe(false);
  expect(aiBudgetAvailable(settings,{requests:0,tokens_in:0})).toBe(true);
  expect(aiBudgetAvailable(settings,{requests:3},true)).toBe(false);
 });
});
