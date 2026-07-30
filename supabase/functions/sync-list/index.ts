import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import {
  fetchAccountProfile,
  normalizeAccountCode,
} from "../_shared/account.ts";
import { requireAccountSession, SessionError } from "../_shared/session.ts";
import { uploadSharedRouteGPX } from "../_shared/storage.ts";
import { serviceClient } from "../_shared/supabase.ts";

type SyncListRequest = {
  clientListID: string;
  remoteListID?: string | null;
  remoteShareToken?: string | null;
  expectedRevision?: number | null;
  name: string;
  listDescription: string;
  visibility: "private" | "invited_viewers" | "link_view";
  collaborationMode: "owner_only" | "link_editors" | "invited_editors";
  collaboratorCodes?: string[];
  viewerCodes?: string[];
  collaboratorEmails?: string[];
  viewerEmails?: string[];
  routes: Array<{
    stravaRouteID: number;
    name: string;
    routeDescription: string;
    distanceMeters: number;
    elevationGainMeters: number;
    estimatedMovingTime: number;
    sportKind: string;
    surfaceKind?: string | null;
    displayLocation: string;
    isPrivateOnStrava: boolean;
    summaryPolyline: string;
    detailPolyline?: string | null;
    hasDownloadedDetails: boolean;
    gpxPayload?: string | null;
  }>;
};

type SnapshotRecord = {
  id: string;
  strava_route_id: number;
  gpx_storage_bucket: string | null;
  gpx_storage_path: string | null;
  gpx_payload: string | null;
  gpx_file_size_bytes: number | null;
};

const maximumSyncRequestBytes = 25 * 1024 * 1024;

function normalizeAccountCodes(codes: string[]) {
  return Array.from(
    new Set(
      codes
        .map((code) => normalizeAccountCode(code))
        .filter(Boolean) as string[],
    ),
  );
}

function validateSyncRequest(body: SyncListRequest | null) {
  if (!body || typeof body !== "object") {
    return "Invalid JSON body.";
  }

  if (
    typeof body.clientListID !== "string" ||
    body.clientListID.trim().length === 0 ||
    body.clientListID.length > 200
  ) {
    return "The client list identifier is missing or too long.";
  }

  if (
    typeof body.name !== "string" || body.name.trim().length === 0 ||
    body.name.length > 120
  ) {
    return "List names must be between 1 and 120 characters.";
  }

  if (
    typeof body.listDescription !== "string" ||
    body.listDescription.length > 5_000
  ) {
    return "List descriptions must be 5,000 characters or fewer.";
  }

  if (!["private", "invited_viewers", "link_view"].includes(body.visibility)) {
    return "Invalid list visibility.";
  }

  if (
    !["owner_only", "link_editors", "invited_editors"].includes(
      body.collaborationMode,
    )
  ) {
    return "Invalid collaboration mode.";
  }

  if (
    body.remoteListID !== undefined && body.remoteListID !== null &&
    typeof body.remoteListID !== "string"
  ) {
    return "Invalid remote list identifier.";
  }

  if (
    body.remoteListID &&
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(body.remoteListID)
  ) {
    return "Invalid remote list identifier.";
  }

  if (
    body.remoteShareToken !== undefined && body.remoteShareToken !== null &&
    typeof body.remoteShareToken !== "string"
  ) {
    return "Invalid remote share token.";
  }

  if ((body.remoteShareToken?.length ?? 0) > 256) {
    return "Invalid remote share token.";
  }

  if (!Array.isArray(body.routes) || body.routes.length > 1_000) {
    return "A list can contain at most 1,000 routes.";
  }

  for (
    const values of [
      body.collaboratorCodes,
      body.viewerCodes,
      body.collaboratorEmails,
      body.viewerEmails,
    ]
  ) {
    if (values !== undefined && !Array.isArray(values)) {
      return "Invalid invited-account list.";
    }
  }

  if (
    (body.collaboratorCodes?.length ?? 0) > 100 ||
    (body.viewerCodes?.length ?? 0) > 100
  ) {
    return "A list can include at most 100 invited editors and 100 invited viewers.";
  }

  if (
    body.expectedRevision !== undefined &&
    body.expectedRevision !== null &&
    (!Number.isSafeInteger(body.expectedRevision) || body.expectedRevision < 0)
  ) {
    return "Invalid expected revision.";
  }

  let totalLargeTextCharacters = 0;
  for (const route of body.routes) {
    if (
      !Number.isSafeInteger(route?.stravaRouteID) || route.stravaRouteID <= 0
    ) {
      return "Every route must have a valid Strava route identifier.";
    }
    if (
      typeof route.name !== "string" || route.name.trim().length === 0 ||
      route.name.length > 240
    ) {
      return "Every route must have a name between 1 and 240 characters.";
    }
    if (
      typeof route.routeDescription !== "string" ||
      route.routeDescription.length > 10_000
    ) {
      return "Route descriptions must be 10,000 characters or fewer.";
    }
    if (
      !Number.isFinite(route.distanceMeters) || route.distanceMeters < 0 ||
      !Number.isFinite(route.elevationGainMeters) ||
      route.elevationGainMeters < 0 ||
      !Number.isFinite(route.estimatedMovingTime) ||
      route.estimatedMovingTime < 0
    ) {
      return "Route distance, climb, and moving time must be valid nonnegative numbers.";
    }
    if (
      typeof route.sportKind !== "string" || route.sportKind.length > 64 ||
      typeof route.displayLocation !== "string" ||
      route.displayLocation.length > 500
    ) {
      return "Route sport or display location is invalid or too long.";
    }
    if (
      typeof route.summaryPolyline !== "string" ||
      route.summaryPolyline.length > 2_000_000
    ) {
      return "A route summary polyline is invalid or too large.";
    }
    if ((route.detailPolyline?.length ?? 0) > 4_000_000) {
      return "A route detail polyline is too large.";
    }
    if ((route.gpxPayload?.length ?? 0) > 20_000_000) {
      return "A shared GPX file is too large.";
    }
    totalLargeTextCharacters += route.summaryPolyline.length +
      (route.detailPolyline?.length ?? 0) +
      (route.gpxPayload?.length ?? 0);
    if (totalLargeTextCharacters > maximumSyncRequestBytes) {
      return "The combined route payload is too large.";
    }
  }

  return null;
}

export async function handleSyncList(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const contentLength = Number(request.headers.get("content-length") ?? "0");
    if (
      Number.isFinite(contentLength) &&
      contentLength > maximumSyncRequestBytes
    ) {
      return jsonResponse({ error: "The sync request is too large." }, 413);
    }

    const { accountId } = await requireAccountSession(request);
    const rawBody = await request.json().catch(() => null) as
      | SyncListRequest
      | null;
    const validationError = validateSyncRequest(rawBody);
    if (validationError) {
      return jsonResponse({ error: validationError }, 400);
    }
    const body = rawBody as SyncListRequest;
    body.clientListID = body.clientListID.trim();
    body.name = body.name.trim();
    const supabase = serviceClient();
    const now = new Date().toISOString();
    const currentAccount = await fetchAccountProfile(accountId);
    const currentAccountCode =
      normalizeAccountCode(String(currentAccount.strava_athlete_id)) ?? "";
    const normalizedCollaboratorCodes = normalizeAccountCodes(
      body.collaboratorCodes ?? body.collaboratorEmails ?? [],
    );
    const normalizedViewerCodes = normalizeAccountCodes(
      body.viewerCodes ?? body.viewerEmails ?? [],
    );

    if (
      body.visibility === "invited_viewers" &&
      body.collaborationMode === "link_editors"
    ) {
      return jsonResponse({
        error:
          "Lists limited to specific viewers cannot also allow anyone with the link to edit.",
      }, 400);
    }

    let listId = body.remoteListID ?? null;
    let shareToken = "";
    let currentRevision = 0;
    let isNewList = false;

    if (listId) {
      const { data: existingList } = await supabase
        .from("route_lists")
        .select(
          "id, owner_account_id, share_token, collaboration_mode, remote_revision",
        )
        .eq("id", listId)
        .is("deleted_at", null)
        .maybeSingle();

      if (!existingList) {
        return jsonResponse({ error: "This list no longer exists." }, 404);
      }

      let canEdit = existingList.owner_account_id === accountId;

      if (!canEdit) {
        const { data: membership } = await supabase
          .from("route_list_members")
          .select("role")
          .eq("list_id", listId)
          .eq("account_id", accountId)
          .maybeSingle();

        canEdit = membership?.role === "owner" || membership?.role === "editor";
      }

      if (!canEdit) {
        const { data: invite } = await supabase
          .from("route_list_invites")
          .select("role")
          .eq("list_id", listId)
          .eq("invited_email", currentAccountCode)
          .maybeSingle();

        canEdit = invite?.role === "editor";
      }

      if (!canEdit && existingList.collaboration_mode === "link_editors") {
        canEdit =
          (body.remoteShareToken?.trim() ?? "") === existingList.share_token;
      }

      if (!canEdit) {
        return jsonResponse({
          error: "You do not have permission to edit this list.",
        }, 403);
      }

      currentRevision = existingList.remote_revision ?? 0;
      if (
        body.expectedRevision !== undefined &&
        body.expectedRevision !== null &&
        body.expectedRevision !== currentRevision
      ) {
        return jsonResponse({
          error:
            "This list changed in Terigo on another device. Reload the latest version before syncing again.",
          currentRevision,
        }, 409);
      }

      shareToken = existingList.share_token;
    } else {
      const { data: existingList } = await supabase
        .from("route_lists")
        .select("id, share_token, remote_revision")
        .eq("owner_account_id", accountId)
        .eq("client_list_id", body.clientListID)
        .is("deleted_at", null)
        .maybeSingle();

      if (existingList) {
        listId = existingList.id;
        shareToken = existingList.share_token;
        currentRevision = existingList.remote_revision ?? 0;
      } else {
        const { data: insertedList, error: insertError } = await supabase
          .from("route_lists")
          .insert({
            owner_account_id: accountId,
            client_list_id: body.clientListID,
            name: body.name,
            list_description: body.listDescription ?? "",
            visibility: body.visibility,
            collaboration_mode: body.collaborationMode,
            remote_revision: 1,
            updated_at: now,
          })
          .select("id, share_token, remote_revision")
          .single();

        if (insertError || !insertedList) {
          return jsonResponse({
            error: insertError?.message ?? "Could not create list.",
          }, 500);
        }

        listId = insertedList.id;
        shareToken = insertedList.share_token;
        currentRevision = insertedList.remote_revision ?? 1;
        isNewList = true;

        await supabase.from("route_list_members").upsert({
          list_id: listId,
          account_id: accountId,
          role: "owner",
        }, {
          onConflict: "list_id,account_id",
        });
      }
    }

    if (!listId) {
      return jsonResponse({
        error: "Could not resolve a Terigo list identifier.",
      }, 500);
    }

    const { data: existingInvites, error: invitesReadError } = await supabase
      .from("route_list_invites")
      .select("invited_email, role")
      .eq("list_id", listId);

    if (invitesReadError) {
      return jsonResponse({ error: invitesReadError.message }, 500);
    }

    const existingInviteRoles = new Map(
      (existingInvites ?? []).map((invite) => [
        String(invite.invited_email).trim().toUpperCase(),
        String(invite.role ?? "editor"),
      ]),
    );
    const desiredInviteRoles = new Map<string, "viewer" | "editor">();

    if (body.visibility === "invited_viewers") {
      for (const code of normalizedViewerCodes) {
        if (code !== currentAccountCode) {
          desiredInviteRoles.set(code, "viewer");
        }
      }
    }

    if (body.collaborationMode === "invited_editors") {
      for (const code of normalizedCollaboratorCodes) {
        if (code !== currentAccountCode) {
          desiredInviteRoles.set(code, "editor");
        }
      }
    }

    const inviteEmailsToDelete = Array.from(existingInviteRoles.keys()).filter((
      email,
    ) => !desiredInviteRoles.has(email));

    if (inviteEmailsToDelete.length > 0) {
      const { error: deleteInvitesError } = await supabase
        .from("route_list_invites")
        .delete()
        .eq("list_id", listId)
        .in("invited_email", inviteEmailsToDelete);

      if (deleteInvitesError) {
        return jsonResponse({ error: deleteInvitesError.message }, 500);
      }
    }

    if (desiredInviteRoles.size > 0) {
      const inviteRows = Array.from(desiredInviteRoles.entries()).map((
        [code, role],
      ) => ({
        list_id: listId,
        invited_email: code,
        role,
      }));

      const { error: upsertInvitesError } = await supabase
        .from("route_list_invites")
        .upsert(inviteRows, {
          onConflict: "list_id,invited_email",
        });

      if (upsertInvitesError) {
        return jsonResponse({ error: upsertInvitesError.message }, 500);
      }
    }

    const { data: existingListRoutes, error: existingRoutesError } =
      await supabase
        .from("route_list_routes")
        .select("strava_route_id")
        .eq("list_id", listId);

    if (existingRoutesError) {
      return jsonResponse({ error: existingRoutesError.message }, 500);
    }

    const incomingRouteIDs = Array.from(
      new Set((body.routes ?? []).map((route) => route.stravaRouteID)),
    );
    const existingRouteIDs = new Set(
      (existingListRoutes ?? []).map((route) => Number(route.strava_route_id)),
    );
    const routeIDsToDelete = Array.from(existingRouteIDs).filter((routeID) =>
      !incomingRouteIDs.includes(routeID)
    );

    if (routeIDsToDelete.length > 0) {
      const { error: deleteRoutesError } = await supabase
        .from("route_list_routes")
        .delete()
        .eq("list_id", listId)
        .in("strava_route_id", routeIDsToDelete);

      if (deleteRoutesError) {
        return jsonResponse({ error: deleteRoutesError.message }, 500);
      }
    }

    const snapshotByRouteID = new Map<number, SnapshotRecord>();
    if (incomingRouteIDs.length > 0) {
      const { data: existingSnapshots, error: snapshotsError } = await supabase
        .from("shared_route_snapshots")
        .select(
          "id, strava_route_id, gpx_storage_bucket, gpx_storage_path, gpx_payload, gpx_file_size_bytes",
        )
        .eq("owner_account_id", accountId)
        .in("strava_route_id", incomingRouteIDs);

      if (snapshotsError) {
        return jsonResponse({ error: snapshotsError.message }, 500);
      }

      for (const snapshot of existingSnapshots ?? []) {
        snapshotByRouteID.set(
          snapshot.strava_route_id,
          snapshot as SnapshotRecord,
        );
      }
    }

    const shareabilityIssues: Array<
      { routeID: number; routeName: string; kind: string }
    > = [];

    for (const [index, route] of (body.routes ?? []).entries()) {
      const trimmedGPXPayload = route.gpxPayload?.trim() ?? "";
      let snapshotRecord = snapshotByRouteID.get(route.stravaRouteID) ?? null;
      let snapshotId = snapshotRecord?.id ?? null;

      if (trimmedGPXPayload.length > 0) {
        const storageObject = await uploadSharedRouteGPX(
          accountId,
          route.stravaRouteID,
          trimmedGPXPayload,
        );

        const { data: snapshot, error: snapshotError } = await supabase
          .from("shared_route_snapshots")
          .upsert({
            owner_account_id: accountId,
            strava_route_id: route.stravaRouteID,
            route_name: route.name,
            route_description: route.routeDescription ?? "",
            distance_meters: route.distanceMeters ?? 0,
            elevation_gain_meters: route.elevationGainMeters ?? 0,
            estimated_moving_time: route.estimatedMovingTime ?? 0,
            sport_kind: route.sportKind ?? "other",
            surface_kind: route.surfaceKind ?? null,
            display_location: route.displayLocation ?? "",
            is_private_on_strava: route.isPrivateOnStrava ?? false,
            summary_polyline: route.summaryPolyline ?? "",
            detail_polyline: route.detailPolyline ?? null,
            gpx_payload: null,
            gpx_storage_bucket: storageObject.bucket,
            gpx_storage_path: storageObject.path,
            gpx_file_size_bytes: storageObject.fileSizeBytes,
            updated_at: now,
          }, {
            onConflict: "owner_account_id,strava_route_id",
          })
          .select(
            "id, strava_route_id, gpx_storage_bucket, gpx_storage_path, gpx_payload, gpx_file_size_bytes",
          )
          .single();

        if (snapshotError || !snapshot) {
          return jsonResponse({
            error: snapshotError?.message ??
              "Could not persist the downloadable GPX snapshot.",
          }, 500);
        }

        snapshotRecord = snapshot as SnapshotRecord;
        snapshotByRouteID.set(route.stravaRouteID, snapshotRecord);
        snapshotId = snapshotRecord.id;
      } else if (snapshotRecord) {
        const { data: snapshot, error: snapshotError } = await supabase
          .from("shared_route_snapshots")
          .upsert({
            owner_account_id: accountId,
            strava_route_id: route.stravaRouteID,
            route_name: route.name,
            route_description: route.routeDescription ?? "",
            distance_meters: route.distanceMeters ?? 0,
            elevation_gain_meters: route.elevationGainMeters ?? 0,
            estimated_moving_time: route.estimatedMovingTime ?? 0,
            sport_kind: route.sportKind ?? "other",
            surface_kind: route.surfaceKind ?? null,
            display_location: route.displayLocation ?? "",
            is_private_on_strava: route.isPrivateOnStrava ?? false,
            summary_polyline: route.summaryPolyline ?? "",
            detail_polyline: route.detailPolyline ?? null,
            gpx_payload: null,
            gpx_storage_bucket: snapshotRecord.gpx_storage_bucket,
            gpx_storage_path: snapshotRecord.gpx_storage_path,
            gpx_file_size_bytes: snapshotRecord.gpx_file_size_bytes,
            updated_at: now,
          }, {
            onConflict: "owner_account_id,strava_route_id",
          })
          .select(
            "id, strava_route_id, gpx_storage_bucket, gpx_storage_path, gpx_payload, gpx_file_size_bytes",
          )
          .single();

        if (snapshotError || !snapshot) {
          return jsonResponse({
            error: snapshotError?.message ??
              "Could not update the shared route snapshot metadata.",
          }, 500);
        }

        snapshotRecord = snapshot as SnapshotRecord;
        snapshotByRouteID.set(route.stravaRouteID, snapshotRecord);
        snapshotId = snapshotRecord.id;
      }

      const hasStoredDownload = Boolean(
        snapshotRecord?.gpx_storage_bucket && snapshotRecord?.gpx_storage_path,
      ) || Boolean(snapshotRecord?.gpx_payload?.trim());

      let shareabilityStatus = "view_only";
      let shareabilityMessage: string | null =
        "Other people can see this route in the list, but it cannot be downloaded until route details are downloaded in Terigo.";

      if (hasStoredDownload) {
        shareabilityStatus = "downloadable";
        shareabilityMessage = null;
      } else if (route.isPrivateOnStrava) {
        shareabilityStatus = "blocked_private_not_downloaded";
        shareabilityMessage =
          "This route is private on Strava and cannot be shown to other people until route details are downloaded in Terigo.";
        shareabilityIssues.push({
          routeID: route.stravaRouteID,
          routeName: route.name,
          kind: "private_route_missing_downloaded_details",
        });
      } else {
        shareabilityIssues.push({
          routeID: route.stravaRouteID,
          routeName: route.name,
          kind: "route_view_only_until_downloaded",
        });
      }

      const { error: routeUpsertError } = await supabase
        .from("route_list_routes")
        .upsert({
          list_id: listId,
          shared_route_snapshot_id: hasStoredDownload ? snapshotId : snapshotId,
          strava_route_id: route.stravaRouteID,
          route_name: route.name,
          route_description: route.routeDescription ?? "",
          distance_meters: route.distanceMeters ?? 0,
          elevation_gain_meters: route.elevationGainMeters ?? 0,
          estimated_moving_time: route.estimatedMovingTime ?? 0,
          sport_kind: route.sportKind ?? "other",
          surface_kind: route.surfaceKind ?? null,
          display_location: route.displayLocation ?? "",
          summary_polyline: route.summaryPolyline ?? "",
          detail_polyline: route.detailPolyline ?? null,
          shareability_status: shareabilityStatus,
          shareability_message: shareabilityMessage,
          sort_order: index,
        }, {
          onConflict: "list_id,strava_route_id",
        });

      if (routeUpsertError) {
        return jsonResponse({ error: routeUpsertError.message }, 500);
      }
    }

    const nextRevision = isNewList ? 1 : currentRevision + 1;

    const { error: updateListError } = await supabase
      .from("route_lists")
      .update({
        name: body.name,
        list_description: body.listDescription ?? "",
        visibility: body.visibility,
        collaboration_mode: body.collaborationMode,
        remote_revision: nextRevision,
        updated_at: now,
      })
      .eq("id", listId);

    if (updateListError) {
      return jsonResponse({ error: updateListError.message }, 500);
    }

    if (body.visibility !== "link_view") {
      const { error: followersError } = await supabase
        .from("route_list_followers")
        .delete()
        .eq("list_id", listId);

      if (followersError) {
        return jsonResponse({ error: followersError.message }, 500);
      }
    }

    const { data: syncedList, error: readError } = await supabase
      .from("route_lists")
      .select("id, owner_account_id, share_token, remote_revision, updated_at")
      .eq("id", listId)
      .single();

    if (readError || !syncedList) {
      return jsonResponse({
        error: readError?.message ??
          "List sync completed but the list could not be reloaded.",
      }, 500);
    }

    return jsonResponse({
      listID: syncedList.id,
      ownerAccountID: syncedList.owner_account_id,
      shareToken: syncedList.share_token,
      revision: syncedList.remote_revision,
      updatedAt: syncedList.updated_at,
      shareabilityIssues: shareabilityIssues.map((issue) => ({
        routeID: issue.routeID,
        routeName: issue.routeName,
        kind: issue.kind,
      })),
    });
  } catch (error) {
    if (error instanceof SessionError) {
      return jsonResponse({ error: error.message }, error.status);
    }

    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo list sync failure.",
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleSyncList);
}
