import { individualAllows, type IndividualPermissions } from "./individualPermissions";
/** 0075 (plan item 1.8): who reads a unit's licence number — the server's fn_room_licenses asks the same three roles. */
export const UNIT_LICENSE_READERS: readonly string[] = ["owner", "manager", "supervisor"];
export const readsUnitLicense = (role: string | null | undefined) => !!role && UNIT_LICENSE_READERS.includes(role);

/**
 * Existing reads are kept (the three roles). Added: an individual non-owner account that may EDIT the rooms page also reads it, whatever the role
 * (the user's 06:12 decision: room editors edit the number, and they must see it to do so). The server (fn_room_licenses) asks the same.
 * Legacy accounts and the owner are unchanged.
 */
export const readsUnitLicenseFor = (role: string | null | undefined, access: IndividualPermissions | null | undefined) =>
  readsUnitLicense(role) || (access?.mode === "individual" && role !== "owner" && individualAllows(access, "/admin/rooms", "edit"));

/** Item 6 (user 2026-11-25 06:19): «Add» on the rooms page is enough to enter the licence while creating a unit; the server saves unit and licence together. */
export const setsUnitLicenseOnCreate = (role: string | null | undefined, access: IndividualPermissions | null | undefined) =>
  readsUnitLicenseFor(role, access) || (access?.mode === "individual" && role !== "owner" && individualAllows(access, "/admin/rooms", "add"));
