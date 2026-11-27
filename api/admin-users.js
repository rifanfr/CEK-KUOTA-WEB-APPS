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
  return {
    id: user && user.id ? String(user.id) : '',
    email: user && user.email ? String(user.email) : '',
    role: typeof appMeta.role === 'string' ? appMeta.role : null,
    created_at: user && user.created_at ? user.created_at : null,
    last_sign_in_at: user && user.last_sign_in_at ? user.last_sign_in_at : null,
  };
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

async function handleCreateUser(req, res, supabaseUrl, serviceRoleKey) {
  let body;
  try {
    body = await parseJsonBody(req);
  } catch (err) {
    return sendJson(res, 400, { error: 'Payload JSON tidak valid.' });
  }

  const email = String(body && body.email ? body.email : '').trim().toLowerCase();
  const password = body && typeof body.password === 'string' ? body.password : '';
  const role = String(body && body.role ? body.role : '').trim().toLowerCase();

  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return sendJson(res, 400, { error: 'Format email tidak valid.' });
  }
  if (password.length < 6) {
    return sendJson(res, 400, { error: 'Kata sandi minimal 6 karakter.' });
  }
  if (!ALLOWED_ROLES.has(role)) {
    return sendJson(res, 400, { error: "Role tidak valid. Pilih 'admin', 'warehouse_admin', atau 'cashier'." });
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
      error: getUpstreamErrorMessage(data, 'Gagal membuat akun petugas baru.'),
    });
  }

  return sendJson(res, 201, { user: toSafeUser(data) });
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

  const upstream = await fetchWithTimeout(
    `${supabaseUrl}/auth/v1/admin/users/${encodeURIComponent(userId)}`,
    {
      method: 'DELETE',
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
      return await handleCreateUser(req, res, supabaseUrl, serviceRoleKey);
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
