# AUDIT_PACKAGE.md

# PRE-RELEASE AUDIT PACKAGE

## Project Information

| Item | Value |
|--------|--------|
| Project Name | |
| Version | |
| Environment | Development / Staging |
| Database | PostgreSQL |
| Architecture | Web Application |
| Intended User | Single User |
| Audit Date | |
| Release Target | |

---

# SYSTEM OVERVIEW

## Purpose

Aplikasi digunakan untuk pencatatan pembelian kuota Beras dan LPG berdasarkan Nomor Kartu Keluarga (No KK).

## Main Features

- Registrasi Customer
- Master Data KK
- Pembelian Beras
- Pembelian LPG
- Validasi Kuota
- Pengurangan Stok
- Refund
- Pembatalan Transaksi
- Audit Log
- Export Excel
- Backup
- Restore

---

# AUDIT INSTRUCTION

Lakukan:

1. Architecture Review
2. Source Code Review
3. Database Review
4. Business Logic Review
5. Security Audit
6. Penetration Testing
7. Patch Generation
8. Patch Verification
9. Regression Testing
10. Release Readiness Review

---

# AUDIT HONESTY POLICY

Wajib mengikuti aturan berikut:

- Jangan membuat asumsi.
- Jangan membuat temuan tanpa bukti.
- Jangan menganggap patch berhasil tanpa pengujian.
- Jangan menyatakan PASS tanpa evidence.
- Jangan menyatakan aplikasi aman tanpa verifikasi.

Jika bukti tidak tersedia:

```text
INSUFFICIENT EVIDENCE
```

Jika tidak dapat direproduksi:

```text
NOT REPRODUCIBLE
```

Jika masih berupa dugaan:

```text
UNVERIFIED HYPOTHESIS
```

---

# BUSINESS RULES

## RULE-001

### No KK Harus 16 Digit

- Wajib numerik
- Tepat 16 digit
- Tidak boleh kosong

---

## RULE-002

### Maksimum Pembelian Per Transaksi

- Qty minimal = 1
- Qty maksimal = 5

---

## RULE-003

### Maksimum 1 Periode Pembelian 30 Hari

- Sistem harus memvalidasi periode 30 hari

---

## RULE-004

### Tidak Boleh Ada Transaksi Ganda

- Double click tidak boleh menghasilkan transaksi ganda
- Retry request tidak boleh membuat record baru

---

## RULE-005

### Stok Tidak Boleh Minus

- Pembelian ditolak jika stok tidak mencukupi

---

## RULE-006

### Audit Log Wajib Dibuat

Setiap:

- Insert
- Update
- Delete
- Refund
- Cancel

harus memiliki audit log.

---

## RULE-007

### Edit Histori Harus Terdeteksi

Perubahan histori wajib dicatat:

- Before Value
- After Value
- Timestamp

---

## RULE-008

### Backup dan Restore

- Backup berhasil
- Restore berhasil
- Data tetap konsisten

---

## RULE-009

### Satu KK Hanya Memiliki Satu Data Master Aktif

- Tidak boleh ada lebih dari satu customer aktif untuk No KK yang sama

---

## RULE-010

### No KK Tidak Boleh Ganda

Validasi harus ada di:

- UI
- API
- Database

---

## RULE-011

### Export Tidak Boleh Mengubah Data

Data sebelum export harus identik dengan data setelah export.

---

## RULE-012

### Restore Harus Identik Dengan Backup

Harus identik untuk:

- Customer
- Stok
- Transaksi
- Audit Log

---

## RULE-013

### Kuota Bersifat Akumulatif

Contoh:

3 pcs + 2 pcs = 5 pcs ✅

3 pcs + 3 pcs = 6 pcs ❌

Perhitungan dilakukan untuk periode 30 hari.

---

## RULE-014

### Refund Mengembalikan Kuota

Refund harus:

- Mengembalikan kuota
- Mengembalikan stok

Refund tidak boleh melebihi pembelian awal.

---

## RULE-015

### Pembatalan Transaksi Aman

Cancel harus:

- Mengembalikan stok
- Tidak mengurangi kuota
- Membuat audit log

---

## RULE-016

### Perlindungan Race Condition

Untuk No KK yang sama:

- Tidak boleh diproses paralel
- Tidak boleh terjadi kuota bocor

Disarankan:

```sql
pg_advisory_xact_lock()
```

---

## RULE-017

### Idempotency Protection

Request yang sama tidak boleh diproses dua kali.

Disarankan:

```sql
request_id UNIQUE
```

dan

```sql
refund_reference UNIQUE
```

---

# DATABASE DESIGN REQUIREMENTS

Wajib diverifikasi:

- UNIQUE NoKK
- CHECK Qty
- CHECK Stock
- Foreign Key
- Transaction Integrity
- Refund Integrity
- Idempotency
- Advisory Lock
- Row Locking

---

# SECURITY REVIEW

Verifikasi:

- XSS
- Stored XSS
- Reflected XSS
- CSRF
- SQL Injection
- CSV Injection
- Business Logic Bypass
- Parameter Tampering
- Local Storage Manipulation
- Browser Console Manipulation

---

# PATCH REQUIREMENTS

Setiap patch wajib:

1. Reproduce
2. Evidence
3. Root Cause
4. Patch
5. Retest
6. Bypass Test
7. Regression Test

Jika salah satu tidak ada:

```text
PATCH REJECTED
```

---

# OUTPUT FORMAT

Setiap temuan wajib memiliki:

- Finding ID
- Severity
- Evidence
- Root Cause
- Patch
- Verification Result
- Regression Result

---

# RELEASE DECISION

Pilihan:

- APPROVED FOR RELEASE
- APPROVED WITH CONDITIONS
- REJECTED FOR RELEASE
- INSUFFICIENT EVIDENCE

---

# SUCCESS CRITERIA

Aplikasi hanya boleh release jika:

✅ RULE-001 sampai RULE-017 PASS

✅ Critical Finding = 0

✅ High Finding = 0

✅ Semua patch terverifikasi

✅ Backup berhasil

✅ Restore berhasil

✅ Refund berhasil

✅ Cancel berhasil

✅ Race Condition Test berhasil

✅ Evidence Coverage ≥ 95%

✅ Business Rule Coverage = 100%