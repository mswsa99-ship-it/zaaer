import {describe,it,expect} from "vitest";
import {ownerPasswordProblem,emptyOwnerDraft} from "../../src/lib/ownerRegistration";
describe("owner registration password and nonsecret draft",()=>{
 it("requires long mixed case digits symbol and confirmation",()=>{for(const p of ["abcdef","abcdefgh1234!","ABCDEFGHI1234!","Abcdefghijkl!","Abcdefgh12345","Abcdefgh1234! "])expect(ownerPasswordProblem(p,p)).not.toBeNull();expect(ownerPasswordProblem("Abcdefgh1234!","different")).not.toBeNull();expect(ownerPasswordProblem("Abcdefgh1234!","Abcdefgh1234!")).toBeNull();});
 it("never puts credentials or codes in the saved owner draft",()=>{expect(Object.keys(emptyOwnerDraft()).sort()).toEqual(["full_name","name_ar"]);});
});
