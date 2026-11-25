import { describe,it,expect } from "vitest";
import { parseGuestScope } from "../../src/lib/guestScope";
describe("guest hotel address",()=>{
 it("GT20 preserves deployment prefix and hotel address",()=>{
  expect(parseGuestScope("/zaaer/h/five-hours/booking/lookup","/zaaer/")).toEqual({slug:"five-hours",token:null,base:"/zaaer/h/five-hours",guest:true});
 });
 it("GT21 old one-booking links keep their capability and no guessed hotel",()=>{
  expect(parseGuestScope("/booking/status/ABC123")).toEqual({slug:null,token:"ABC123",base:"",guest:true});
 });
 it("GT22 staff routes are not guests and unknown malformed hotel paths do not create scope",()=>{
  expect(parseGuestScope("/staff/login").guest).toBe(false);
  expect(parseGuestScope("/h/a_b/booking/lookup").slug).toBe(null);
  expect(parseGuestScope("/h/a/booking/status/TOKEN").token).toBe("TOKEN");
  expect(parseGuestScope("/booking/review/REVIEW").token).toBe("REVIEW");
 });
});
