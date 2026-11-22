const fs = require('fs');
const crypto = require('crypto');
const path = require('path');

const files = [
  path.resolve(__dirname, 'dispatch-console.html'),
  path.resolve(__dirname, 'terminal-hub.html'),
  'C:/Users/Rifan Fakhrur Rozi/Downloads/catat_kuota_kk (5).html'
];

files.forEach(f => {
  let content = fs.readFileSync(f, 'utf8');
  const isCRLF = content.includes('\r\n');
  const norm = content.replace(/\r\n/g, '\n');

  // 1. Header card replacement
  const targetHeader = `          <div id="warehouse-header-card" class="bg-white rounded-2xl border border-slate-200 shadow-2xs p-4 sm:p-5 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
            <div class="flex items-center gap-2 min-w-0">
              <h2 class="text-base sm:text-lg font-bold text-slate-900 truncate">Stok Gudang</h2>
              <span class="px-2 py-0.5 rounded-full text-[10px] font-bold bg-emerald-50 text-emerald-700 border border-emerald-200 shrink-0 whitespace-nowrap">
                Admin Aktif
              </span>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <button
                type="button"
                onclick="exportWarehouseCSV()"
                class="flex-1 sm:flex-none inline-flex items-center justify-center gap-1.5 px-3 py-2 rounded-xl bg-slate-900 hover:bg-slate-800 text-white font-semibold text-xs transition whitespace-nowrap"
              >
                <i data-lucide="download" class="w-3.5 h-3.5 text-emerald-400"></i>
                <span>Export Data</span>
              </button>
              <button
                type="button"
                onclick="lockWarehouseAdmin()"
                class="flex-1 sm:flex-none inline-flex items-center justify-center gap-1.5 px-3 py-2 rounded-xl bg-slate-100 hover:bg-slate-200 text-slate-700 border border-slate-300 font-semibold text-xs transition whitespace-nowrap"
              >
                <i data-lucide="lock" class="w-3.5 h-3.5"></i>
                <span>Kunci PIN</span>
              </button>
            </div>
          </div>`;

  const replaceHeader = `          <div id="warehouse-header-card" class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 pt-1 pb-0.5">
            <div class="min-w-0">
              <h2 class="text-base sm:text-lg font-extrabold text-slate-900 tracking-tight">Stok Gudang</h2>
              <p class="text-xs text-slate-500">Saldo fisik real-time & pencatatan mutasi penerimaan/pengeluaran</p>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <span class="hidden sm:inline-flex items-center gap-1.5 px-2.5 py-1.5 rounded-xl bg-emerald-50 text-emerald-700 border border-emerald-200 text-xs font-bold">
                <i data-lucide="unlock" class="w-3.5 h-3.5 text-emerald-600"></i>
                <span>Sesi Terbuka</span>
              </span>
              <button
                type="button"
                onclick="exportWarehouseCSV()"
                class="inline-flex items-center justify-center gap-1.5 px-3.5 py-2 rounded-xl bg-slate-900 hover:bg-slate-800 text-white font-semibold text-xs transition shadow-2xs whitespace-nowrap"
              >
                <i data-lucide="download" class="w-3.5 h-3.5 text-emerald-400"></i>
                <span>Export Data</span>
              </button>
              <button
                type="button"
                onclick="lockWarehouseAdmin()"
                class="inline-flex items-center justify-center gap-1.5 px-3 py-2 rounded-xl bg-white hover:bg-slate-50 text-slate-700 border border-slate-200/90 font-semibold text-xs transition shadow-2xs whitespace-nowrap"
              >
                <i data-lucide="lock" class="w-3.5 h-3.5 text-slate-500"></i>
                <span>Kunci PIN</span>
              </button>
            </div>
          </div>`;

  // 2. Form Column 4: side-by-side preset select & text input
  const targetCol4 = `              <div class="space-y-1">
                <div class="flex items-center justify-between gap-1 mb-1">
                  <label for="wh-form-ref" class="block text-xs font-bold text-slate-700">No. DO / Keterangan</label>
                  <span class="text-[10px] font-semibold text-emerald-700 bg-emerald-50 px-1.5 py-0.5 rounded">Format Seragam</span>
                </div>
                <select
                  id="wh-ref-preset-select"
                  onchange="handleRefPresetChange(this.value)"
                  class="w-full px-2.5 py-1.5 bg-slate-100 hover:bg-slate-200/70 border border-slate-300 rounded-lg text-xs font-bold text-slate-800 focus:outline-none focus:ring-2 focus:ring-emerald-500 cursor-pointer transition mb-1"
                >
                  <option value="">-- Pilih Format Seragam / Otomatis --</option>
                  <option value="DO-PERTAMINA">DO (Otomatis) - PERTAMINA</option>
                  <option value="DO-BULOG">DO (Otomatis) - BULOG</option>
                  <option value="DO-AGEN">DO (Otomatis) - AGEN RESMI</option>
                  <option value="RECEIVE">RECEIVE - DROP STOK TAMBAHAN</option>
                  <option value="RETUR">RETUR - TABUNG BOCOR / BERAS RUSAK</option>
                  <option value="OPNAME">PENYESUAIAN - STOK OPNAME FISIK</option>
                  <option value="CUSTOM">Ketik Manual / Bebas</option>
                </select>
                <input
                  type="text"
                  id="wh-form-ref"
                  required
                  oninput="this.value = this.value.toUpperCase()"
                  placeholder="PILIH PRESET / KETIK MANUAL"
                  class="auto-uppercase w-full px-3 py-2 bg-slate-50 border border-slate-300 rounded-xl text-xs sm:text-sm font-bold text-slate-900 focus:bg-white focus:outline-none focus:ring-2 focus:ring-emerald-500"
                />
              </div>`;

  const replaceCol4 = `              <div class="space-y-1">
                <div class="flex items-center justify-between gap-1 mb-1">
                  <label for="wh-form-ref" class="block text-xs font-bold text-slate-700">No. DO / Keterangan</label>
                  <span class="text-[10px] font-semibold text-emerald-700 bg-emerald-50 px-1.5 py-0.5 rounded">Format Seragam</span>
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-1.5">
                  <select
                    id="wh-ref-preset-select"
                    onchange="handleRefPresetChange(this.value)"
                    class="w-full px-2.5 py-2 bg-slate-100 hover:bg-slate-200/70 border border-slate-300 rounded-xl text-xs font-bold text-slate-800 focus:outline-none focus:ring-2 focus:ring-emerald-500 cursor-pointer transition"
                  >
                    <option value="">Preset</option>
                    <option value="DO-PERTAMINA">DO Pertamina</option>
                    <option value="DO-BULOG">DO Bulog</option>
                    <option value="DO-AGEN">DO Agen</option>
                    <option value="RECEIVE">Receive Drop</option>
                    <option value="RETUR">Retur Rusak</option>
                    <option value="OPNAME">Opname Fisik</option>
                    <option value="CUSTOM">Ketik Manual</option>
                  </select>
                  <input
                    type="text"
                    id="wh-form-ref"
                    required
                    oninput="this.value = this.value.toUpperCase()"
                    placeholder="PILIH PRESET / KETIK MANUAL"
                    class="auto-uppercase w-full px-3 py-2 bg-slate-50 border border-slate-300 rounded-xl text-xs sm:text-sm font-bold text-slate-900 focus:bg-white focus:outline-none focus:ring-2 focus:ring-emerald-500"
                  />
                </div>
              </div>`;

  let updated = norm;
  if (norm.includes(targetHeader)) {
    updated = updated.replace(targetHeader, replaceHeader);
  }
  if (norm.includes(targetCol4)) {
    updated = updated.replace(targetCol4, replaceCol4);
  }

  content = isCRLF ? updated.replace(/\n/g, '\r\n') : updated;
  fs.writeFileSync(f, content, 'utf8');
  console.log(`Updated ${path.basename(f)}`);
});
