/** 0075 (plan item 1.8): who reads a unit's licence number — the server's fn_room_licenses asks the same three roles. */
export const UNIT_LICENSE_READERS: readonly string[] = ["owner", "manager", "supervisor"];
export const readsUnitLicense = (role: string | null | undefined) => !!role && UNIT_LICENSE_READERS.includes(role);
