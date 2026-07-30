import { corsHeaders, jsonResponse } from "./functions/_shared/cors.ts";

type Visibility = "private" | "invited_viewers" | "link_view";
type CollaborationMode = "owner_only" | "link_editors" | "invited_editors";
type MemberRole = "owner" | "editor" | "viewer";
type Relationship = "owner" | "editor" | "viewer" | "follower";

type BootstrapRequest = {
  stravaSession?: { accessToken?: string | null } | null;
  device?: {
    platform?: string | null;
    appVersion?: string | null;
    buildNumber?: string | null;
  } | null;
};

type StravaAthlete = {
  id: number;
  username?: string | null;
  firstname?: string | null;
  lastname?: string | null;
  profile_medium?: string | null;
  profile?: string | null;
};

type FollowRequest = {
  shareToken?: string | null;
  isFollowing?: boolean | null;
};

type SyncListRequest = {
  clientListID: string;
  remoteListID?: string | null;
  remoteShareToken?: string | null;
  expectedRevision?: number | null;
  name: string;
  listDescription: string;
  visibility: Visibility;
  collaborationMode: CollaborationMode;
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

type Store = {
  accounts: AccountRecord[];
  sessions: SessionRecord[];
  lists: ListRecord[];
  members: MemberRecord[];
  invites: InviteRecord[];
  followers: FollowerRecord[];
  routes: RouteRecord[];
  feedback: FeedbackRecord[];
};

type AccountRecord = {
  id: string;
  stravaAthleteID: number;
  displayName: string;
  avatarURLString: string | null;
  createdAt: string;
  updatedAt: string;
};

type SessionRecord = {
  token: string;
  accountId: string;
  expiresAt: string;
  createdAt: string;
  lastUsedAt: string;
  devicePlatform: string | null;
  appVersion: string | null;
  buildNumber: string | null;
};

type ListRecord = {
  id: string;
  ownerAccountID: string;
  clientListID: string | null;
  name: string;
  listDescription: string;
  visibility: Visibility;
  collaborationMode: CollaborationMode;
  shareToken: string;
  remoteRevision: number;
  createdAt: string;
  updatedAt: string;
  deletedAt: string | null;
};

type MemberRecord = {
  listId: string;
  accountId: string;
  role: MemberRole;
};

type InviteRecord = {
  listId: string;
  invitedAccountCode: string;
  role: Exclude<MemberRole, "owner">;
};

type FollowerRecord = {
  listId: string;
  accountId: string;
};

type RouteRecord = {
  listId: string;
  stravaRouteID: number;
  routeName: string;
  routeDescription: string;
  distanceMeters: number;
  elevationGainMeters: number;
  estimatedMovingTime: number;
  sportKind: string;
  surfaceKind: string | null;
  displayLocation: string;
  summaryPolyline: string;
  detailPolyline: string | null;
  shareabilityStatus:
    | "viewable"
    | "downloadable"
    | "blocked_private_not_downloaded"
    | "view_only";
  shareabilityMessage: string | null;
  sortOrder: number;
  gpxPayload: string | null;
};

type FeedbackRecord = {
  id: string;
  accountId: string;
  sessionId: string | null;
  stravaAthleteID: number;
  displayName: string;
  message: string;
  sourceScreen: string;
  appVersion: string | null;
  buildNumber: string | null;
  createdAt: string;
};

const storePath = Deno.env.get("TERIGO_LOCAL_BACKEND_STORE_PATH")?.trim() ||
  "/Users/myaport/Documents/test-repo/dev2/supabase/.local-backend/store.json";

async function ensureStoreDir() {
  await Deno.mkdir(new URL(".", new URL(`file://${storePath}`)).pathname, {
    recursive: true,
  });
}

async function loadStore(): Promise<Store> {
  try {
    const raw = await Deno.readTextFile(storePath);
    const parsed = JSON.parse(raw) as Partial<Store>;
    const parsedInvites = (parsed.invites ?? []) as Array<
      InviteRecord & { invitedEmail?: string }
    >;
    return {
      accounts: parsed.accounts ?? [],
      sessions: parsed.sessions ?? [],
      lists: parsed.lists ?? [],
      members: parsed.members ?? [],
      invites: parsedInvites
        .map((invite) => ({
          listId: invite.listId,
          invitedAccountCode: normalizeAccountCode(
            invite.invitedAccountCode ?? invite.invitedEmail,
          ) ?? "",
          role: invite.role,
        }))
        .filter((invite) => invite.invitedAccountCode.length > 0),
      followers: parsed.followers ?? [],
      routes: parsed.routes ?? [],
      feedback: parsed.feedback ?? [],
    };
  } catch {
    return {
      accounts: [],
      sessions: [],
      lists: [],
      members: [],
      invites: [],
      followers: [],
      routes: [],
      feedback: [],
    };
  }
}

let store = await loadStore();
let persistQueue = Promise.resolve();

function queuePersist() {
  persistQueue = persistQueue.then(async () => {
    await ensureStoreDir();
    await Deno.writeTextFile(storePath, JSON.stringify(store, null, 2));
  });
  return persistQueue;
}

function nowISO() {
  return new Date().toISOString();
}

const accountCodePrefix = "TG-";

function accountCodeForAthleteID(athleteID: number) {
  return `${accountCodePrefix}${
    Math.trunc(athleteID).toString(36).toUpperCase()
  }`;
}

function normalizeAccountCode(value: string | null | undefined) {
  const trimmed = value?.trim().toUpperCase().replaceAll(" ", "") || "";
  if (!trimmed) {
    return null;
  }

  if (/^\d+$/.test(trimmed)) {
    const athleteID = Number(trimmed);
    return Number.isSafeInteger(athleteID) && athleteID > 0
      ? accountCodeForAthleteID(athleteID)
      : null;
  }

  const payload = trimmed.startsWith(accountCodePrefix)
    ? trimmed.slice(accountCodePrefix.length)
    : trimmed;

  if (!/^[0-9A-Z]+$/.test(payload)) {
    return null;
  }

  return `${accountCodePrefix}${payload}`;
}

function randomToken() {
  return crypto.randomUUID().replaceAll("-", "") +
    crypto.randomUUID().replaceAll("-", "");
}

function relationshipRank(role: Relationship) {
  switch (role) {
    case "owner":
      return 4;
    case "editor":
      return 3;
    case "viewer":
      return 2;
    case "follower":
      return 1;
  }
}

function parseBearer(request: Request) {
  const raw = request.headers.get("x-routevault-session") ??
    request.headers.get("authorization") ?? "";
  const trimmed = raw.replace(/^Bearer\s+/i, "").trim();
  return trimmed.length > 0 ? trimmed : null;
}

function accountCodeForAccountId(accountId: string | null) {
  if (!accountId) {
    return null;
  }

  const account = store.accounts.find((candidate) => candidate.id == accountId);
  return account ? accountCodeForAthleteID(account.stravaAthleteID) : null;
}

function notAuthenticatedResponse() {
  return jsonResponse({
    error: "Terigo account session is invalid or expired.",
  }, 401);
}

async function requireSession(request: Request) {
  const token = parseBearer(request);
  if (!token) {
    return null;
  }

  const now = Date.now();
  const session = store.sessions.find((candidate) =>
    candidate.token == token && new Date(candidate.expiresAt).getTime() > now
  );
  if (!session) {
    return null;
  }

  session.lastUsedAt = nowISO();
  await queuePersist();
  return session;
}

function displayNameFromAthlete(athlete: StravaAthlete) {
  return [athlete.firstname, athlete.lastname].filter(Boolean).join(" ")
    .trim() ||
    athlete.username?.trim() ||
    "Connected Athlete";
}

function serializeAccountProfile(account: AccountRecord) {
  return {
    id: account.id,
    stravaAthleteID: account.stravaAthleteID,
    accountCode: accountCodeForAthleteID(account.stravaAthleteID),
    displayName: account.displayName,
    avatarURLString: account.avatarURLString,
    createdAt: account.createdAt,
    updatedAt: account.updatedAt,
  };
}

function shareURL(origin: string, token: string) {
  return `${origin}/functions/v1/shared-list?token=${
    encodeURIComponent(token)
  }`;
}

function routePayload(route: RouteRecord, token: string, origin: string) {
  return {
    stravaRouteID: route.stravaRouteID,
    name: route.routeName,
    routeDescription: route.routeDescription,
    distanceMeters: route.distanceMeters,
    elevationGainMeters: route.elevationGainMeters,
    estimatedMovingTime: route.estimatedMovingTime,
    sportKind: route.sportKind,
    surfaceKind: route.surfaceKind,
    displayLocation: route.displayLocation,
    summaryPolyline: route.summaryPolyline,
    detailPolyline: route.detailPolyline,
    isDownloadable: Boolean(route.gpxPayload?.trim()),
    downloadURLString: route.gpxPayload?.trim()
      ? `${origin}/functions/v1/shared-list?token=${
        encodeURIComponent(token)
      }&downloadRouteID=${route.stravaRouteID}`
      : null,
    shareabilityStatus: route.shareabilityStatus,
    shareabilityMessage: route.shareabilityMessage,
  };
}

function canOpenList(list: ListRecord, accountId: string | null) {
  if (list.visibility == "link_view") {
    return true;
  }

  if (!accountId) {
    return false;
  }

  if (list.ownerAccountID == accountId) {
    return true;
  }

  if (
    store.members.some((member) =>
      member.listId == list.id && member.accountId == accountId
    )
  ) {
    return true;
  }

  const accountCode = accountCodeForAccountId(accountId);
  return Boolean(
    accountCode &&
      store.invites.some((invite) =>
        invite.listId == list.id && invite.invitedAccountCode == accountCode
      ),
  );
}

function canEditList(
  list: ListRecord,
  accountId: string | null,
  remoteShareToken: string | null | undefined,
) {
  if (accountId && list.ownerAccountID == accountId) {
    return true;
  }

  if (accountId) {
    const membership = store.members.find((member) =>
      member.listId == list.id && member.accountId == accountId
    );
    if (membership?.role == "owner" || membership?.role == "editor") {
      return true;
    }
  }

  const accountCode = accountCodeForAccountId(accountId);
  if (accountCode) {
    const invite = store.invites.find((candidate) =>
      candidate.listId == list.id && candidate.invitedAccountCode == accountCode
    );
    if (invite?.role == "editor") {
      return true;
    }
  }

  return list.collaborationMode == "link_editors" &&
    remoteShareToken?.trim() == list.shareToken;
}

function listRelationship(list: ListRecord, accountId: string) {
  let best: Relationship | null = list.ownerAccountID == accountId
    ? "owner"
    : null;

  const membership = store.members.find((member) =>
    member.listId == list.id && member.accountId == accountId
  );
  if (membership) {
    const relation: Relationship = membership.role == "owner"
      ? "owner"
      : membership.role;
    if (!best || relationshipRank(relation) > relationshipRank(best)) {
      best = relation;
    }
  }

  const accountCode = accountCodeForAccountId(accountId);
  const invite = accountCode
    ? store.invites.find((candidate) =>
      candidate.listId == list.id && candidate.invitedAccountCode == accountCode
    )
    : null;
  if (invite) {
    const relation: Relationship = invite.role == "editor"
      ? "editor"
      : "viewer";
    if (!best || relationshipRank(relation) > relationshipRank(best)) {
      best = relation;
    }
  }

  if (
    store.followers.some((follower) =>
      follower.listId == list.id && follower.accountId == accountId
    )
  ) {
    if (!best || relationshipRank("follower") > relationshipRank(best)) {
      best = "follower";
    }
  }

  return best;
}

function htmlEscape(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

export async function handleLocalAccountBootstrap(request: Request) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method != "POST") {
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

    if (athleteResponse.status == 401 || athleteResponse.status == 403) {
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

    const now = nowISO();
    const existing = store.accounts.find((account) =>
      account.stravaAthleteID == athlete.id
    );
    const account = existing ?? {
      id: crypto.randomUUID(),
      stravaAthleteID: athlete.id,
      displayName: "",
      avatarURLString: null,
      createdAt: now,
      updatedAt: now,
    };

    account.displayName = displayNameFromAthlete(athlete);
    account.avatarURLString = athlete.profile_medium ?? athlete.profile ?? null;
    account.updatedAt = now;

    if (!existing) {
      store.accounts.push(account);
    }

    const rawToken = randomToken();
    const expiresAt = new Date(Date.now() + 1000 * 60 * 60 * 24 * 45)
      .toISOString();
    store.sessions.push({
      token: rawToken,
      accountId: account.id,
      expiresAt,
      createdAt: now,
      lastUsedAt: now,
      devicePlatform: body?.device?.platform?.trim() ?? "ios",
      appVersion: body?.device?.appVersion?.trim() ?? null,
      buildNumber: body?.device?.buildNumber?.trim() ?? null,
    });

    await queuePersist();

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

export async function handleLocalAccountLists(request: Request) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const session = await requireSession(request);
  if (!session) {
    return notAuthenticatedResponse();
  }

  const visibleLists = store.lists
    .filter((list) => !list.deletedAt)
    .map((list) => ({
      list,
      relationship: listRelationship(list, session.accountId),
    }))
    .filter((entry) => entry.relationship);

  return jsonResponse({
    lists: visibleLists.map(({ list, relationship }) => {
      const owner = store.accounts.find((account) =>
        account.id == list.ownerAccountID
      );
      const routes = store.routes
        .filter((route) => route.listId == list.id)
        .sort((lhs, rhs) => lhs.sortOrder - rhs.sortOrder);
      const canManageSharing = relationship == "owner" ||
        relationship == "editor";
      return {
        listID: list.id,
        shareToken: list.shareToken,
        name: list.name,
        listDescription: list.listDescription,
        ownerAccountID: list.ownerAccountID,
        ownerDisplayName: owner?.displayName ?? "Terigo athlete",
        visibility: list.visibility,
        collaborationMode: list.collaborationMode,
        collaboratorCodes: canManageSharing
          ? store.invites.filter((invite) =>
            invite.listId == list.id && invite.role == "editor"
          ).map((invite) => invite.invitedAccountCode)
          : [],
        viewerCodes: canManageSharing
          ? store.invites.filter((invite) =>
            invite.listId == list.id && invite.role == "viewer"
          ).map((invite) => invite.invitedAccountCode)
          : [],
        relationship,
        revision: list.remoteRevision,
        updatedAt: list.updatedAt,
        routes: routes.map((route) =>
          routePayload(route, list.shareToken, new URL(request.url).origin)
        ),
      };
    }),
  });
}

export async function handleLocalDeleteAccount(request: Request) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method != "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  const session = await requireSession(request);
  if (!session) {
    return notAuthenticatedResponse();
  }

  const accountCode = accountCodeForAccountId(session.accountId);
  const ownedListIDs = new Set(
    store.lists
      .filter((list) => list.ownerAccountID == session.accountId)
      .map((list) => list.id),
  );

  store.routes = store.routes.filter((route) =>
    !ownedListIDs.has(route.listId)
  );
  store.members = store.members.filter((member) =>
    !ownedListIDs.has(member.listId) && member.accountId != session.accountId
  );
  store.invites = store.invites.filter((invite) =>
    !ownedListIDs.has(invite.listId) &&
    invite.invitedAccountCode != accountCode
  );
  store.followers = store.followers.filter((follower) =>
    !ownedListIDs.has(follower.listId) &&
    follower.accountId != session.accountId
  );
  store.lists = store.lists.filter((list) => !ownedListIDs.has(list.id));
  store.feedback = store.feedback.filter((entry) =>
    entry.accountId != session.accountId
  );
  store.sessions = store.sessions.filter((candidate) =>
    candidate.accountId != session.accountId
  );
  store.accounts = store.accounts.filter((account) =>
    account.id != session.accountId
  );

  await queuePersist();
  return jsonResponse({ deleted: true });
}

export async function handleLocalStartContactEmailVerification(
  request: Request,
) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  return jsonResponse({
    error:
      "Terigo no longer uses invite-email verification. Share a Strava-backed Terigo account code instead.",
  }, 410);
}

export async function handleLocalConfirmContactEmail(request: Request) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  return jsonResponse({
    error:
      "Terigo no longer uses invite-email verification. Share a Strava-backed Terigo account code instead.",
  }, 410);
}

export async function handleLocalFollowList(request: Request) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const session = await requireSession(request);
  if (!session) {
    return notAuthenticatedResponse();
  }

  try {
    const body = await request.json() as FollowRequest;
    const shareToken = body.shareToken?.trim();
    if (!shareToken) {
      return jsonResponse({ error: "Missing share token." }, 400);
    }

    const list = store.lists.find((candidate) =>
      candidate.shareToken == shareToken && !candidate.deletedAt
    );
    if (!list) {
      return jsonResponse({ error: "This shared list is unavailable." }, 404);
    }

    if (list.ownerAccountID == session.accountId) {
      return jsonResponse({ ok: true });
    }

    if (body.isFollowing === false) {
      store.followers = store.followers.filter((follower) =>
        !(follower.listId == list.id && follower.accountId == session.accountId)
      );
      await queuePersist();
      return jsonResponse({ ok: true });
    }

    if (list.visibility != "link_view") {
      return jsonResponse({
        error: "Only public Terigo lists can be followed from a share link.",
      }, 403);
    }

    if (
      !store.followers.some((follower) =>
        follower.listId == list.id && follower.accountId == session.accountId
      )
    ) {
      store.followers.push({ listId: list.id, accountId: session.accountId });
      await queuePersist();
    }

    return jsonResponse({ ok: true });
  } catch (error) {
    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo follow failure.",
    }, 500);
  }
}

export async function handleLocalSubmitFeedback(request: Request) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const session = await requireSession(request);
  if (!session) {
    return notAuthenticatedResponse();
  }

  try {
    const body = await request.json() as {
      message?: string | null;
      sourceScreen?: string | null;
      appVersion?: string | null;
      buildNumber?: string | null;
    };
    const message = body.message?.trim();
    if (!message) {
      return jsonResponse({ error: "Feedback message is required." }, 400);
    }

    const account = store.accounts.find((candidate) =>
      candidate.id == session.accountId
    );
    if (!account) {
      return jsonResponse({
        error: "Connected Terigo account could not be found.",
      }, 404);
    }

    store.feedback.push({
      id: crypto.randomUUID(),
      accountId: account.id,
      sessionId: session.token,
      stravaAthleteID: account.stravaAthleteID,
      displayName: account.displayName,
      message,
      sourceScreen: body.sourceScreen?.trim() || "unknown",
      appVersion: body.appVersion?.trim() ?? null,
      buildNumber: body.buildNumber?.trim() ?? null,
      createdAt: nowISO(),
    });
    await queuePersist();
    return jsonResponse({ ok: true });
  } catch (error) {
    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo feedback failure.",
    }, 500);
  }
}

export async function handleLocalSharedList(request: Request) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = new URL(request.url);
    const shareToken = url.searchParams.get("token")?.trim();
    const downloadRouteID = url.searchParams.get("downloadRouteID")?.trim();
    if (!shareToken) {
      return jsonResponse({ error: "Missing share token." }, 400);
    }

    const list = store.lists.find((candidate) =>
      candidate.shareToken == shareToken && !candidate.deletedAt
    );
    if (!list) {
      return jsonResponse({
        error: "This shared list is unavailable or private.",
      }, 404);
    }

    const session = await requireSession(request);
    const accountId = session?.accountId ?? null;
    if (!canOpenList(list, accountId)) {
      return jsonResponse({
        error: "This shared list is limited to specific Terigo accounts.",
      }, 403);
    }

    const routes = store.routes
      .filter((route) => route.listId == list.id)
      .sort((lhs, rhs) => lhs.sortOrder - rhs.sortOrder);

    if (downloadRouteID) {
      const route = routes.find((candidate) =>
        String(candidate.stravaRouteID) == downloadRouteID
      );
      if (!route?.gpxPayload?.trim()) {
        return jsonResponse({
          error: "This route is not downloadable from the shared list.",
        }, 404);
      }

      return new Response(route.gpxPayload, {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/gpx+xml; charset=utf-8",
          "Content-Disposition": `attachment; filename=\"${
            route.routeName.replaceAll('"', "")
          }.gpx\"`,
        },
      });
    }

    const owner = store.accounts.find((account) =>
      account.id == list.ownerAccountID
    );
    const payload = {
      listID: list.id,
      name: list.name,
      listDescription: list.listDescription,
      ownerDisplayName: owner?.displayName ?? "Terigo athlete",
      visibility: list.visibility,
      collaborationMode: list.collaborationMode,
      collaboratorCodes: [],
      viewerCodes: [],
      revision: list.remoteRevision,
      updatedAt: list.updatedAt,
      routes: routes.map((route) =>
        routePayload(route, list.shareToken, url.origin)
      ),
    };

    const acceptsHTML = (request.headers.get("accept") ?? "").includes(
      "text/html",
    );
    if (!acceptsHTML) {
      return jsonResponse(payload);
    }

    const routeMarkup = payload.routes.map((route) => `
      <li>
        <strong>${htmlEscape(route.name)}</strong>
        <div>${htmlEscape(route.displayLocation ?? "")}</div>
        <div>${Math.round(route.distanceMeters)} m • ${
      Math.round(route.elevationGainMeters)
    } m climb • ${htmlEscape(route.sportKind)}</div>
        ${
      route.isDownloadable
        ? `<a href="${
          htmlEscape(route.downloadURLString ?? "#")
        }">Download GPX</a>`
        : `<span>${htmlEscape(route.shareabilityMessage ?? "View only")}</span>`
    }
      </li>
    `).join("");

    const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>${htmlEscape(list.name)} • Terigo</title>
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
      <h1>${htmlEscape(list.name)}</h1>
      <div class="meta">By ${
      htmlEscape(owner?.displayName ?? "Terigo athlete")
    } • Updated ${htmlEscape(new Date(list.updatedAt).toLocaleString())}</div>
      <p>${htmlEscape(list.listDescription ?? "")}</p>
      <p><a href="${
      htmlEscape(shareURL(url.origin, shareToken))
    }">Open in Terigo</a></p>
      <p><a href="routevault://lists/shared?token=${
      encodeURIComponent(shareToken)
    }">Fallback deep link</a></p>
    </div>
    <ul>${routeMarkup}</ul>
  </main>
</body>
</html>`;

    return new Response(html, {
      status: 200,
      headers: {
        ...corsHeaders,
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

export async function handleLocalSyncList(request: Request) {
  if (request.method == "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const session = await requireSession(request);
  if (!session) {
    return notAuthenticatedResponse();
  }

  try {
    const body = await request.json() as SyncListRequest;
    const now = nowISO();
    const currentAccountCode = accountCodeForAccountId(session.accountId);
    const collaboratorCodes = Array.from(
      new Set(
        (body.collaboratorCodes ?? body.collaboratorEmails ?? [])
          .map((value) => normalizeAccountCode(value))
          .filter(Boolean),
      ),
    ) as string[];
    const viewerCodes = Array.from(
      new Set(
        (body.viewerCodes ?? body.viewerEmails ?? [])
          .map((value) => normalizeAccountCode(value))
          .filter(Boolean),
      ),
    ) as string[];

    if (
      body.visibility == "invited_viewers" &&
      body.collaborationMode == "link_editors"
    ) {
      return jsonResponse({
        error:
          "Lists limited to specific viewers cannot also allow anyone with the link to edit.",
      }, 400);
    }

    let list = body.remoteListID
      ? store.lists.find((candidate) =>
        candidate.id == body.remoteListID && !candidate.deletedAt
      )
      : null;
    let isNewList = false;

    if (!list) {
      list = store.lists.find((candidate) =>
        candidate.ownerAccountID == session.accountId &&
        candidate.clientListID == body.clientListID &&
        !candidate.deletedAt
      ) ?? null;
    }

    if (list) {
      if (!canEditList(list, session.accountId, body.remoteShareToken)) {
        return jsonResponse({
          error: "You do not have permission to edit this list.",
        }, 403);
      }

      if (
        body.expectedRevision !== undefined && body.expectedRevision !== null &&
        body.expectedRevision != list.remoteRevision
      ) {
        return jsonResponse({
          error:
            "This list changed in Terigo on another device. Reload the latest version before syncing again.",
          currentRevision: list.remoteRevision,
        }, 409);
      }
    } else {
      const createdList: ListRecord = {
        id: crypto.randomUUID(),
        ownerAccountID: session.accountId,
        clientListID: body.clientListID,
        name: body.name,
        listDescription: body.listDescription ?? "",
        visibility: body.visibility,
        collaborationMode: body.collaborationMode,
        shareToken: randomToken().slice(0, 36),
        remoteRevision: 1,
        createdAt: now,
        updatedAt: now,
        deletedAt: null,
      };
      list = createdList;
      store.lists.push(createdList);
      store.members = store.members.filter((member) =>
        !(
          member.listId == createdList.id &&
          member.accountId == session.accountId
        )
      );
      store.members.push({
        listId: createdList.id,
        accountId: session.accountId,
        role: "owner",
      });
      isNewList = true;
    }

    list.name = body.name;
    list.listDescription = body.listDescription ?? "";
    list.visibility = body.visibility;
    list.collaborationMode = body.collaborationMode;
    list.updatedAt = now;
    list.remoteRevision = isNewList ? 1 : list.remoteRevision + 1;

    const desiredInvites = new Map<string, Exclude<MemberRole, "owner">>();
    if (body.visibility == "invited_viewers") {
      for (const code of viewerCodes) {
        if (code != currentAccountCode) {
          desiredInvites.set(code, "viewer");
        }
      }
    }
    if (body.collaborationMode == "invited_editors") {
      for (const code of collaboratorCodes) {
        if (code != currentAccountCode) {
          desiredInvites.set(code, "editor");
        }
      }
    }
    store.invites = store.invites.filter((invite) =>
      invite.listId != list.id || desiredInvites.has(invite.invitedAccountCode)
    );
    for (const [code, role] of desiredInvites.entries()) {
      const existing = store.invites.find((invite) =>
        invite.listId == list.id && invite.invitedAccountCode == code
      );
      if (existing) {
        existing.role = role;
      } else {
        store.invites.push({ listId: list.id, invitedAccountCode: code, role });
      }
    }

    store.routes = store.routes.filter((route) => route.listId != list.id);

    const shareabilityIssues: Array<
      { routeID: number; routeName: string; kind: string }
    > = [];
    for (const [index, route] of (body.routes ?? []).entries()) {
      const gpxPayload = route.gpxPayload?.trim() || null;
      let shareabilityStatus: RouteRecord["shareabilityStatus"] = "view_only";
      let shareabilityMessage: string | null =
        "Other people can see this route in the list, but it cannot be downloaded until route details are downloaded in Terigo.";

      if (gpxPayload) {
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

      store.routes.push({
        listId: list.id,
        stravaRouteID: route.stravaRouteID,
        routeName: route.name,
        routeDescription: route.routeDescription ?? "",
        distanceMeters: route.distanceMeters ?? 0,
        elevationGainMeters: route.elevationGainMeters ?? 0,
        estimatedMovingTime: route.estimatedMovingTime ?? 0,
        sportKind: route.sportKind ?? "other",
        surfaceKind: route.surfaceKind ?? null,
        displayLocation: route.displayLocation ?? "",
        summaryPolyline: route.summaryPolyline ?? "",
        detailPolyline: route.detailPolyline ?? null,
        shareabilityStatus,
        shareabilityMessage,
        sortOrder: index,
        gpxPayload,
      });
    }

    await queuePersist();

    return jsonResponse({
      listID: list.id,
      ownerAccountID: list.ownerAccountID,
      shareToken: list.shareToken,
      revision: list.remoteRevision,
      updatedAt: list.updatedAt,
      shareabilityIssues,
    });
  } catch (error) {
    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo list sync failure.",
    }, 500);
  }
}
