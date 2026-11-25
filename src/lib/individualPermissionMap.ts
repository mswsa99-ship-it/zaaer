// Local engineering proposal, individual activation remains disabled. Must match migration 0112.
import type { PageAction } from "./individualPermissions";
export const INDIVIDUAL_PERMISSION_MAP: Record<string, {page:string;action:PageAction;sensitive:boolean}> = {
  "res.create": {
    "page": "/staff/reservations",
    "action": "add",
    "sensitive": false
  },
  "disc.before": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "disc.after": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "price.adjust": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "charges.add": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": false
  },
  "stay.extend": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": false
  },
  "room.assign": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": false
  },
  "checkin": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": false
  },
  "checkout": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": false
  },
  "inspection": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": false
  },
  "res.cancel": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "res.undo_cancel": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "hold.set": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "hold.lift": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "code.deliver": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "checkin.undo": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "stay.reopen": {
    "page": "/staff/reservations",
    "action": "edit",
    "sensitive": true
  },
  "guest.enter": {
    "page": "/staff/identity-verification",
    "action": "edit",
    "sensitive": false
  },
  "identity.approve": {
    "page": "/staff/identity-verification",
    "action": "edit",
    "sensitive": false
  },
  "shomoos": {
    "page": "/staff/identity-verification",
    "action": "edit",
    "sensitive": false
  },
  "guest.ban": {
    "page": "/admin/guests",
    "action": "edit",
    "sensitive": true
  },
  "guest.rate": {
    "page": "/admin/guests",
    "action": "edit",
    "sensitive": true
  },
  "voucher.receipt": {
    "page": "/staff/payments",
    "action": "add",
    "sensitive": false
  },
  "invoice.issue": {
    "page": "/staff/payments",
    "action": "add",
    "sensitive": false
  },
  "voucher.refund": {
    "page": "/staff/payments",
    "action": "edit",
    "sensitive": true
  },
  "deposit.refund": {
    "page": "/staff/payments",
    "action": "edit",
    "sensitive": true
  },
  "damage.charge": {
    "page": "/staff/payments",
    "action": "edit",
    "sensitive": true
  },
  "deposit.apply": {
    "page": "/staff/payments",
    "action": "edit",
    "sensitive": true
  },
  "voucher.correct": {
    "page": "/staff/payments",
    "action": "edit",
    "sensitive": true
  },
  "voucher.cancel": {
    "page": "/staff/payments",
    "action": "edit",
    "sensitive": true
  },
  "invoice.edit": {
    "page": "/staff/payments",
    "action": "edit",
    "sensitive": true
  },
  "pos.settle": {
    "page": "/staff/pos-settlement",
    "action": "edit",
    "sensitive": false
  },
  "platform.payouts": {
    "page": "/admin/platform-payouts",
    "action": "edit",
    "sensitive": true
  },
  "day.close": {
    "page": "/staff/day-close",
    "action": "edit",
    "sensitive": false
  },
  "day.close.approve": {
    "page": "/staff/day-close",
    "action": "edit",
    "sensitive": true
  },
  "expense.create": {
    "page": "/staff/expenses",
    "action": "add",
    "sensitive": false
  },
  "expense.cancel": {
    "page": "/staff/expenses",
    "action": "edit",
    "sensitive": true
  },
  "ledger.view": {
    "page": "/staff/ledger",
    "action": "view",
    "sensitive": false
  },
  "rates": {
    "page": "/admin/rates",
    "action": "edit",
    "sensitive": false
  },
  "branch.tax": {
    "page": "/admin/branches",
    "action": "edit",
    "sensitive": true
  },
  "cash_accounts": {
    "page": "/admin/cash-accounts",
    "action": "edit",
    "sensitive": true
  },
  "policies": {
    "page": "/admin/policies",
    "action": "edit",
    "sensitive": false
  },
  "knowledge": {
    "page": "/admin/knowledge",
    "action": "edit",
    "sensitive": false
  },
  "task.work": {
    "page": "/staff/housekeeping",
    "action": "edit",
    "sensitive": false
  },
  "cleanliness": {
    "page": "/staff/housekeeping",
    "action": "edit",
    "sensitive": false
  },
  "task.manage": {
    "page": "/staff/housekeeping",
    "action": "edit",
    "sensitive": true
  },
  "keybox.code": {
    "page": "/staff/codes",
    "action": "edit",
    "sensitive": true
  },
  "maintenance.create": {
    "page": "/staff/tickets",
    "action": "add",
    "sensitive": false
  },
  "maintenance.resolve": {
    "page": "/staff/tickets",
    "action": "edit",
    "sensitive": false
  },
  "conversation.take": {
    "page": "/staff/inbox",
    "action": "edit",
    "sensitive": false
  },
  "staff.manage": {
    "page": "/admin/staff",
    "action": "edit",
    "sensitive": true
  },
  "staff.force_logout": {
    "page": "/admin/staff",
    "action": "edit",
    "sensitive": true
  },
  "review.list": {
    "page": "/admin/review",
    "action": "view",
    "sensitive": false
  },
  "reports.finance": {
    "page": "/admin/reports",
    "action": "view",
    "sensitive": false
  },
  "accounts.view": {
    "page": "/staff/accounts",
    "action": "view",
    "sensitive": false
  },
  "accounts.close_month": {
    "page": "/staff/accounts",
    "action": "edit",
    "sensitive": true
  },
  "bank.view": {
    "page": "/staff/bank",
    "action": "view",
    "sensitive": false
  },
  "bank.manage": {
    "page": "/admin/bank-mail",
    "action": "edit",
    "sensitive": true
  },
  "audit.log": {
    "page": "/admin/audit-logs",
    "action": "view",
    "sensitive": false
  },
  "payment.settings": {
    "page": "/admin/payment-providers",
    "action": "edit",
    "sensitive": true
  },
  "history.details": {
    "page": "/staff/reservations",
    "action": "view",
    "sensitive": true
  }
};
