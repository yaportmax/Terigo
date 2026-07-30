export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return json({ message: "Method not allowed" }, 405);
    }

    const url = new URL(request.url);
    const body = await request.json().catch(() => null);
    if (!body || !env.STRAVA_CLIENT_ID || !env.STRAVA_CLIENT_SECRET || !env.STRAVA_REDIRECT_URI) {
      return json({ message: "Missing broker configuration" }, 500);
    }

    const requestedClientID = String(body.client_id || "").trim();
    if (requestedClientID && requestedClientID !== env.STRAVA_CLIENT_ID) {
      return json({ message: "Client ID does not match this broker" }, 400);
    }

    let params;
    if (url.pathname.endsWith("/exchange")) {
      const code = String(body.code || "").trim();
      const redirectURI = String(body.redirect_uri || "").trim();
      if (!code || code.length > 512) {
        return json({ message: "Authorization code is missing or invalid" }, 400);
      }
      if (redirectURI !== env.STRAVA_REDIRECT_URI) {
        return json({ message: "Redirect URI does not match this broker" }, 400);
      }

      params = new URLSearchParams({
        client_id: env.STRAVA_CLIENT_ID,
        client_secret: env.STRAVA_CLIENT_SECRET,
        code,
        grant_type: "authorization_code",
        redirect_uri: env.STRAVA_REDIRECT_URI
      });
    } else if (url.pathname.endsWith("/refresh")) {
      const refreshToken = String(body.refresh_token || "").trim();
      if (!refreshToken || refreshToken.length > 2048) {
        return json({ message: "Refresh token is missing or invalid" }, 400);
      }

      params = new URLSearchParams({
        client_id: env.STRAVA_CLIENT_ID,
        client_secret: env.STRAVA_CLIENT_SECRET,
        grant_type: "refresh_token",
        refresh_token: refreshToken
      });
    } else {
      return json({ message: "Unknown endpoint" }, 404);
    }

    const response = await fetch("https://www.strava.com/oauth/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: params,
      signal: AbortSignal.timeout(10_000)
    });

    const payload = await response.text();
    return new Response(payload, {
      status: response.status,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store"
      }
    });
  }
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store"
    }
  });
}
