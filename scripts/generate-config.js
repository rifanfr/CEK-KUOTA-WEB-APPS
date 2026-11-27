/**
 * Generator konfigurasi runtime untuk deployment Vercel.
 *
 * Tujuan: jangan pernah menaruh Supabase anon key di HTML yang di-commit.
 * Script ini membaca environment variable build-time lalu menulis
 * `config.js` yang dimuat oleh halaman. Jalankan sebelum build:
 *
 *   node scripts/generate-config.js
 *
 * Environment variable yang dibaca:
 *   SUPABASE_URL       contoh: https://xxxx.supabase.co
 *   SUPABASE_ANON_KEY  publishable / anon key
 */

const fs = require('fs');
const path = require('path');

const url = process.env.SUPABASE_URL || '';
const anonKey = process.env.SUPABASE_ANON_KEY || '';
const outPath = path.join(__dirname, '..', 'config.js');

const content = `// GENERATED FILE - jangan diedit manual.
// Dibuat oleh scripts/generate-config.js dari environment variable.
window.__APP_CONFIG__ = window.__APP_CONFIG__ || ${JSON.stringify(
  { supabaseUrl: url, supabaseAnonKey: anonKey },
  null,
  2
)};
`;

fs.writeFileSync(outPath, content, 'utf8');

if (!url || !anonKey) {
  console.warn(
    '[generate-config] SUPABASE_URL / SUPABASE_ANON_KEY kosong. ' +
      'Aplikasi akan berjalan pada mode offline lokal.'
  );
} else {
  console.log('[generate-config] config.js berhasil dibuat.');
}
