// Every regular .md file in issues/ is an issue. No content, status, or name-prefix filtering.
export function isIssueFileName(name) {
  if (typeof name !== "string" || name.length === 0) return false;
  if (name.includes("/") || name.includes("\\")) return false;
  return name.endsWith(".md");
}