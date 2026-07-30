import {
  corsHeaders,
  htmlSecurityHeaders,
  jsonResponse,
} from "../_shared/cors.ts";
import {
  accountCodeForAthleteID,
  fetchAccountProfile,
} from "../_shared/account.ts";
import { optionalAccountSession } from "../_shared/session.ts";
import { createSharedRouteDownloadURL } from "../_shared/storage.ts";
import { serviceClient } from "../_shared/supabase.ts";

function relatedRecord(value: unknown): Record<string, unknown> | null {
  const candidate = Array.isArray(value) ? value[0] : value;
  return candidate && typeof candidate === "object"
    ? candidate as Record<string, unknown>
    : null;
}

function relatedString(value: unknown, key: string) {
  const field = relatedRecord(value)?.[key];
  return typeof field === "string" && field.length > 0 ? field : null;
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function safeGPXFilename(value: string) {
  const normalized = value
    .replace(/[^\x20-\x7e]/g, " ")
    .replace(/[\u0000-\u001f\u007f"\\/:*?<>|]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
  return `${normalized || "terigo-route"}.gpx`;
}

function publicShareURL(requestURL: URL, token: string) {
  const configuredBaseURL = Deno.env.get("ROUTE_VAULT_SHARE_BASE_URL")?.trim();
  if (configuredBaseURL) {
    const baseURL = new URL(configuredBaseURL);
    baseURL.pathname = "/lists/shared";
    baseURL.search = `token=${encodeURIComponent(token)}`;
    return baseURL.toString();
  }

  return `${requestURL.origin}${requestURL.pathname}?token=${
    encodeURIComponent(token)
  }`;
}

export async function handleSharedList(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "GET") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const url = new URL(request.url);
    const token = url.searchParams.get("token")?.trim();
    const downloadRouteID = url.searchParams.get("downloadRouteID")?.trim();
    const session = await optionalAccountSession(request);

    if (!token || token.length > 256 || !/^[A-Za-z0-9_-]+$/.test(token)) {
      return jsonResponse({ error: "Missing or invalid share token." }, 400);
    }

    if (
      downloadRouteID &&
      (!/^\d+$/.test(downloadRouteID) ||
        !Number.isSafeInteger(Number(downloadRouteID)))
    ) {
      return jsonResponse({ error: "Invalid route download identifier." }, 400);
    }

    const supabase = serviceClient();
    const { data: list, error: listError } = await supabase
      .from("route_lists")
      .select(
        "id, name, list_description, visibility, collaboration_mode, remote_revision, updated_at, owner_account_id, app_accounts!route_lists_owner_account_id_fkey(display_name)",
      )
      .eq("share_token", token)
      .is("deleted_at", null)
      .single();

    if (listError || !list) {
      return jsonResponse({
        error: "This shared list is unavailable or private.",
      }, 404);
    }

    const isOwner = session?.accountId === list.owner_account_id;
    let membershipRole: string | null = null;
    let invitedRole: string | null = null;
    if (session?.accountId && !isOwner) {
      const { data: membership } = await supabase
        .from("route_list_members")
        .select("role")
        .eq("list_id", list.id)
        .eq("account_id", session.accountId)
        .maybeSingle();

      membershipRole = String(membership?.role ?? "");

      const account = await fetchAccountProfile(session.accountId);
      const accountCode = accountCodeForAthleteID(account.strava_athlete_id);
      const { data: invite } = await supabase
        .from("route_list_invites")
        .select("role")
        .eq("list_id", list.id)
        .eq("invited_email", accountCode)
        .maybeSingle();

      invitedRole = String(invite?.role ?? "");
    }

    const canOpen = list.visibility === "link_view" ||
      isOwner ||
      membershipRole === "owner" ||
      membershipRole === "editor" ||
      membershipRole === "viewer" ||
      invitedRole === "editor" ||
      invitedRole === "viewer";

    if (!canOpen) {
      const acceptsHTML = (request.headers.get("accept") ?? "").includes(
        "text/html",
      );
      if (acceptsHTML) {
        const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Restricted List • Terigo</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #0b0b0c; color: #f5f5f5; }
    main { max-width: 640px; margin: 0 auto; padding: 40px 20px 56px; }
    .card { background: #16181d; border-radius: 18px; padding: 20px; }
    h1 { font-size: 28px; margin: 0 0 12px; }
    p { color: #c9c9cf; line-height: 1.5; }
  </style>
</head>
<body>
  <main>
    <div class="card">
      <h1>This shared list is limited to specific Terigo accounts.</h1>
      <p>Open the link in Terigo after signing in with the invited account.</p>
    </div>
  </main>
</body>
</html>`;

        return new Response(html, {
          status: 403,
          headers: {
            ...htmlSecurityHeaders,
            "Content-Type": "text/html; charset=utf-8",
          },
        });
      }

      return jsonResponse({
        error: "This shared list is limited to specific Terigo accounts.",
      }, 403);
    }

    const { data: routes, error: routesError } = await supabase
      .from("route_list_routes")
      .select(
        "strava_route_id, route_name, route_description, distance_meters, elevation_gain_meters, estimated_moving_time, sport_kind, surface_kind, display_location, summary_polyline, detail_polyline, shareability_status, shareability_message, shared_route_snapshot_id, shared_route_snapshots(gpx_payload, gpx_storage_bucket, gpx_storage_path)",
      )
      .eq("list_id", list.id)
      .order("sort_order", { ascending: true });

    if (routesError) {
      return jsonResponse({ error: routesError.message }, 500);
    }

    if (downloadRouteID) {
      const route = routes?.find((item) =>
        String(item.strava_route_id) === downloadRouteID
      );
      const storageBucket = relatedString(
        route?.shared_route_snapshots,
        "gpx_storage_bucket",
      );
      const storagePath = relatedString(
        route?.shared_route_snapshots,
        "gpx_storage_path",
      );
      const gpxPayload = relatedString(
        route?.shared_route_snapshots,
        "gpx_payload",
      );

      if (storageBucket && storagePath) {
        const signedURL = await createSharedRouteDownloadURL(
          storageBucket,
          storagePath,
        );
        return new Response(null, {
          status: 302,
          headers: {
            ...corsHeaders,
            Location: signedURL,
            "Cache-Control": "no-store",
          },
        });
      }

      if (!route || !gpxPayload) {
        return jsonResponse({
          error: "This route is not downloadable from the shared list.",
        }, 404);
      }

      return new Response(gpxPayload, {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/gpx+xml; charset=utf-8",
          "Content-Disposition": `attachment; filename="${
            safeGPXFilename(route.route_name)
          }"`,
        },
      });
    }

    const routePayload = (routes ?? []).map((route) => {
      const storageBucket = relatedString(
        route.shared_route_snapshots,
        "gpx_storage_bucket",
      );
      const storagePath = relatedString(
        route.shared_route_snapshots,
        "gpx_storage_path",
      );
      const hasStorageDownload = Boolean(
        storageBucket && storagePath,
      );
      const hasLegacyPayload = Boolean(
        relatedString(route.shared_route_snapshots, "gpx_payload"),
      );
      const isDownloadable = hasStorageDownload || hasLegacyPayload;

      return {
        stravaRouteID: route.strava_route_id,
        name: route.route_name,
        routeDescription: route.route_description,
        distanceMeters: route.distance_meters,
        elevationGainMeters: route.elevation_gain_meters,
        estimatedMovingTime: route.estimated_moving_time,
        sportKind: route.sport_kind,
        surfaceKind: route.surface_kind,
        displayLocation: route.display_location,
        summaryPolyline: route.summary_polyline,
        detailPolyline: route.detail_polyline,
        isDownloadable,
        downloadURLString: isDownloadable
          ? `${url.origin}${url.pathname}?token=${
            encodeURIComponent(token)
          }&downloadRouteID=${route.strava_route_id}`
          : null,
        shareabilityStatus: route.shareability_status,
        shareabilityMessage: route.shareability_message,
      };
    });

    const payload = {
      listID: list.id,
      name: list.name,
      listDescription: list.list_description,
      ownerDisplayName: relatedString(list.app_accounts, "display_name") ??
        "Terigo athlete",
      visibility: list.visibility,
      collaborationMode: list.collaboration_mode,
      collaboratorCodes: [],
      viewerCodes: [],
      revision: list.remote_revision,
      updatedAt: list.updated_at,
      routes: routePayload,
    };

    const acceptsHTML = (request.headers.get("accept") ?? "").includes(
      "text/html",
    );
    if (!acceptsHTML) {
      return jsonResponse(payload);
    }

    const shareURL = publicShareURL(url, token);
    const routeMarkup = routePayload.map((route) => `
      <li>
        <strong>${escapeHtml(route.name)}</strong>
        <div>${escapeHtml(route.displayLocation ?? "")}</div>
        <div>${Math.round(route.distanceMeters)} m • ${
      Math.round(route.elevationGainMeters)
    } m climb • ${escapeHtml(route.sportKind)}</div>
        ${
      route.isDownloadable
        ? `<a href="${
          escapeHtml(route.downloadURLString ?? "#")
        }">Download GPX</a>`
        : `<span>${escapeHtml(route.shareabilityMessage ?? "View only")}</span>`
    }
      </li>
    `).join("");

    const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>${escapeHtml(list.name)} • Terigo</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #0b0b0c; color: #f5f5f5; }
    main { max-width: 760px; margin: 0 auto; padding: 32px 20px 56px; }
    h1 { font-size: 32px; margin-bottom: 8px; }
    .meta { color: #a1a1aa; margin-bottom: 24px; }
    .card { background: #16181d; border-radius: 18px; padding: 18px; margin-bottom: 16px; }
    ul { list-style: none; padding: 0; margin: 0; display: grid; gap: 12px; }
    li { background: #16181d; border-radius: 18px; padding: 16px; }
    a { color: #ff7a1a; text-decoration: none; font-weight: 600; }
    strong { display: block; font-size: 18px; margin-bottom: 6px; }
  </style>
</head>
<body>
  <main>
    <div class="card">
      <h1>${escapeHtml(list.name)}</h1>
      <div class="meta">By ${
      escapeHtml(
        relatedString(list.app_accounts, "display_name") ?? "Terigo athlete",
      )
    } • Updated ${escapeHtml(new Date(list.updated_at).toLocaleString())}</div>
      <p>${escapeHtml(list.list_description ?? "")}</p>
      <p><a href="${escapeHtml(shareURL)}">Open in Terigo</a></p>
      <p><a href="routevault://lists/shared?token=${
      encodeURIComponent(token)
    }">Fallback deep link</a></p>
    </div>
    <ul>${routeMarkup}</ul>
  </main>
</body>
</html>`;

    return new Response(html, {
      status: 200,
      headers: {
        ...htmlSecurityHeaders,
        "Content-Type": "text/html; charset=utf-8",
      },
    });
  } catch (error) {
    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo share-link failure.",
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleSharedList);
}
