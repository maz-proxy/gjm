import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const appOrigin = "https://projectme-maz.github.io";
const vercelOrigin = "https://m-maz.vercel.app";
const localOrigins = new Set([
  "http://127.0.0.1:8000",
  "http://localhost:8000",
  "http://127.0.0.1:8080",
  "http://localhost:8080",
]);
const passwordAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%";
const resetTemporaryPassword = "12345678";

function jsonResponse(status: number, body: Record<string, unknown>, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Access-Control-Allow-Origin": origin,
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Content-Type": "application/json",
      "Vary": "Origin",
    },
  });
}

function makeTemporaryPassword() {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return Array.from(bytes, (byte) => passwordAlphabet[byte % passwordAlphabet.length]).join("");
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin") || "";
  const allowedOrigin = origin === appOrigin || origin === vercelOrigin || localOrigins.has(origin);
  if (request.method === "OPTIONS") {
    if (!allowedOrigin) return new Response(null, { status: 403 });
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Vary": "Origin",
      },
    });
  }
  if (!allowedOrigin) return jsonResponse(403, { error: "Origin not allowed." }, appOrigin);
  if (request.method !== "POST") return jsonResponse(405, { error: "Method not allowed." }, origin);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    console.error("Missing Supabase function environment configuration.");
    return jsonResponse(500, { error: "Admin service is not configured." }, origin);
  }

  const authorization = request.headers.get("authorization") || "";
  const accessToken = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!accessToken) return jsonResponse(401, { error: "Silakan login sebagai super admin." }, origin);

  const authClient = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser(accessToken);
  if (
    authError ||
    authData.user?.app_metadata?.role !== "super_admin" ||
    authData.user?.app_metadata?.owner_username !== "indra"
  ) {
    return jsonResponse(403, { error: "Aksi ini hanya untuk super admin." }, origin);
  }

  let input: { action?: string; username?: string; disabled?: boolean };
  try {
    input = await request.json();
  } catch {
    return jsonResponse(400, { error: "Permintaan tidak valid." }, origin);
  }
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  if (input.action === "list") {
    const { data: mappings, error: mappingError } = await adminClient
      .from("stock_opname_usernames")
      .select("username, email")
      .order("username");
    if (mappingError) {
      console.error("Admin username listing failed:", mappingError.message);
      return jsonResponse(503, { error: "Daftar akun gagal dimuat." }, origin);
    }

    const users = [];
    for (let page = 1; ; page++) {
      const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) {
        console.error("Admin auth user listing failed:", error.message);
        return jsonResponse(503, { error: "Daftar akun autentikasi gagal dimuat." }, origin);
      }
      users.push(...data.users);
      if (data.users.length < 1000) break;
    }
    return jsonResponse(200, {
      users: (mappings || []).map((mapping) => {
        const user = users.find((candidate) => candidate.email === mapping.email);
        return {
          username: mapping.username,
          disabled: Boolean(user?.banned_until && new Date(user.banned_until).getTime() > Date.now()),
          superAdmin: user?.app_metadata?.role === "super_admin",
        };
      }),
    }, origin);
  }

  const username = String(input.username || "").trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]{2,29}$/.test(username)) {
    return jsonResponse(400, { error: "Username harus 3–30 karakter: huruf kecil, angka, titik, garis bawah, atau tanda hubung." }, origin);
  }

  if (input.action === "create") {
    const email = `${username}@users.stock-opname.invalid`;
    const { data: existing, error: lookupError } = await adminClient
      .from("stock_opname_usernames")
      .select("username")
      .eq("username", username)
      .maybeSingle();
    if (lookupError) {
      console.error("Admin username lookup failed:", lookupError.message);
      return jsonResponse(503, { error: "Akun tidak dapat diperiksa." }, origin);
    }
    if (existing) return jsonResponse(409, { error: "Username tersebut sudah digunakan." }, origin);

    const temporaryPassword = makeTemporaryPassword();
    const { data: created, error: createError } = await adminClient.auth.admin.createUser({
      email,
      password: temporaryPassword,
      email_confirm: true,
      user_metadata: { username, must_change_password: true },
    });
    if (createError || !created.user) {
      console.error("Admin auth user creation failed:", createError?.message);
      return jsonResponse(400, { error: "Akun gagal dibuat. Periksa apakah username sudah dipakai." }, origin);
    }
    const { error: insertError } = await adminClient
      .from("stock_opname_usernames")
      .insert({ username, email });
    if (insertError) {
      const { error: rollbackError } = await adminClient.auth.admin.deleteUser(created.user.id);
      if (rollbackError) console.error("Admin account rollback failed:", rollbackError.message);
      console.error("Admin username mapping creation failed:", insertError.message);
      return jsonResponse(503, { error: "Akun gagal didaftarkan ke tabel username." }, origin);
    }
    return jsonResponse(201, {
      username,
      temporaryPassword,
      message: "Akun dibuat. Password sementara wajib diganti saat login pertama.",
    }, origin);
  }

  const { data: mapping, error: mappingError } = await adminClient
    .from("stock_opname_usernames")
    .select("email")
    .eq("username", username)
    .maybeSingle();
  if (mappingError || !mapping) {
    if (mappingError) console.error("Admin account lookup failed:", mappingError.message);
    return jsonResponse(404, { error: "Akun tidak ditemukan." }, origin);
  }

  let targetUser = null;
  for (let page = 1; !targetUser; page++) {
    const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) {
      console.error("Admin auth target lookup failed:", error.message);
      return jsonResponse(503, { error: "Akun tidak dapat diperiksa." }, origin);
    }
    targetUser = data.users.find((user) => user.email === mapping.email) || null;
    if (targetUser || data.users.length < 1000) break;
  }
  if (!targetUser) return jsonResponse(404, { error: "Akun autentikasi tidak ditemukan." }, origin);

  if (input.action === "reset-password") {
    const { error } = await adminClient.auth.admin.updateUserById(targetUser.id, {
      password: resetTemporaryPassword,
      user_metadata: {
        ...targetUser.user_metadata,
        username,
        must_change_password: true,
      },
    });
    if (error) {
      console.error("Admin password reset failed:", error.message);
      return jsonResponse(500, { error: "Password gagal direset." }, origin);
    }
    return jsonResponse(200, {
      username,
      temporaryPassword: resetTemporaryPassword,
      message: "Password sementara direset ke 12345678; wajib diganti saat login berikutnya.",
    }, origin);
  }

  if (input.action === "set-disabled") {
    if (targetUser.app_metadata?.owner_username === "indra") {
      return jsonResponse(403, { error: "Akun pemilik tidak dapat dinonaktifkan." }, origin);
    }
    if (typeof input.disabled !== "boolean") {
      return jsonResponse(400, { error: "Status akun tidak valid." }, origin);
    }
    const { error } = await adminClient.auth.admin.updateUserById(targetUser.id, {
      ban_duration: input.disabled ? "876000h" : "none",
    });
    if (error) {
      console.error("Admin account status update failed:", error.message);
      return jsonResponse(500, { error: "Status akun gagal diperbarui." }, origin);
    }
    return jsonResponse(200, {
      message: input.disabled ? `Akun ${username} dinonaktifkan.` : `Akun ${username} diaktifkan kembali.`,
    }, origin);
  }

  return jsonResponse(400, { error: "Aksi admin tidak dikenal." }, origin);
});
