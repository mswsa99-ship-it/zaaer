/**
 * Plan 3.4 — الاسم RoomAI في كل ما يراه الموظف. The one source for the product name and its assets.
 * The name is fixed by the approved identity (README «الاسم»): one word, R and A and I capital, Latin letters
 * even inside an Arabic sentence. The hotel's name stays the hotel's data.
 */
import { PRODUCT_NAME, POWERED_BY } from "./designTokens";

export { PRODUCT_NAME, POWERED_BY };

/** The original approved logo files (public/roomai/, copied byte-exact). Resolves in the demo (./) and production (/). */
export function roomaiAsset(file: "roomai-logo.svg" | "roomai-logo-reversed.svg" | "roomai-mark.svg" | "roomai-mark-reversed.svg" | "roomai-app-icon.svg" | "roomai-wordmark.svg"): string {
  return `${import.meta.env.BASE_URL}roomai/${file}`;
}
