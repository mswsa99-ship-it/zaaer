/** Uploaded raster logos or HTTPS assets only. Never render SVG or executable URL schemes. */
export function guestLogoSource(value: string | null | undefined): string | null {
  if (!value) return null;
  if (/^data:image\/(?:png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(value)) return value;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password ? value : null;
  } catch { return null; }
}
