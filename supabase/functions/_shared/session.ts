import { serviceClient } from "./supabase.ts";

export class SessionError extends Error {
  status: number;

  constructor(message: string, status = 401) {
    super(message);
    this.name = "SessionError";
    this.status = status;
  }
}

export async function sha256Hex(value: string) {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export function bearerFromRequest(request: Request) {
  const raw = request.headers.get("x-routevault-session") ??
    request.headers.get("authorization") ?? "";
  const trimmed = raw.replace(/^Bearer\s+/i, "").trim();
  return trimmed.length > 0 ? trimmed : null;
}

export async function requireAccountSession(request: Request) {
  const rawToken = bearerFromRequest(request);
  if (!rawToken) {
    throw new SessionError("Missing Terigo account session.");
  }

  return await loadAccountSession(rawToken);
}

export async function optionalAccountSession(request: Request) {
  const rawToken = bearerFromRequest(request);
  if (!rawToken) {
    return null;
  }

  try {
    return await loadAccountSession(rawToken);
  } catch {
    return null;
  }
}

async function loadAccountSession(rawToken: string) {
  if (!rawToken) {
    throw new SessionError("Missing Terigo account session.");
  }

  const tokenHash = await sha256Hex(rawToken);
  const supabase = serviceClient();
  const now = new Date().toISOString();

  const { data, error } = await supabase
    .from("app_sessions")
    .select("id, account_id, expires_at")
    .eq("session_token_hash", tokenHash)
    .gt("expires_at", now)
    .maybeSingle();

  if (error || !data) {
    throw new SessionError("Terigo account session is invalid or expired.");
  }

  await supabase
    .from("app_sessions")
    .update({ last_used_at: now })
    .eq("id", data.id);

  return {
    accountId: data.account_id as string,
    sessionId: data.id as string,
  };
}
