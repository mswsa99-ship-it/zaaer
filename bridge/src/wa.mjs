/** whatsapp-web.js ↔ the bridge core: the handful of WhatsApp actions an employee uses. */

/** a whatsapp-web.js Message → the plain shape the core reads */
export function toMsg(m) {
  return {
    id: m?.id?._serialized ?? null,
    chatId: m?.fromMe ? m?.to : m?.from,
    fromMe: !!m?.fromMe,
    type: m?.type,
    body: typeof m?.body === "string" ? m.body : "",
    timestamp: Number(m?.timestamp) || null,
    name: m?._data?.notifyName ?? null,
    isStatus: !!m?.isStatus,
    broadcast: !!m?.broadcast,
  };
}

export function waAdapter(client) {
  const chat = (id) => client.getChatById(id);
  return {
    /** { id } of the sent message; { id: null } when WhatsApp did not confirm it (the caller treats that as not sent) */
    async sendText(chatId, text) {
      const m = await client.sendMessage(chatId, text, { linkPreview: false });
      return { id: m?.id?._serialized ?? null };
    },
    /** WhatsApp Web's own connection state ("CONNECTED" when working) */
    async state() { return client.getState(); },
    async markSeen(chatId) { await client.sendSeen(chatId); },
    async typing(chatId) { await (await chat(chatId)).sendStateTyping(); },
    async clearTyping(chatId) { await (await chat(chatId)).clearState(); },
    /** the number behind a privacy id (…@lid), when WhatsApp gives it */
    async resolvePhone(chatId) {
      if (!chatId.endsWith("@lid")) return chatId.split("@")[0];
      const r = await client.getContactLidAndPhone([chatId]);
      const pn = r?.[0]?.pn;
      return pn ? String(pn).split("@")[0] : null;
    },
    /**
     * one-to-one chats with unread messages: their latest unread guest messages. A chat a receptionist marked unread
     * by hand (WhatsApp reports -1) has no unread message: it is theirs, and is left alone.
     */
    async unreadChats(maxPerChat = 5) {
      const out = [];
      for (const c of await client.getChats()) {
        const id = c?.id?._serialized ?? "";
        const unread = Number(c?.unreadCount) || 0;
        if (c.isGroup || unread <= 0 || !/^\d{5,20}@(c\.us|lid)$/.test(id)) continue;
        const msgs = await c.fetchMessages({ limit: Math.max(1, Math.min(unread, maxPerChat)), fromMe: false });
        out.push({ chatId: id, messages: msgs.slice(-Math.min(unread, maxPerChat)).map(toMsg) });
      }
      return out;
    },
  };
}
