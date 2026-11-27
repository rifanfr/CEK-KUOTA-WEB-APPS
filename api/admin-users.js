const ALLOWED_ROLES = new Set(['admin', 'warehouse_admin', 'cashier']);
const UPSTREAM_TIMEOUT_MS = 10000;
const MAX_LIST_PAGES = 5;
const USERS_PER_PAGE = 200;

function sendJson(res, status, payload) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(payload));
}

function toSafeUser(user) {
  const appMeta = user && user.app_metadata && typeof user.app_metadata === 'object' ? user.app_metadata : {};
  const emailConfirmedAt = user && (user.email_confirmed_at || user.confirmed_at)
    ? String(user.email_confirmed_at || user.confirmed_at)
    : null;
  return {
    id: user && user.id ? String(user.id) : '',
    email: user && user.email ? String(user.email) : '',
    role: typeof appMeta.role === 'string' ? appMeta.role : null,
    created_at: user && user.created_at ? user.created_at : null,
    last_sign_in_at: user && user.last_sign_in_at ? user.last_sign_in_at : null,
    email_confirmed_at: emailConfirmedAt,
    invited_at: user && user.invited_at ? String(user.invited_at) : null,
    is_active: Boolean(emailConfirmedAt),
  };
}

function resolveSafeRedirectTo(req, candidateUrl) {
  const hostHeader = req && req.headers && (req.headers['x-forwarded-host'] || req.headers.host);
  const host = typeof hostHeader === 'string' ? hostHeader.split(',')[0].trim().toLowerCase() : '';
  const protoHeader = req && req.headers && req.headers['x-forwarded-proto'];
  const proto = typeof protoHeader === 'string' && /^https?$/i.test(protoHeader.split(',')[0].trim())
    ? protoHeader.split(',')[0].trim().toLowerCase()
    : (host.startsWith('localhost') || host.startsWith('127.0.0.1') ? 'http' : 'https');

  if (typeof candidateUrl === 'string' && candidateUrl.trim()) {
    try {
      const parsed = new URL(candidateUrl.trim());
      const isAllowedScheme = parsed.protocol === 'https:'
        || (parsed.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(parsed.hostname));
      const sameHost = !host || parsed.host.toLowerCase() === host;
      if (isAllowedScheme && sameHost && /\/dispatch-console(\.html)?$/i.test(parsed.pathname)) {
        return `${parsed.origin}${parsed.pathname}`;
      }
    } catch (e) {}
  }

  return host ? `${proto}://${host}/dispatch-console` : '';
}

function buildRedirectQuery(redirectTo) {
  return redirectTo ? `?redirect_to=${encodeURIComponent(redirectTo)}` : '';
}

function isSyntheticLocalEmail(email) {
  return /\.local$/i.test(String(email || '').trim());
}

async function fetchWithTimeout(url, options = {}, timeoutMs = UPSTREAM_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function parseJsonBody(req) {
  if (req.body && typeof req.body === 'object' && !Buffer.isBuffer(req.body)) {
    return req.body;
  }
  if (typeof req.body === 'string') {
    return req.body.trim() ? JSON.parse(req.body) : {};
  }
  if (Buffer.isBuffer(req.body)) {
    const text = req.body.toString('utf8').trim();
    return text ? JSON.parse(text) : {};
  }

  const chunks = [];
  for await (const chunk of req) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8').trim();
  if (!raw) return {};
  return JSON.parse(raw);
}

function extractBearerToken(req) {
  const authHeader = req.headers && (req.headers.authorization || req.headers.Authorization);
  if (!authHeader || typeof authHeader !== 'string') return null;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token || null;
}

function getUpstreamErrorMessage(payload, fallbackMsg) {
  if (!payload || typeof payload !== 'object') return fallbackMsg;
  const msg = payload.msg || payload.error_description || payload.message || payload.error;
  return (typeof msg === 'string' && msg.trim()) ? msg.trim() : fallbackMsg;
}

async function verifyCallerAdmin(supabaseUrl, serviceRoleKey, callerToken) {
  const res = await fetchWithTimeout(`${supabaseUrl}/auth/v1/user`, {
    method: 'GET',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${callerToken}`,
    },
  });

  if (!res.ok) {
    return { status: 401, error: 'Unauthorized: Sesi login tidak valid atau kedaluwarsa.' };
  }

  const user = await res.json().catch(() => null);
  if (!user || !user.id) {
    return { status: 401, error: 'Unauthorized: Identitas pengguna tidak ditemukan.' };
  }

  const callerRole = String(user.app_metadata && user.app_metadata.role ? user.app_metadata.role : '')
    .trim()
    .toLowerCase();
  if (callerRole !== 'admin') {
    return { status: 403, error: 'Forbidden: Hanya akun dengan peran admin yang diizinkan.' };
  }

  return { status: 200, user };
}

async function handleListUsers(res, supabaseUrl, serviceRoleKey) {
  const allUsers = [];

  for (let page = 1; page <= MAX_LIST_PAGES; page++) {
    const upstream = await fetchWithTimeout(
      `${supabaseUrl}/auth/v1/admin/users?page=${page}&per_page=${USERS_PER_PAGE}`,
      {
        method: 'GET',
        headers: {
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
        },
      }
    );

    const data = await upstream.json().catch(() => null);
    if (!upstream.ok) {
      const status = upstream.status >= 400 && upstream.status < 500 ? upstream.status : 502;
      return sendJson(res, status, {
        error: getUpstreamErrorMessage(data, 'Gagal mengambil daftar akun petugas dari Supabase.'),
      });
    }

    const batch = Array.isArray(data && data.users) ? data.users : (Array.isArray(data) ? data : []);
    for (const u of batch) {
      allUsers.push(toSafeUser(u));
    }
    if (batch.length < USERS_PER_PAGE) break;
  }

  allUsers.sort((a, b) => String(a.email).localeCompare(String(b.email)));
  return sendJson(res, 200, { users: allUsers });
}

async function fetchAdminUserById(supabaseUrl, serviceRoleKey, userId) {
  const res = await fetchWithTimeout(
    `${supabaseUrl}/auth/v1/admin/users/${encodeURIComponent(userId)}`,
    {
      method: 'GET',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
    }
  );
  const data = await res.json().catch(() => null);
  return { ok: res.ok, status: res.status, data };
}

async function updateUserAppRole(supabaseUrl, serviceRoleKey, userId, role) {
  const res = await fetchWithTimeout(
    `${supabaseUrl}/auth/v1/admin/users/${encodeURIComponent(userId)}`,
    {
      method: 'PUT',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ app_metadata: { role } }),
    }
  );
  const data = await res.json().catch(() => null);
  return { ok: res.ok, status: res.status, data };
}

async function deleteAdminUserById(supabaseUrl, serviceRoleKey, userId) {
  return fetchWithTimeout(
    `${supabaseUrl}/auth/v1/admin/users/${encodeURIComponent(userId)}`,
    {
      method: 'DELETE',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
      },
    }
  );
}

async function dispatchInviteEmail(supabaseUrl, serviceRoleKey, email, redirectTo) {
  const endpoint = `${supabaseUrl}/auth/v1/invite${buildRedirectQuery(redirectTo)}`;
  const res = await fetchWithTimeout(endpoint, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ email }),
  });
  const data = await res.json().catch(() => null);
  return { ok: res.ok, status: res.status, data };
}

function mapAuthUpstreamError(data, upstreamStatus, fallbackMsg) {
  const raw = getUpstreamErrorMessage(data, fallbackMsg);
  if (/already.*registered|email_exists/i.test(raw)) {
    return 'Email sudah terdaftar. Gunakan tombol Kirim Ulang Undangan atau Reset Password pada daftar akun.';
  }
  if (/rate limit|too many requests|429/i.test(raw) || upstreamStatus === 429) {
    return 'Batas pengiriman email tercapai sementara. Tunggu beberapa menit lalu coba lagi.';
  }
  if (/email_address_not_authorized/i.test(raw)) {
    return 'Alamat email belum diizinkan oleh penyedia SMTP. Pastikan Custom SMTP domain terverifikasi sudah aktif.';
  }
  return raw;
}

async function handleCreateUser(req, res, supabaseUrl, serviceRoleKey, body) {
  const email = String(body && body.email ? body.email : '').trim().toLowerCase();
  const password = body && typeof body.password === 'string' ? body.password : '';
  const mode = String(body && body.mode ? body.mode : (password ? 'manual' : 'invite')).trim().toLowerCase();
  const role = String(body && body.role ? body.role : '').trim().toLowerCase();

  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return sendJson(res, 400, { error: 'Format email tidak valid.' });
  }
  if (!ALLOWED_ROLES.has(role)) {
    return sendJson(res, 400, { error: "Role tidak valid. Pilih 'admin', 'warehouse_admin', atau 'cashier'." });
  }
  if (!['invite', 'manual'].includes(mode)) {
    return sendJson(res, 400, { error: "Mode pembuatan akun harus 'invite' atau 'manual'." });
  }

  if (mode === 'manual') {
    if (password.length < 6) {
      return sendJson(res, 400, { error: 'Kata sandi minimal 6 karakter.' });
    }

    const upstream = await fetchWithTimeout(`${supabaseUrl}/auth/v1/admin/users`, {
      method: 'POST',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email,
        password,
        email_confirm: true,
        app_metadata: { role },
      }),
    });

    const data = await upstream.json().catch(() => null);
    if (!upstream.ok) {
      const status = upstream.status >= 400 && upstream.status < 500 ? upstream.status : 502;
      return sendJson(res, status, {
        error: mapAuthUpstreamError(data, upstream.status, 'Gagal membuat akun petugas baru.'),
      });
    }

    return sendJson(res, 201, { user: toSafeUser(data), mode: 'manual' });
  }

  if (isSyntheticLocalEmail(email)) {
    return sendJson(res, 400, {
      error: 'Domain .local tidak dapat menerima email aktivasi. Gunakan alamat email aktif atau pilih mode password manual.',
    });
  }

  const redirectTo = resolveSafeRedirectTo(req, body && body.redirect_to);
  const inviteResult = await dispatchInviteEmail(supabaseUrl, serviceRoleKey, email, redirectTo);
  if (!inviteResult.ok) {
    const status = inviteResult.status >= 400 && inviteResult.status < 500 ? inviteResult.status : 502;
    return sendJson(res, status, {
      error: mapAuthUpstreamError(inviteResult.data, inviteResult.status, 'Gagal mengirim email undangan aktivasi akun.'),
    });
  }

  const invitedUser = inviteResult.data && inviteResult.data.id ? inviteResult.data : null;
  if (!invitedUser || !invitedUser.id) {
    return sendJson(res, 502, { error: 'Respons undangan Supabase tidak menyertakan ID akun.' });
  }

  const roleResult = await updateUserAppRole(supabaseUrl, serviceRoleKey, invitedUser.id, role);
  if (!roleResult.ok) {
    // Rollback akun baru tanpa role agar tidak tertinggal akun tanpa hak operasional
    await deleteAdminUserById(supabaseUrl, serviceRoleKey, invitedUser.id).catch(() => {});
    const status = roleResult.status >= 400 && roleResult.status < 500 ? roleResult.status : 502;
    return sendJson(res, status, {
      error: mapAuthUpstreamError(roleResult.data, roleResult.status, 'Akun gagal dipasang role operasional. Silakan coba ulang.'),
    });
  }

  return sendJson(res, 201, {
    user: toSafeUser(roleResult.data || invitedUser),
    mode: 'invite',
    message: `Undangan aktivasi akun telah dikirim ke ${email}.`,
  });
}

async function handleResendInvite(req, res, supabaseUrl, serviceRoleKey, body) {
  const userId = String(body && body.user_id ? body.user_id : '').trim();
  if (!userId || !/^[a-zA-Z0-9_-]{1,64}$/.test(userId)) {
    return sendJson(res, 400, { error: 'Parameter user_id tidak valid atau wajib diisi.' });
  }

  const lookup = await fetchAdminUserById(supabaseUrl, serviceRoleKey, userId);
  if (!lookup.ok || !lookup.data || !lookup.data.email) {
    const status = lookup.status >= 400 && lookup.status < 500 ? lookup.status : 502;
    return sendJson(res, status, {
      error: mapAuthUpstreamError(lookup.data, lookup.status, 'Akun petugas tidak ditemukan.'),
    });
  }

  const safeUser = toSafeUser(lookup.data);
  if (safeUser.is_active) {
    return sendJson(res, 400, {
      error: `Akun ${safeUser.email} sudah aktif. Gunakan tombol Reset Password bila perlu mengatur ulang kata sandi.`,
    });
  }
  if (isSyntheticLocalEmail(safeUser.email)) {
    return sendJson(res, 400, {
      error: 'Domain .local tidak dapat menerima email aktivasi.',
    });
  }

  const redirectTo = resolveSafeRedirectTo(req, body && body.redirect_to);
  const inviteResult = await dispatchInviteEmail(supabaseUrl, serviceRoleKey, safeUser.email, redirectTo);
  if (!inviteResult.ok) {
    const status = inviteResult.status >= 400 && inviteResult.status < 500 ? inviteResult.status : 502;
    return sendJson(res, status, {
      error: mapAuthUpstreamError(inviteResult.data, inviteResult.status, 'Gagal mengirim ulang email undangan.'),
    });
  }

  return sendJson(res, 200, {
    success: true,
    user: toSafeUser(inviteResult.data || lookup.data),
    message: `Email undangan aktivasi telah dikirim ulang ke ${safeUser.email}.`,
  });
}

async function handleSendResetEmail(req, res, supabaseUrl, serviceRoleKey, body) {
  const userId = String(body && body.user_id ? body.user_id : '').trim();
  if (!userId || !/^[a-zA-Z0-9_-]{1,64}$/.test(userId)) {
    return sendJson(res, 400, { error: 'Parameter user_id tidak valid atau wajib diisi.' });
  }

  const lookup = await fetchAdminUserById(supabaseUrl, serviceRoleKey, userId);
  if (!lookup.ok || !lookup.data || !lookup.data.email) {
    const status = lookup.status >= 400 && lookup.status < 500 ? lookup.status : 502;
    return sendJson(res, status, {
      error: mapAuthUpstreamError(lookup.data, lookup.status, 'Akun petugas tidak ditemukan.'),
    });
  }

  const safeUser = toSafeUser(lookup.data);
  if (!safeUser.is_active) {
    return sendJson(res, 400, {
      error: `Akun ${safeUser.email} belum diaktifkan. Gunakan tombol Kirim Ulang Undangan terlebih dahulu.`,
    });
  }
  if (isSyntheticLocalEmail(safeUser.email)) {
    return sendJson(res, 400, {
      error: `Akun ${safeUser.email} memakai domain .local dan tidak bisa menerima email reset password.`,
    });
  }

  const redirectTo = resolveSafeRedirectTo(req, body && body.redirect_to);
  const upstream = await fetchWithTimeout(`${supabaseUrl}/auth/v1/recover${buildRedirectQuery(redirectTo)}`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ email: safeUser.email }),
  });

  const data = await upstream.json().catch(() => null);
  if (!upstream.ok) {
    const status = upstream.status >= 400 && upstream.status < 500 ? upstream.status : 502;
    return sendJson(res, status, {
      error: mapAuthUpstreamError(data, upstream.status, 'Gagal mengirim email reset kata sandi.'),
    });
  }

  return sendJson(res, 200, {
    success: true,
    email: safeUser.email,
    message: `Email instruksi reset kata sandi telah dikirim ke ${safeUser.email}.`,
  });
}

async function handlePostRequest(req, res, supabaseUrl, serviceRoleKey) {
  let body;
  try {
    body = await parseJsonBody(req);
  } catch (err) {
    return sendJson(res, 400, { error: 'Payload JSON tidak valid.' });
  }

  const action = String(body && body.action ? body.action : 'create').trim().toLowerCase();
  if (action === 'resend_invite') {
    return handleResendInvite(req, res, supabaseUrl, serviceRoleKey, body);
  }
  if (action === 'send_reset') {
    return handleSendResetEmail(req, res, supabaseUrl, serviceRoleKey, body);
  }
  if (action === 'create') {
    return handleCreateUser(req, res, supabaseUrl, serviceRoleKey, body);
  }
  return sendJson(res, 400, { error: `Aksi '${action}' tidak dikenali.` });
}

async function handleDeleteUser(req, res, supabaseUrl, serviceRoleKey, callerUser) {
  let body = {};
  try {
    body = await parseJsonBody(req);
  } catch (err) {
    return sendJson(res, 400, { error: 'Payload JSON tidak valid.' });
  }

  let queryUserId = '';
  if (req.query && req.query.user_id) {
    queryUserId = String(req.query.user_id);
  } else if (req.url && req.url.includes('?')) {
    try {
      const parsed = new URL(req.url, 'http://localhost');
      queryUserId = parsed.searchParams.get('user_id') || '';
    } catch (e) {}
  }

  const userId = String((body && body.user_id) || queryUserId || '').trim();
  if (!userId || !/^[a-zA-Z0-9_-]{1,64}$/.test(userId)) {
    return sendJson(res, 400, { error: 'Parameter user_id tidak valid atau wajib diisi.' });
  }

  if (userId === String(callerUser.id)) {
    return sendJson(res, 400, { error: 'Dilarang menghapus akun admin yang sedang Anda gunakan.' });
  }

  const upstream = await deleteAdminUserById(supabaseUrl, serviceRoleKey, userId);

  const data = await upstream.json().catch(() => null);
  if (!upstream.ok) {
    const status = upstream.status >= 400 && upstream.status < 500 ? upstream.status : 502;
    return sendJson(res, status, {
      error: getUpstreamErrorMessage(data, 'Gagal menghapus akun petugas.'),
    });
  }

  return sendJson(res, 200, { success: true, deleted_user_id: userId });
}

module.exports = async function handler(req, res) {
  try {
    const method = String(req && req.method ? req.method : '').toUpperCase();
    if (!['GET', 'POST', 'DELETE'].includes(method)) {
      res.setHeader('Allow', 'GET, POST, DELETE');
      return sendJson(res, 405, { error: `Method ${method || 'UNKNOWN'} tidak diizinkan.` });
    }

    const supabaseUrl = String(process.env.SUPABASE_URL || '').trim().replace(/\/+$/, '');
    const serviceRoleKey = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
    if (!supabaseUrl || !serviceRoleKey) {
      return sendJson(res, 500, { error: 'Konfigurasi server Supabase belum lengkap.' });
    }

    const callerToken = extractBearerToken(req);
    if (!callerToken) {
      return sendJson(res, 401, { error: 'Unauthorized: Header Authorization Bearer wajib disertakan.' });
    }

    const authCheck = await verifyCallerAdmin(supabaseUrl, serviceRoleKey, callerToken);
    if (authCheck.status !== 200) {
      return sendJson(res, authCheck.status, { error: authCheck.error });
    }

    if (method === 'GET') {
      return await handleListUsers(res, supabaseUrl, serviceRoleKey);
    }
    if (method === 'POST') {
      return await handlePostRequest(req, res, supabaseUrl, serviceRoleKey);
    }
    return await handleDeleteUser(req, res, supabaseUrl, serviceRoleKey, authCheck.user);
  } catch (err) {
    const isTimeout = err && err.name === 'AbortError';
    return sendJson(res, isTimeout ? 504 : 500, {
      error: isTimeout
        ? 'Koneksi ke Supabase Admin API timeout. Coba lagi.'
        : 'Terjadi kesalahan internal server saat memproses akun petugas.',
    });
  }
};
