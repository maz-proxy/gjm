import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const appOrigin = "https://projectme-maz.github.io";
const vercelOrigin = "https://m-maz.vercel.app";
const localOrigins = new Set([
  "http://127.0.0.1:8000",
  "http://localhost:8000",
  "http://127.0.0.1:8080",
  "http://localhost:8080",
  "https://localhost",
]);
const corsHeaders = {
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Vary": "Origin",
};

function jsonResponse(status: number, body: Record<string, unknown>, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Access-Control-Allow-Origin": origin,
      "Cache-Control": "no-store",
      "Content-Type": "application/json",
    },
  });
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin") || "";
  const allowedOrigin = origin === appOrigin || origin === vercelOrigin || localOrigins.has(origin);
  if (request.method === "OPTIONS") {
    if (!allowedOrigin) return new Response(null, { status: 403 });
    return new Response("ok", {
      headers: { ...corsHeaders, "Access-Control-Allow-Origin": origin },
    });
  }
  if (!allowedOrigin) return jsonResponse(403, { error: "Origin not allowed." }, appOrigin);
  if (request.method !== "GET") return jsonResponse(405, { error: "Method not allowed." }, origin);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("Missing Supabase function environment configuration.");
    return jsonResponse(500, { error: "Recorded archive service is not configured." }, origin);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: row, error } = await adminClient
    .from("stock_opname_state")
    .select("data")
    .eq("id", "stock-opname-team")
    .maybeSingle();

  if (error) {
    console.error("Public recorded archive lookup failed:", error.message);
    return jsonResponse(503, { error: "Recorded archives are temporarily unavailable." }, origin);
  }

  if (row && (!row.data || !Array.isArray(row.data.sessions))) {
    console.error("Public recorded archive data has an invalid shape.");
    return jsonResponse(500, { error: "Recorded archive data is not available." }, origin);
  }
  const sessions = row?.data?.sessions || [];
  const archivedSessions = sessions
    .filter((session: Record<string, unknown>) =>
      session &&
      typeof session === "object" &&
      typeof session.id === "string" &&
      typeof session.workspaceName === "string" &&
      Boolean(session.snapshot && typeof session.snapshot === "object" && !Array.isArray(session.snapshot))
    )
    .map((session: Record<string, unknown>) => ({
      id: session.id,
      workspaceName: session.workspaceName,
      month: session.month,
      period: session.period,
      finishedAt: session.finishedAt,
      picNames: session.picNames,
      snapshot: session.snapshot,
    }));

  return jsonResponse(200, { sessions: archivedSessions }, origin);
});
