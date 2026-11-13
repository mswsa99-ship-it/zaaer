/**
 * A9: the email the phone app writes (tests/android/fixtures/relay-sample.eml, produced by the app's own code in
 * tests/android/run.sh, RL06) is read by the bank-mail function as the server expects: from the app's mailbox, the
 * v1 body, a signature that checks with the relay key, the bank's text unchanged.
 */
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { createHmac } from "node:crypto";
import { readMail } from "../../supabase/functions/_shared/mime";
import { setupText, smtpFor, setupProblem } from "../../src/lib/relaySetup";

const KEY = "0123456789abcdef0123456789abcdef0123456789abcdef";   // the test key of RelayCoreTests, not a real one

describe("the phone app's email (A9)", () => {
  it("RL10 the bank-mail function reads the app's email: from its mailbox, the v1 body whose signature checks with the relay key, the text as the bank wrote it", () => {
    const raw = readFileSync("tests/android/fixtures/relay-sample.eml", "latin1");
    const m = readMail(raw);
    expect(m.from).toBe("<relay.test@example.com>");
    expect(m.subject).toBe("FIVEHOURS-RELAY");
    expect(m.date).toBe("2026-11-13T06:12:00.000Z");
    const cut = m.body.indexOf("\n---\n");
    const head = Object.fromEntries(m.body.slice(0, cut).split("\n").slice(1).map((l) => [l.slice(0, l.indexOf(":")), l.slice(l.indexOf(":") + 1).trim()]));
    const text = m.body.slice(cut + 5);
    expect(m.body.split("\n")[0]).toBe("FIVEHOURS-RELAY 1");
    expect(head).toMatchObject({ sender: "AlRajhiBank", received: "2026-11-13T09:12:00+03:00", channel: "sms" });
    const sig = createHmac("sha256", KEY).update([head.sender, head.received, head.channel, text].join("\n"), "utf8").digest("hex");
    expect(head.signature).toBe(sig);
    expect(text).toBe("حوالة واردة\nمبلغ: ٤٥٠ SAR\nإلى: 605****4321\nرقم المرجع: AND1001\n13/11/26 09:12");
  });
});

describe("the setup text «بريد البنك» makes for the phone (A9)", () => {
  it("RL12 the setup text carries the mailbox, its SMTP server, the senders and each branch's account rule, the key only when given — the format the app reads (RelayCoreTests RL01)", () => {
    const s = { mailbox_address: "relay.test@example.com", imap_host: "imap.gmail.com", allowed_senders: ["AlRajhiBank", "الراجحي"],
      accounts: [{ id: "1", branch: "أ", name: "بنك أ", prefix: "605", suffix: "4321" }, { id: "2", branch: "ب", name: "بنك ب", prefix: null, suffix: null }] };
    expect(setupText(s)).toBe("FIVEHOURS-SETUP 1\nmailbox: relay.test@example.com\nsmtp: smtp.gmail.com:465\nsenders: AlRajhiBank, الراجحي\naccount: 605…4321\n");
    expect(setupText(s, "abc123abc123abc123")).toMatch(/\nkey: abc123abc123abc123\n$/);
    expect(smtpFor("mail.example.org")).toBe("mail.example.org:465");
    expect(setupProblem(s)).toBeNull();
    expect(setupProblem({ ...s, mailbox_address: null })).toBe("mailbox");
    expect(setupProblem({ ...s, accounts: [s.accounts[1]] })).toBe("accounts");
  });
});
