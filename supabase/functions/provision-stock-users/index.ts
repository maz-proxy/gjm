import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const appOrigin = "https://projectme-maz.github.io";
const vercelOrigin = "https://m-maz.vercel.app";
const localOrigins = new Set([
  "http://127.0.0.1:8000",
  "http://localhost:8000",
  "http://127.0.0.1:8080",
  "http://localhost:8080",
]);
const usernames = [
  "indra", "dinar", "beni", "rosadi", "ivan", "iyant", "arief",
  "dimas", "bara", "rino", "ahmad", "rangga", "dyah", "putri",
  "boniex", "andri", "fadhil", "yusuf", "yoga",
];
const passwordAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%";

function jsonResponse(status: number, body: Record<string, unknown>, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Access-Control-Allow-Origin": origin,
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-provisioning-key",
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
  const responseOrigin = origin || appOrigin;
  const allowedOrigin = !origin || origin === appOrigin || origin === vercelOrigin || localOrigins.has(origin);
  if (request.method === "OPTIONS") {
    if (!allowedOrigin) return new Response(null, { status: 403 });
    return jsonResponse(200, {}, responseOrigin);
  }
  if (!allowedOrigin) return jsonResponse(403, { error: "Origin not allowed." }, appOrigin);
  if (request.method !== "POST") return jsonResponse(405, { error: "Method not allowed." }, responseOrigin);

  const expectedKey = Deno.env.get("STOCK_OPNAME_PROVISION_KEY");
  const suppliedKey = request.headers.get("x-provisioning-key") || "";
  let keyDifference = suppliedKey.length ^ (expectedKey || "").length;
  for (let index = 0; index < Math.max(suppliedKey.length, (expectedKey || "").length); index++) {
    keyDifference |= (suppliedKey.charCodeAt(index) || 0) ^ ((expectedKey || "").charCodeAt(index) || 0);
  }
  if (!expectedKey || keyDifference !== 0) {
    return jsonResponse(401, { error: "Provisioning is not authorized." }, responseOrigin);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("Missing Supabase function environment configuration.");
    return jsonResponse(500, { error: "Provisioning service is not configured." }, responseOrigin);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  let input: { action?: string; username?: string; temporaryPassword?: string } = {};
  try {
    input = await request.json();
  } catch {
    return jsonResponse(400, { error: "Invalid request." }, responseOrigin);
  }

  const temporaryPassword = makeTemporaryPassword();
  if (input.action === "promote-owner") {
    const { data: mapping, error: mappingError } = await adminClient
      .from("stock_opname_usernames")
      .select("email")
      .eq("username", "indra")
      .maybeSingle();
    if (mappingError || !mapping) {
      if (mappingError) console.error("Owner username lookup failed:", mappingError.message);
      return jsonResponse(404, { error: "Akun indra tidak ditemukan." }, responseOrigin);
    }

    let owner = null;
    for (let page = 1; !owner; page++) {
      const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) {
        console.error("Owner auth user lookup failed:", error.message);
        return jsonResponse(503, { error: "Akun indra tidak dapat diperiksa." }, responseOrigin);
      }
      owner = data.users.find((user) => user.email === mapping.email) || null;
      if (owner || data.users.length < 1000) break;
    }
    if (!owner) return jsonResponse(404, { error: "Akun autentikasi indra tidak ditemukan." }, responseOrigin);

    const { error } = await adminClient.auth.admin.updateUserById(owner.id, {
      app_metadata: {
        ...owner.app_metadata,
        role: "super_admin",
        owner_username: "indra",
      },
    });
    if (error) {
      console.error("Owner promotion failed:", error.message);
      return jsonResponse(500, { error: "Peran Owner gagal diberikan." }, responseOrigin);
    }
    return jsonResponse(200, {
      username: "indra",
      role: "super_admin",
      message: "Indra sekarang menjadi Owner workspace.",
    }, responseOrigin);
  }

  if (input.action === "reset-all-passwords") {
    if (
      typeof input.temporaryPassword !== "string" ||
      input.temporaryPassword.length < 8 ||
      input.temporaryPassword.length > 72
    ) {
      return jsonResponse(400, { error: "Password sementara harus terdiri dari 8 sampai 72 karakter." }, responseOrigin);
    }

    const { data: mappings, error: mappingsError } = await adminClient
      .from("stock_opname_usernames")
      .select("username, email")
      .in("username", usernames);
    if (mappingsError) {
      console.error("Bulk password reset mapping lookup failed:", mappingsError.message);
      return jsonResponse(503, { error: "Daftar akun tidak dapat diperiksa." }, responseOrigin);
    }

    const mappingsByUsername = new Map((mappings || []).map((mapping) => [mapping.username, mapping.email]));
    let authUsers: Array<{ id: string; email?: string; user_metadata?: Record<string, unknown> }> = [];
    for (let page = 1; ; page++) {
      const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) {
        console.error("Bulk password reset user lookup failed:", error.message);
        return jsonResponse(503, { error: "Daftar akun tidak dapat diperiksa." }, responseOrigin);
      }
      authUsers = authUsers.concat(data.users);
      if (data.users.length < 1000) break;
    }

    const updated: string[] = [];
    const failed: Array<{ username: string; error: string }> = [];
    for (const username of usernames) {
      const email = mappingsByUsername.get(username);
      if (!email) {
        failed.push({ username, error: "Username belum terdaftar." });
        continue;
      }
      const user = authUsers.find((candidate) => candidate.email === email);
      if (!user) {
        failed.push({ username, error: "Akun autentikasi tidak ditemukan." });
        continue;
      }
      const { error } = await adminClient.auth.admin.updateUserById(user.id, {
        password: input.temporaryPassword,
        user_metadata: {
          ...user.user_metadata,
          username,
          must_change_password: true,
        },
      });
      if (error) {
        console.error(`Bulk password reset failed for ${username}:`, error.message);
        failed.push({ username, error: "Password gagal diperbarui." });
      } else {
        updated.push(username);
      }
    }

    return jsonResponse(failed.length ? 207 : 200, {
      updated,
      failed,
      message: failed.length
        ? "Sebagian password gagal direset. Periksa daftar failed."
        : "Semua password direset; setiap pengguna wajib menggantinya saat login berikutnya.",
    }, responseOrigin);
  }
  if (input.action === "reset-password") {
    const username = String(input.username || "").trim().toLowerCase();
    if (!/^[a-z0-9][a-z0-9._-]{2,29}$/.test(username)) {
      return jsonResponse(400, { error: "Username tidak valid." }, responseOrigin);
    }
    const { data: mapping, error: lookupError } = await adminClient
      .from("stock_opname_usernames")
      .select("email")
      .eq("username", username)
      .maybeSingle();
    if (lookupError || !mapping) {
      if (lookupError) console.error("Password reset lookup failed:", lookupError.message);
      return jsonResponse(404, { error: "Akun tidak ditemukan." }, responseOrigin);
    }

    let authUser = null;
    for (let page = 1; !authUser; page++) {
      const { data, error } = await adminClient.auth.admin.listUsers({ page, perPage: 1000 });
      if (error) {
        console.error("Password reset user lookup failed:", error.message);
        return jsonResponse(503, { error: "Akun tidak dapat diperiksa. Coba lagi nanti." }, responseOrigin);
      }
      authUser = data.users.find((user) => user.email === mapping.email) || null;
      if (authUser || data.users.length < 1000) break;
    }
    if (!authUser) return jsonResponse(404, { error: "Akun tidak ditemukan." }, responseOrigin);

    const { error: updateError } = await adminClient.auth.admin.updateUserById(authUser.id, {
      password: temporaryPassword,
      user_metadata: { ...authUser.user_metadata, username, must_change_password: true },
    });
    if (updateError) {
      console.error("Password reset failed:", updateError.message);
      return jsonResponse(500, { error: "Password sementara gagal dibuat." }, responseOrigin);
    }
    return jsonResponse(200, {
      username,
      temporaryPassword,
      message: "Password sementara dibuat. Pengguna wajib menggantinya saat login berikutnya.",
    }, responseOrigin);
  }
  if (input.action && input.action !== "create-users") {
    return jsonResponse(400, { error: "Action tidak dikenal." }, responseOrigin);
  }

  const created: string[] = [];
  const existing: string[] = [];
  const failed: Array<{ username: string; error: string }> = [];

  for (const username of usernames) {
    const email = `${username}@users.stock-opname.invalid`;
    const { data: mapping, error: lookupError } = await adminClient
      .from("stock_opname_usernames")
      .select("username")
      .eq("username", username)
      .maybeSingle();

    if (lookupError) {
      console.error("Username lookup failed:", lookupError.message);
      return jsonResponse(503, {
        error: "Tabel username belum tersedia atau layanan database sedang bermasalah.",
        created,
        existing,
        failed,
        ...(created.length ? { temporaryPassword } : {}),
      }, responseOrigin);
    }
    if (mapping) {
      existing.push(username);
      continue;
    }

    const { data: authData, error: createError } = await adminClient.auth.admin.createUser({
      email,
      password: temporaryPassword,
      email_confirm: true,
      user_metadata: { username, must_change_password: true },
    });
    if (createError || !authData.user) {
      console.error(`Auth user creation failed for ${username}:`, createError?.message);
      failed.push({ username, error: "Akun Auth gagal dibuat." });
      continue;
    }

    const { error: insertError } = await adminClient
      .from("stock_opname_usernames")
      .insert({ username, email });
    if (insertError) {
      const { error: deleteError } = await adminClient.auth.admin.deleteUser(authData.user.id);
      if (deleteError) console.error(`Auth rollback failed for ${username}:`, deleteError.message);
      console.error(`Username mapping creation failed for ${username}:`, insertError.message);
      failed.push({ username, error: "Pemetaan username gagal disimpan." });
      continue;
    }
    created.push(username);
  }

  return jsonResponse(200, {
    created,
    existing,
    failed,
    ...(created.length ? { temporaryPassword } : {}),
    message: failed.length
      ? "Sebagian akun belum berhasil dibuat. Periksa daftar failed sebelum mengulangi proses."
      : "Selesai. Bagikan password sementara kepada staf secara aman; mereka wajib menggantinya saat login pertama.",
  }, responseOrigin);
});
