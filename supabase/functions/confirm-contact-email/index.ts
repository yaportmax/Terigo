import { corsHeaders, jsonResponse } from "../_shared/cors.ts";

export async function handleConfirmContactEmail(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  return jsonResponse({
    error:
      "Terigo no longer uses invite-email verification. Share a Strava-backed Terigo account code instead.",
  }, 410);
}

if (import.meta.main) {
  Deno.serve(handleConfirmContactEmail);
}
