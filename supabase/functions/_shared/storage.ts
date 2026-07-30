import { serviceClient } from "./supabase.ts";

export const sharedRouteGPXBucket =
  Deno.env.get("ROUTE_VAULT_SHARED_GPX_BUCKET")?.trim() || "route-shared-gpx";

export function sharedRouteGPXPath(accountId: string, stravaRouteId: number) {
  return `${accountId}/${stravaRouteId}.gpx`;
}

export async function uploadSharedRouteGPX(
  accountId: string,
  stravaRouteId: number,
  gpxPayload: string,
) {
  const supabase = serviceClient();
  const path = sharedRouteGPXPath(accountId, stravaRouteId);
  const data = new TextEncoder().encode(gpxPayload);

  const { error } = await supabase.storage
    .from(sharedRouteGPXBucket)
    .upload(path, data, {
      contentType: "application/gpx+xml; charset=utf-8",
      upsert: true,
    });

  if (error) {
    throw new Error(error.message);
  }

  return {
    bucket: sharedRouteGPXBucket,
    path,
    fileSizeBytes: data.byteLength,
  };
}

export async function createSharedRouteDownloadURL(
  bucket: string,
  path: string,
  expiresInSeconds = 300,
) {
  const supabase = serviceClient();
  const { data, error } = await supabase.storage
    .from(bucket)
    .createSignedUrl(path, expiresInSeconds);

  if (error || !data?.signedUrl) {
    throw new Error(
      error?.message ?? "Could not create a signed GPX download URL.",
    );
  }

  return data.signedUrl;
}
