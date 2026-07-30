import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { fetchAccountProfile } from "../_shared/account.ts";
import { requireAccountSession, SessionError } from "../_shared/session.ts";
import { serviceClient } from "../_shared/supabase.ts";

type SubmitFeedbackRequest = {
  message?: string | null;
  sourceScreen?: string | null;
  appVersion?: string | null;
  buildNumber?: string | null;
};

export async function handleSubmitFeedback(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const { accountId, sessionId } = await requireAccountSession(request);
    const body = await request.json().catch(() => null) as
      | SubmitFeedbackRequest
      | null;
    const message = body?.message?.trim();

    if (!message) {
      return jsonResponse({ error: "Feedback message is required." }, 400);
    }

    if (message.length > 4_000) {
      return jsonResponse({
        error: "Feedback must be 4,000 characters or fewer.",
      }, 400);
    }

    const account = await fetchAccountProfile(accountId);
    const supabase = serviceClient();
    const { error } = await supabase
      .from("app_feedback")
      .insert({
        account_id: accountId,
        session_id: sessionId,
        strava_athlete_id: account.strava_athlete_id,
        display_name: account.display_name,
        message,
        source_screen: body?.sourceScreen?.trim().slice(0, 100) || "unknown",
        app_version: body?.appVersion?.trim().slice(0, 64) || null,
        build_number: body?.buildNumber?.trim().slice(0, 64) || null,
      });

    if (error) {
      return jsonResponse({ error: error.message }, 500);
    }

    return jsonResponse({ ok: true });
  } catch (error) {
    if (error instanceof SessionError) {
      return jsonResponse({ error: error.message }, error.status);
    }

    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo feedback failure.",
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleSubmitFeedback);
}
