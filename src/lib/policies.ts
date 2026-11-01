/** The policy topics (0056): «أخرى» carries its own name, typed in «السياسات». */
export const POLICY_TOPICS: Record<string, string> = {
  checkin: "الوصول والمغادرة", cancellation: "الإلغاء", wifi: "الإنترنت", parking: "المواقف", location: "الموقع",
  children: "الأطفال والمرافقون", contact: "التواصل", stay: "شروط الإقامة", privacy: "الخصوصية", other: "أخرى",
};
export const policyTopic = (p: { topic: string; topic_label?: string | null }) => (p.topic === "other" && p.topic_label ? p.topic_label : POLICY_TOPICS[p.topic] ?? p.topic);
