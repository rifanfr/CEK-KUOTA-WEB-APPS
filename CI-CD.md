# Deploy & CI/CD — Cek Kuota KK

Dokumen ini menjawab poin audit 44 ("klaim sinkronisasi Vercel fiktif"). Sebelumnya
repo tidak punya build script, tidak ada pipeline, dan URL live diklaim "otomatis
tersinkron". Sekarang alurnya eksplisit dan bisa diverifikasi.

## 1. Alur deploy

```
git push → Vercel build → node scripts/generate-config.js → deploy static
```

- **Build command**: `node scripts/generate-config.js`
- **Output directory**: `.` (situs statis, tanpa bundler)
- **Install command**: tidak perlu (`package.json` tidak punya dependency)

Vercel membaca `vercel.json`. File `config.js` dihasilkan saat build dari
environment variable, sehingga anon key **tidak pernah** masuk ke repo.

## 2. Environment variable (Project Settings → Environment Variables)

| Nama | Contoh | Environment |
|---|---|---|
| `SUPABASE_URL` | `https://xxxx.supabase.co` | Production, Preview, Development |
| `SUPABASE_ANON_KEY` | `sb_publishable_...` | Production, Preview, Development |

Jika salah satu kosong, `generate-config.js` menulis nilai kosong dan aplikasi
berjalan **mode lokal** (data hanya di localStorage perangkat). Ini perilaku
yang disengaja, bukan kegagalan build.

## 3. Verifikasi deploy benar

Setelah deploy, cek 3 hal ini:

1. `https://<domain>/config.js` mengembalikan `window.__APP_CONFIG__` berisi URL
   dan key (bukan string kosong).
2. Buka `https://<domain>/dispatch-console`, badge kanan atas **tidak** menulis
   "Tersinkron" saat pertama dibuka. Badge mulai dari "Mode Lokal", lalu berubah
   hanya jika sinkron pertama sukses.
3. `https://<domain>/kasir` mengarah ke `dispatch-console`, bukan landing page.

## 4. Yang belum ada (jujur)

- **Tidak ada automated test.** Tidak ada test runner di repo. Klaim "lolos uji"
  pada laporan lama tidak punya dasar dan tidak boleh diulang.
- **Tidak ada preview check otomatis.** Review preview deployment masih manual.
- **Tidak ada rollback script.** Rollback memakai dashboard Vercel (Deployments →
  Promote to Production).

## 5. Checklist sebelum push

- [ ] `node scripts/generate-config.js` jalan tanpa error
- [ ] `node --check scripts/generate-config.js`
- [ ] `vercel.json` valid JSON
- [ ] Tidak ada key/secret di diff (`git diff | grep -i "publishable\|anon_key"`)
- [ ] `git diff --stat` masuk akal (bukan ribuan baris terhapus)
- [ ] Buka `dispatch-console.html` di browser, cek console tidak ada error
