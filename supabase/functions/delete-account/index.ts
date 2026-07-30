import {
  accountCodeForAthleteID,
  fetchAccountProfile,
} from "../_shared/account.ts";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { requireAccountSession, SessionError } from "../_shared/session.ts";
import { serviceClient } from "../_shared/supabase.ts";

type StoredSnapshot = {
  gpx_storage_bucket: string | null;
  gpx_storage_path: string | null;
};

export async function handleDeleteAccount(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const { accountId } = await requireAccountSession(request);
    const account = await fetchAccountProfile(accountId);
    const supabase = serviceClient();

    const { data: snapshots, error: snapshotsError } = await supabase
      .from("shared_route_snapshots")
      .select("gpx_storage_bucket, gpx_storage_path")
      .eq("owner_account_id", accountId);

    if (snapshotsError) {
      return jsonResponse({ error: snapshotsError.message }, 500);
    }

    const pathsByBucket = new Map<string, string[]>();
    for (const snapshot of (snapshots ?? []) as StoredSnapshot[]) {
      const bucket = snapshot.gpx_storage_bucket?.trim();
      const path = snapshot.gpx_storage_path?.trim();
      if (!bucket || !path) {
        continue;
      }

      const paths = pathsByBucket.get(bucket) ?? [];
      paths.push(path);
      pathsByBucket.set(bucket, paths);
    }

    for (const [bucket, paths] of pathsByBucket) {
      const { error } = await supabase.storage.from(bucket).remove(paths);
      if (error) {
        return jsonResponse({
          error:
            "Terigo could not remove all hosted route files. The account was not deleted; try again.",
        }, 502);
      }
    }

    const accountCode = accountCodeForAthleteID(account.strava_athlete_id);
    const { error: inviteError } = await supabase
      .from("route_list_invites")
      .delete()
      .eq("invited_email", accountCode);

    if (inviteError) {
      return jsonResponse({ error: inviteError.message }, 500);
    }

    const { error: accountError } = await supabase
      .from("app_accounts")
      .delete()
      .eq("id", accountId);

    if (accountError) {
      return jsonResponse({ error: accountError.message }, 500);
    }

    return jsonResponse({ ok: true });
  } catch (error) {
    if (error instanceof SessionError) {
      return jsonResponse({ error: error.message }, error.status);
    }

    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo account deletion failure.",
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleDeleteAccount);
}
