import { corsHeaders, jsonResponse } from "../_shared/cors.ts";

type BrokerRequest = {
  client_id?: string | null;
  code?: string | null;
  refresh_token?: string | null;
  redirect_uri?: string | null;
};

function requiredEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) {
    throw new Error(`Missing ${name} for Strava auth broker.`);
  }
  return value;
}

export async function handleStravaAuthBroker(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ message: "Method not allowed" }, 405);
  }

  try {
    const url = new URL(request.url);
    const body = await request.json().catch(() => null) as BrokerRequest | null;
    if (!body) {
      return jsonResponse({ message: "Invalid JSON body" }, 400);
    }

    const clientID = requiredEnv("STRAVA_CLIENT_ID");
    const clientSecret = requiredEnv("STRAVA_CLIENT_SECRET");
    const requestedClientID = body.client_id?.trim();
    if (requestedClientID && requestedClientID !== clientID) {
      return jsonResponse(
        { message: "Client ID does not match this broker." },
        400,
      );
    }

    let params: URLSearchParams;
    if (url.pathname.endsWith("/exchange")) {
      const code = body.code?.trim();
      const redirectURI = body.redirect_uri?.trim();
      const configuredRedirectURI = requiredEnv("STRAVA_REDIRECT_URI");
      if (!code || code.length > 512) {
        return jsonResponse({
          message: "Authorization code is missing or invalid.",
        }, 400);
      }
      if (!redirectURI || redirectURI !== configuredRedirectURI) {
        return jsonResponse({
          message: "Redirect URI does not match this broker.",
        }, 400);
      }

      params = new URLSearchParams({
        client_id: clientID,
        client_secret: clientSecret,
        code,
        grant_type: "authorization_code",
        redirect_uri: configuredRedirectURI,
      });
    } else if (url.pathname.endsWith("/refresh")) {
      const refreshToken = body.refresh_token?.trim();
      if (!refreshToken || refreshToken.length > 2048) {
        return jsonResponse(
          { message: "Refresh token is missing or invalid." },
          400,
        );
      }

      params = new URLSearchParams({
        client_id: clientID,
        client_secret: clientSecret,
        grant_type: "refresh_token",
        refresh_token: refreshToken,
      });
    } else {
      return jsonResponse({ message: "Unknown endpoint" }, 404);
    }

    const response = await fetch("https://www.strava.com/oauth/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: params,
      signal: AbortSignal.timeout(10_000),
    });

    const payload = await response.text();
    return new Response(payload, {
      status: response.status,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
      },
    });
  } catch (error) {
    return jsonResponse({
      message: error instanceof Error
        ? error.message
        : "Unexpected broker error",
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleStravaAuthBroker);
}
