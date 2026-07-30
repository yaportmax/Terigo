import { corsHeaders } from "./functions/_shared/cors.ts";
import { handleStravaAuthBroker } from "./functions/strava-auth-broker/index.ts";
import {
  handleLocalAccountBootstrap,
  handleLocalAccountLists,
  handleLocalConfirmContactEmail,
  handleLocalDeleteAccount,
  handleLocalFollowList,
  handleLocalSharedList,
  handleLocalStartContactEmailVerification,
  handleLocalSubmitFeedback,
  handleLocalSyncList,
} from "./local-dev-backend.ts";

type RouteHandler = (request: Request) => Response | Promise<Response>;

const port = Number(Deno.env.get("TERIGO_LOCAL_FUNCTIONS_PORT") ?? "54321");
const hostname = Deno.env.get("TERIGO_LOCAL_FUNCTIONS_HOST")?.trim() ||
  "127.0.0.1";

const routeHandlers = new Map<string, RouteHandler>([
  ["/functions/v1/account-bootstrap", handleLocalAccountBootstrap],
  ["/functions/v1/account-lists", handleLocalAccountLists],
  ["/functions/v1/confirm-contact-email", handleLocalConfirmContactEmail],
  ["/functions/v1/delete-account", handleLocalDeleteAccount],
  ["/functions/v1/follow-list", handleLocalFollowList],
  ["/functions/v1/shared-list", handleLocalSharedList],
  [
    "/functions/v1/start-contact-email-verification",
    handleLocalStartContactEmailVerification,
  ],
  ["/functions/v1/strava-auth-broker/exchange", handleStravaAuthBroker],
  ["/functions/v1/strava-auth-broker/refresh", handleStravaAuthBroker],
  ["/functions/v1/submit-feedback", handleLocalSubmitFeedback],
  ["/functions/v1/sync-list", handleLocalSyncList],
]);

function notFoundResponse(path: string) {
  return new Response(
    JSON.stringify({
      code: "NOT_FOUND",
      message: `Requested function was not found: ${path}`,
    }),
    {
      status: 404,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json; charset=utf-8",
      },
    },
  );
}

console.log(`Terigo local backend listening on http://${hostname}:${port}`);

Deno.serve({ hostname, port }, async (request) => {
  const path = new URL(request.url).pathname;

  if (path === "/healthz") {
    return new Response("ok", {
      status: 200,
      headers: corsHeaders,
    });
  }

  const handler = routeHandlers.get(path);
  if (!handler) {
    return notFoundResponse(path);
  }

  return await handler(request);
});
