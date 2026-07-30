import { serviceClient } from "./supabase.ts";

type AccountRow = {
  id: string;
  strava_athlete_id: number;
  display_name: string;
  avatar_url: string | null;
  created_at: string;
  updated_at: string;
};

export const accountCodePrefix = "TG-";

export function accountCodeForAthleteID(athleteID: number) {
  return `${accountCodePrefix}${
    Math.trunc(athleteID).toString(36).toUpperCase()
  }`;
}

export function normalizeAccountCode(value: string | null | undefined) {
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

export function normalizeEmail(email: string | null | undefined) {
  return email?.trim().toLowerCase() || null;
}

export function serializeAccountProfile(account: AccountRow) {
  return {
    id: account.id,
    stravaAthleteID: account.strava_athlete_id,
    accountCode: accountCodeForAthleteID(account.strava_athlete_id),
    displayName: account.display_name,
    avatarURLString: account.avatar_url,
    createdAt: account.created_at,
    updatedAt: account.updated_at,
  };
}

export async function fetchAccountProfile(accountId: string) {
  const supabase = serviceClient();
  const { data: account, error } = await supabase
    .from("app_accounts")
    .select(
      "id, strava_athlete_id, display_name, avatar_url, created_at, updated_at",
    )
    .eq("id", accountId)
    .single();

  if (error || !account) {
    throw new Error(error?.message ?? "Could not load the Terigo account.");
  }

  return account as AccountRow;
}
