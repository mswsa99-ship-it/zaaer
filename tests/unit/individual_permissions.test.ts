import { describe, expect, it } from "vitest";
import { EMPTY_INDIVIDUAL, individualAllows, validatePageGrants, type IndividualPermissions } from "../../src/lib/individualPermissions";
const grants: IndividualPermissions = { mode:"individual",revision:1,pages:{"/staff/reservations":{view:true,export:true,edit:false}},sensitive:[],homePage:null };
describe("individual page grant decisions",()=>{
 it("legacy mode is never an implicit individual allow",()=>expect(individualAllows(EMPTY_INDIVIDUAL,"/staff/reservations","view")).toBe(false));
 it("view does not grant add edit delete",()=>{for(const action of ["add","edit","delete"] as const)expect(individualAllows(grants,"/staff/reservations",action)).toBe(false);});
 it("explicit export is independent",()=>expect(individualAllows(grants,"/staff/reservations","export")).toBe(true));
 it("requires view even for malformed stored exports",()=>expect(individualAllows({...grants,pages:{"/staff/reservations":{export:true}}},"/staff/reservations","export")).toBe(false));
 it("unknown page is denied",()=>expect(individualAllows(grants,"/admin/unknown","view")).toBe(false));
 it("accepts a valid known page",()=>expect(validatePageGrants(grants.pages)).toBe(true));
 it.each([null,[],{"/admin/unknown":{view:true}},{"/staff/reservations":{add:true}},{"/staff/reservations":{view:"true"}},{"/staff/reservations":{view:true,promote:true}}])("rejects malformed grants %j",value=>expect(validatePageGrants(value)).toBe(false));
});

import { parseIndividualPermissions } from "../../src/lib/individualPermissions";
import { pageFor, pageAllowed, unifiedMenu } from "../../src/lib/nav";
it("malformed server individual response never becomes legacy",()=>expect(()=>parseIndividualPermissions({mode:"individual",pages:{},revision:"1",sensitive:[]})).toThrow());
it("server predating grants preserves legacy",()=>expect(parseIndividualPermissions(undefined).mode).toBe("legacy"));
it("explicit grants override role menu, without granting writes",()=>{
 const allows={can:()=>false,canFull:()=>false,pageAccess:grants};
 expect(pageAllowed(pageFor('/staff/reservations')!,"housekeeping",allows)).toBe(true);
 expect(pageAllowed(pageFor('/admin/staff')!,"manager",allows)).toBe(false);
 expect(unifiedMenu("housekeeping",allows).map(p=>p.path)).toEqual(["/staff/reservations"]);
});

it("detail and create pages inherit reservation grants",()=>{
 expect(individualAllows(grants,"/staff/reservations/:id","view")).toBe(true);
 expect(individualAllows(grants,"/staff/reservations/new","add")).toBe(false);
 expect(pageAllowed(pageFor("/staff/reservations/new")!,"housekeeping",{pageAccess:grants})).toBe(true);
});
