import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { serializeAccountProfile } from "../_shared/account.ts";
import { serviceClient } from "../_shared/supabase.ts";
import { sha256Hex } from "../_shared/session.ts";

type BootstrapRequest = {
  stravaSession: {
    accessToken: string;
  };
  device?: {
    platform?: string | null;
    appVersion?: string | null;
    buildNumber?: string | null;
  };
};

type StravaAthlete = {
  id: number;
  username?: string | null;
  firstname?: string | null;
  lastname?: string | null;
  profile_medium?: string | null;
  profile?: string | null;
};

function normalizedDisplayName(
  firstName?: string | null,
  lastName?: string | null,
  username?: string | null,
) {
  return [firstName, lastName].filter(Boolean).join(" ").trim() ||
    username?.trim() || "Connected Athlete";
}

export async function handleAccountBootstrap(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const body = await request.json().catch(() => null) as
      | BootstrapRequest
      | null;
    const accessToken = body?.stravaSession?.accessToken?.trim();
    if (!accessToken) {
      return jsonResponse({ error: "Missing Strava access token." }, 400);
    }

    let athleteResponse: Response;
    try {
      athleteResponse = await fetch("https://www.strava.com/api/v3/athlete", {
        headers: {
          Authorization: `Bearer ${accessToken}`,
          Accept: "application/json",
        },
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      return jsonResponse({
        error: "Strava could not be reached to verify this account.",
      }, 502);
    }

    if (athleteResponse.status === 401 || athleteResponse.status === 403) {
      return jsonResponse({
        error: "The Strava access token is invalid or expired.",
      }, 401);
    }

    if (!athleteResponse.ok) {
      return jsonResponse(
        { error: "Strava could not verify this account." },
        502,
      );
    }

    const athlete = await athleteResponse.json().catch(() => null) as
      | StravaAthlete
      | null;
    if (!athlete || !Number.isSafeInteger(athlete.id) || athlete.id <= 0) {
      return jsonResponse({
        error: "Strava returned an invalid athlete profile.",
      }, 502);
    }

    const displayName = normalizedDisplayName(
      athlete.firstname,
      athlete.lastname,
      athlete.username,
    );

    const supabase = serviceClient();
    const now = new Date().toISOString();

    const { data: account, error: accountError } = await supabase
      .from("app_accounts")
      .upsert({
        strava_athlete_id: athlete.id,
        display_name: displayName,
        avatar_url: athlete.profile_medium ?? athlete.profile ?? null,
        updated_at: now,
      }, {
        onConflict: "strava_athlete_id",
      })
      .select(
        "id, strava_athlete_id, display_name, avatar_url, created_at, updated_at",
      )
      .single();

    if (accountError || !account) {
      return jsonResponse({
        error: accountError?.message ?? "Could not create Terigo account.",
      }, 500);
    }

    const rawToken = crypto.randomUUID().replace(/-/g, "") +
      crypto.randomUUID().replace(/-/g, "");
    const sessionTokenHash = await sha256Hex(rawToken);
    const expiresAt = new Date(Date.now() + (1000 * 60 * 60 * 24 * 45))
      .toISOString();

    const { error: sessionError } = await supabase
      .from("app_sessions")
      .insert({
        account_id: account.id,
        session_token_hash: sessionTokenHash,
        device_platform: body?.device?.platform?.trim().slice(0, 32) || "ios",
        app_version: body?.device?.appVersion?.trim().slice(0, 64) || null,
        build_number: body?.device?.buildNumber?.trim().slice(0, 64) || null,
        expires_at: expiresAt,
      });

    if (sessionError) {
      return jsonResponse({ error: sessionError.message }, 500);
    }

    return jsonResponse({
      token: rawToken,
      expiresAt,
      profile: serializeAccountProfile(account),
    });
  } catch (error) {
    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected error bootstrapping Terigo account.",
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleAccountBootstrap);
}
