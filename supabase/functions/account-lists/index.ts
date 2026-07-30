import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import {
  accountCodeForAthleteID,
  fetchAccountProfile,
} from "../_shared/account.ts";
import { requireAccountSession, SessionError } from "../_shared/session.ts";
import { serviceClient } from "../_shared/supabase.ts";

function ownerDisplayName(value: unknown) {
  const owner = Array.isArray(value) ? value[0] : value;
  if (
    owner && typeof owner === "object" && "display_name" in owner &&
    typeof owner.display_name === "string" && owner.display_name.trim()
  ) {
    return owner.display_name;
  }
  return "Terigo athlete";
}

export async function handleAccountLists(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "GET") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const { accountId } = await requireAccountSession(request);
    const supabase = serviceClient();
    const currentAccount = await fetchAccountProfile(accountId);
    const currentAccountCode = accountCodeForAthleteID(
      currentAccount.strava_athlete_id,
    );

    const { data: ownedLists, error: ownedListsError } = await supabase
      .from("route_lists")
      .select(
        "id, owner_account_id, name, list_description, visibility, collaboration_mode, share_token, remote_revision, updated_at, app_accounts!route_lists_owner_account_id_fkey(display_name)",
      )
      .eq("owner_account_id", accountId)
      .is("deleted_at", null);

    if (ownedListsError) {
      return jsonResponse({ error: ownedListsError.message }, 500);
    }

    const { data: memberships, error: membershipsError } = await supabase
      .from("route_list_members")
      .select("list_id, role")
      .eq("account_id", accountId);

    if (membershipsError) {
      return jsonResponse({ error: membershipsError.message }, 500);
    }

    const { data: follows, error: followsError } = await supabase
      .from("route_list_followers")
      .select("list_id")
      .eq("account_id", accountId);

    if (followsError) {
      return jsonResponse({ error: followsError.message }, 500);
    }

    const { data: inviteAccessRows, error: inviteAccessError } = await supabase
      .from("route_list_invites")
      .select("list_id, role")
      .eq("invited_email", currentAccountCode);

    if (inviteAccessError) {
      return jsonResponse({ error: inviteAccessError.message }, 500);
    }

    const membershipRoleByListId = new Map(
      (memberships ?? []).map((
        membership,
      ) => [membership.list_id, membership.role]),
    );
    const followedListIDs = new Set(
      (follows ?? []).map((follow) => follow.list_id),
    );
    const ownedListIDs = new Set((ownedLists ?? []).map((list) => list.id));
    const inviteRoleByListId = new Map(
      (inviteAccessRows ?? []).map((invite) => [invite.list_id, invite.role]),
    );

    const extraListIDs = new Set<string>();
    for (const [listId] of membershipRoleByListId) {
      if (!ownedListIDs.has(listId)) {
        extraListIDs.add(listId);
      }
    }
    for (const listId of followedListIDs) {
      if (!ownedListIDs.has(listId)) {
        extraListIDs.add(listId);
      }
    }
    for (const [listId] of inviteRoleByListId) {
      if (!ownedListIDs.has(listId)) {
        extraListIDs.add(listId);
      }
    }

    let extraLists: Array<Record<string, unknown>> = [];
    if (extraListIDs.size > 0) {
      const { data, error } = await supabase
        .from("route_lists")
        .select(
          "id, owner_account_id, name, list_description, visibility, collaboration_mode, share_token, remote_revision, updated_at, app_accounts!route_lists_owner_account_id_fkey(display_name)",
        )
        .in("id", Array.from(extraListIDs))
        .is("deleted_at", null);

      if (error) {
        return jsonResponse({ error: error.message }, 500);
      }

      extraLists = data ?? [];
    }

    const normalizedOwnedLists = (ownedLists ?? []) as unknown as Array<
      Record<string, unknown>
    >;
    const accessibleLists = ([...normalizedOwnedLists, ...extraLists]
      .filter((list) => {
        const listId = list.id as string;
        return ownedListIDs.has(listId) ||
          membershipRoleByListId.has(listId) ||
          inviteRoleByListId.has(listId) ||
          (followedListIDs.has(listId) && list.visibility === "link_view");
      })
      .map((list) => {
        const relationship = ownedListIDs.has(list.id as string)
          ? "owner"
          : membershipRoleByListId.get(list.id as string) === "editor"
          ? "editor"
          : membershipRoleByListId.get(list.id as string) === "viewer"
          ? "viewer"
          : inviteRoleByListId.get(list.id as string) === "editor"
          ? "editor"
          : inviteRoleByListId.get(list.id as string) === "viewer"
          ? "viewer"
          : followedListIDs.has(list.id as string)
          ? "follower"
          : "viewer";
        return {
          ...list,
          relationship,
        };
      })) as Array<Record<string, unknown> & { relationship: string }>;

    const listIds = accessibleLists.map((list) => list.id as string);
    const routesByListId = new Map<string, Array<Record<string, unknown>>>();
    const inviteRowsByListId = new Map<
      string,
      Array<{ invited_email: string; role: string }>
    >();

    if (listIds.length > 0) {
      const { data: invites, error: invitesError } = await supabase
        .from("route_list_invites")
        .select("list_id, invited_email, role")
        .in("list_id", listIds);

      if (invitesError) {
        return jsonResponse({ error: invitesError.message }, 500);
      }

      for (const invite of invites ?? []) {
        const listId = invite.list_id as string;
        const current = inviteRowsByListId.get(listId) ?? [];
        current.push({
          invited_email: String(invite.invited_email),
          role: String(invite.role),
        });
        inviteRowsByListId.set(listId, current);
      }

      const { data: routes, error: routesError } = await supabase
        .from("route_list_routes")
        .select(
          "list_id, strava_route_id, route_name, route_description, distance_meters, elevation_gain_meters, estimated_moving_time, sport_kind, surface_kind, display_location, summary_polyline, detail_polyline, shareability_status, shareability_message, shared_route_snapshots(gpx_payload, gpx_storage_bucket, gpx_storage_path)",
        )
        .in("list_id", listIds)
        .order("sort_order", { ascending: true });

      if (routesError) {
        return jsonResponse({ error: routesError.message }, 500);
      }

      for (const route of routes ?? []) {
        const listId = route.list_id as string;
        const current = routesByListId.get(listId) ?? [];
        current.push(route);
        routesByListId.set(listId, current);
      }
    }

    return jsonResponse({
      lists: accessibleLists.map((list) => {
        const listRoutes = routesByListId.get(list.id as string) ?? [];
        const listInvites = inviteRowsByListId.get(list.id as string) ?? [];
        const relationship = list.relationship as string;
        const canManageSharing = relationship === "owner" ||
          relationship === "editor";
        return {
          listID: list.id,
          shareToken: list.share_token,
          name: list.name,
          listDescription: list.list_description,
          ownerAccountID: list.owner_account_id,
          ownerDisplayName: ownerDisplayName(list.app_accounts),
          visibility: list.visibility,
          collaborationMode: list.collaboration_mode,
          collaboratorCodes: canManageSharing
            ? listInvites
              .filter((invite) => invite.role === "editor")
              .map((invite) => invite.invited_email)
            : [],
          viewerCodes: canManageSharing
            ? listInvites
              .filter((invite) => invite.role === "viewer")
              .map((invite) => invite.invited_email)
            : [],
          relationship: list.relationship,
          revision: list.remote_revision,
          updatedAt: list.updated_at,
          routes: listRoutes.map((route) => ({
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
            isDownloadable: Boolean(
              (route.shared_route_snapshots as {
                gpx_payload?: string | null;
                gpx_storage_bucket?: string | null;
                gpx_storage_path?: string | null;
              } | null)?.gpx_payload ||
                (
                  (route.shared_route_snapshots as {
                    gpx_storage_bucket?: string | null;
                    gpx_storage_path?: string | null;
                  } | null)?.gpx_storage_bucket &&
                  (route.shared_route_snapshots as {
                    gpx_storage_bucket?: string | null;
                    gpx_storage_path?: string | null;
                  } | null)?.gpx_storage_path
                ),
            ),
            downloadURLString: null,
            shareabilityStatus: route.shareability_status,
            shareabilityMessage: route.shareability_message,
          })),
        };
      }),
    });
  } catch (error) {
    if (error instanceof SessionError) {
      return jsonResponse({ error: error.message }, error.status);
    }

    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo account list failure.",
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleAccountLists);
}
