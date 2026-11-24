export function canonicalPermissionPage(path: string): string {
 if (path === "/staff/reservations/new" || path === "/staff/reservations/:id") return "/staff/reservations";
 if (path === "/admin/guests/:id") return "/admin/guests";
 return path;
}
