import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { requireAccountSession, SessionError } from "../_shared/session.ts";
import { serviceClient } from "../_shared/supabase.ts";

type FollowRequest = {
  shareToken?: string | null;
  isFollowing?: boolean | null;
};

export async function handleFollowList(request: Request) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed." }, 405);
  }

  try {
    const { accountId } = await requireAccountSession(request);
    const body = await request.json().catch(() => null) as FollowRequest | null;
    const shareToken = body?.shareToken?.trim();

    if (!shareToken || shareToken.length > 256) {
      return jsonResponse({ error: "Missing or invalid share token." }, 400);
    }

    const supabase = serviceClient();
    const { data: list, error: listError } = await supabase
      .from("route_lists")
      .select("id, owner_account_id, visibility")
      .eq("share_token", shareToken)
      .is("deleted_at", null)
      .maybeSingle();

    if (listError || !list) {
      return jsonResponse({ error: "This shared list is unavailable." }, 404);
    }

    if (list.owner_account_id === accountId) {
      return jsonResponse({ ok: true });
    }

    if (body?.isFollowing === false) {
      const { error } = await supabase
        .from("route_list_followers")
        .delete()
        .eq("list_id", list.id)
        .eq("account_id", accountId);

      if (error) {
        return jsonResponse({ error: error.message }, 500);
      }

      return jsonResponse({ ok: true });
    }

    if (list.visibility !== "link_view") {
      return jsonResponse({
        error: "Only public Terigo lists can be followed from a share link.",
      }, 403);
    }

    const { error } = await supabase
      .from("route_list_followers")
      .upsert({
        list_id: list.id,
        account_id: accountId,
      }, {
        onConflict: "list_id,account_id",
      });

    if (error) {
      return jsonResponse({ error: error.message }, 500);
    }

    return jsonResponse({ ok: true });
  } catch (error) {
    if (error instanceof SessionError) {
      return jsonResponse({ error: error.message }, error.status);
    }

    return jsonResponse({
      error: error instanceof Error
        ? error.message
        : "Unexpected Terigo follow failure.",
    }, 500);
  }
}

if (import.meta.main) {
  Deno.serve(handleFollowList);
}
