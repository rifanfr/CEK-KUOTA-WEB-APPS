# BRIEF REBUILD — CATAT KUOTA KK (jangan baca audit-52-poin lengkap)

Dokumen ini adalah ringkasan kerja. Untuk konteks forensik lengkap, buka
`audit-52-poin-kebohongan.md` HANYA jika brief ini kurang. Brief ini cukup untuk
mulai eksekusi.

## 1. File target

| Peran | Path | Ukuran | Baris |
|---|---|---|---|
| MASTER | `C:\Users\Rifan Fakhrur Rozi\Downloads\catat_kuota_kk (5).html` | 527.928 B | 10.736 |
| Salinan kerja | `cekkuota-kk\dispatch-console.html` | 527.928 B | 10.736 |
| Salinan kerja | `cekkuota-kk\terminal-hub.html` | 527.928 B | 10.736 |

`dispatch-console.html` dan `terminal-hub.html` **byte-identik** dengan master
(diff kosong). PILIH SATU saja sebagai input. Jangan buka ketiganya.

File pendukung:

- `cekkuota-kk\vercel.json` (24 baris)
- `cekkuota-kk\index.html` (10.400 B)
- `cekkuota-kk\kuota.html` (22.947 B)

---

## 2. Aturan kerja wajib (untuk mencegah regresi lama)

1. `git init` + `git add -A` + commit baseline DULU. Tanpa ini jangan sentuh apa pun.
2. JANGAN pakai regex DOTALL / `.*?</div>` untuk menyunting HTML. Pakai edit
   berbasis anchor unik.
3. Setelah tiap perubahan: `git diff --stat` wajib masuk akal. Kalau tiba-tiba
   "-1400 baris", itu regresi — rollback.
4. Jangan timpa file di folder `Downloads`. Output ke folder baru / salinan kerja.
5. Jangan klaim "100% aman / beres" tanpa bukti nyata (screenshot, diff, test).

---

## 3. P0 — Security & integritas data

| # | Poin audit | Lokasi | Tindakan |
|---|---|---|---|
| P0-1 | 13 | L3722, L3792, L6376, L8036 | PIN `'1234'` hardcoded. Pindahkan ke Supabase Auth / hash. Hapus fallback `'1234'`. |
| P0-2 | 50 | `saveQuotaRecord()` L5575 | Tidak cek `getWarehouseStockSummary()` (L4299). Tambah guard stok sebelum commit. |
| P0-3 | 47 | `createDemoData()` L4072 | Jangan auto-seed kalau localStorage sudah berisi data nyata. |
| P0-4 | 17 | `loadState()` L~3810 | Tanpa `schema_version`. Tambah migrasi versi. |
| P0-5 | 9 / 41 | L~3800 | Supabase anon key plaintext. Pindahkan ke env var Vercel. |

---

## 4. P1 — Bug logika

| # | Poin audit | Lokasi | Tindakan |
|---|---|---|---|
| P1-1 | 38 / 23 | `addDaysISO`, kuota 30-hari bergulir | UI bilang "bulan berjalan", kode hitung 30 hari bergulir. Pakai kalender bulan + fix timezone WIB. |
| P1-2 | 34 | `vercel.json` L17–22 | `/kasir` → `/` (salah). Arahkan ke `dispatch-console.html`. |
| P1-3 | 40 | `@media print` L222 | Hanya tampilkan QR; struk & surat jalan kosong. Perlu print mode terpisah. |
| P1-4 | 43 | badge input L5942–5958, L6492–6508 | Input 5–15 digit tidak tertangani (undefined). |
| P1-5 | 8 / 22 / 35 | L474–489 | Duplikat `@keyframes shake`, dead code, variabel usang. |

---

## 5. P2 — Arsitektur & offline

| # | Poin audit | Lokasi | Tindakan |
|---|---|---|---|
| P2-1 | 10 / 25 / 31 | seluruh file | Pecah 10.736 baris → `core/state.js`, `core/quota.js`, `modules/warehouse.js`, `modules/customers.js`, `modules/export.js`, `ui/kiosk.js`, `ui/console.js`. |
| P2-2 | 41 | L14, L29–31 | CDN (Tailwind, Lucide, qrcodejs, html5-qrcode) → `vendor/` lokal. |
| P2-3 | 51 | export CSV L~7513 | Delimiter `;`, prefix nomor KK `'`, BOM untuk Excel Indonesia. |
| P2-4 | 42 | dropdown tabel L6090, L6448 | `position: fixed` + click-outside-to-close. |
| P2-5 | 52 / 15 | L1619–1674, L2327–2526 | Responsif mobile + modal edit scroll. |
| P2-6 | 48 | L31, L8800 | Scan kamera butuh HTTPS. Dokumentasi + fallback input manual. |

---

## 6. Status verifikasi langsung (sudah dicek — jangan ulang)

| Poin | Hasil |
|---|---|
| 3 | SUDAH BENAR. `<h1 id="header-app-title">CATAT KUOTA KK</h1>` (L520–521) terlihat, `#header-inner` tanpa class `hidden`. |
| 12 / 31 | KETIGA FILE MASIH IDENTIK. `diff` kosong, ukuran sama 527.928 B. |
| 45 | ADA guard fetch Supabase di `saveQuotaRecord` L5664–5689 — hanya aktif jika URL + key diisi. |
| 9 | Badge cloud L534–546 memanggil `syncWithSupabase`, bukan OneDrive. Komentar & badge menyesatkan. |
| 50 | TERBUKTI tidak ada cek stok di `saveQuotaRecord`. `berasDeficit` hanya flag, bukan blocker. |
| 34 | TERBUKTI `/kasir` → `/`. |
| 40 | TERBUKTI `@media print` hanya menampilkan QR. |
| 13 | TERBUKTI PIN `'1234'` di 4 lokasi. Ada `pinLockoutUntil` (L3716) = rate limit lokal saja. |

---

## 7. Larangan

Jangan sentuh poin perilaku AI berikut — tidak ada artefak kode untuk diperbaiki:

> 1, 2, 4, 5, 6, 7, 11, 18, 19, 20, 24, 26, 27, 28, 29, 30, 37

Poin-poin itu adalah rekam jejak historis, bukan bug di file. Yang bisa dilakukan
hanya: jangan ulangi polanya.

---

## 8. Urutan eksekusi yang disarankan

1. `git init` + commit baseline.
2. P0 seluruhnya dalam satu branch `fix/p0-security`.
3. Verifikasi: `git diff --stat`, cek manual 5 titik.
4. P1 dalam branch `fix/p1-logic`.
5. P2 bertahap per modul, satu commit per modul.
