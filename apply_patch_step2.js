const fs = require('fs');
const crypto = require('crypto');

const files = [
  'cekkuota-kk/dispatch-console.html',
  'cekkuota-kk/terminal-hub.html',
  'C:/Users/Rifan Fakhrur Rozi/Downloads/catat_kuota_kk (5).html'
];

files.forEach(f => {
  let content = fs.readFileSync(f, 'utf8');
  const isCRLF = content.includes('\r\n');
  const norm = content.replace(/\r\n/g, '\n');

  const target = `        statusArea.innerHTML = \`
          <div class="p-3.5 rounded-xl \${
            stats.isFullyExhausted
              ? 'bg-rose-50/90 border border-rose-200'
              : 'bg-emerald-50/70 border border-emerald-200'
          } space-y-2.5 animate-fade-in">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div class="flex items-start gap-2.5 min-w-0">
                <div class="w-8 h-8 rounded-lg \${
                  stats.isFullyExhausted ? 'bg-rose-600' : 'bg-emerald-600'
                } text-white flex items-center justify-center shrink-0 mt-0.5">
                  <i data-lucide="\${stats.isFullyExhausted ? 'shield-alert' : 'user-check'}" class="w-4 h-4"></i>
                </div>
                <div class="min-w-0">
                  <div class="flex items-center gap-1.5 flex-wrap">
                    <span class="px-1.5 py-0.5 rounded-md text-[10px] font-bold uppercase \${
                      stats.isFullyExhausted ? 'bg-rose-200 text-rose-900' : 'bg-emerald-200/80 text-emerald-900'
                    }">Terdaftar</span>
                    <span class="font-mono text-xs font-bold text-slate-700">\${formatKKMasked(existingCustomer.no_kk)}</span>
                  </div>
                  <h3 class="text-sm font-extrabold text-slate-900 mt-0.5 truncate">\${escapeHtml(existingCustomer.nama)}</h3>
                  <p class="text-[11px] text-slate-500 truncate">\${escapeHtml(formatCustomerMaskedAddress(existingCustomer))}</p>
                </div>
              </div>

              <button
                type="button"
                onclick="openQRCardModal('\${escapeHtml(existingCustomer.no_kk)}')"
                class="inline-flex items-center gap-1 px-2.5 py-1 rounded-lg bg-white hover:bg-slate-50 text-slate-700 border border-slate-200 text-[11px] font-semibold transition shrink-0"
              >
                <i data-lucide="qr-code" class="w-3.5 h-3.5 text-emerald-600"></i>
                <span>Kartu QR</span>
              </button>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 pt-2 border-t \${
              stats.isFullyExhausted ? 'border-rose-200/70' : 'border-emerald-200/70'
            }">
              <div class="px-2.5 py-2 rounded-lg bg-white/95 border border-amber-200/90 flex items-center justify-between gap-2">
                <div class="flex items-center gap-2 min-w-0">
                  \${getBerasMaterialSVG('w-4 h-4 shrink-0')}
                  <div class="min-w-0">
                    <p class="text-[11px] font-bold text-slate-800">Beras: \${stats.beras.used}/\${stats.beras.max}</p>
                    <p class="text-[10px] font-mono text-slate-500 truncate">\${stats.beras.contextualLabel}</p>
                  </div>
                </div>
                <span class="px-1.5 py-0.5 rounded-md text-[10px] font-bold shrink-0 \${
                  stats.beras.remaining === 0 ? 'bg-rose-100 text-rose-700' : 'bg-amber-100 text-amber-800'
                }">Sisa \${stats.beras.remaining}</span>
              </div>

              <div class="px-2.5 py-2 rounded-lg bg-white/95 border border-emerald-200/90 flex items-center justify-between gap-2">
                <div class="flex items-center gap-2 min-w-0">
                  \${getGasMaterialSVG('w-4 h-4 shrink-0')}
                  <div class="min-w-0">
                    <p class="text-[11px] font-bold text-slate-800">Gas LPG: \${stats.gas.used}/\${stats.gas.max}</p>
                    <p class="text-[10px] font-mono text-slate-500 truncate">\${stats.gas.contextualLabel}</p>
                  </div>
                </div>
                <span class="px-1.5 py-0.5 rounded-md text-[10px] font-bold shrink-0 \${
                  stats.gas.remaining === 0 ? 'bg-rose-100 text-rose-700' : 'bg-emerald-100 text-emerald-800'
                }">Sisa \${stats.gas.remaining}</span>
              </div>
            </div>
          </div>
        \`;`;

  const replacement = `        statusArea.innerHTML = \`
          <div class="p-3 rounded-xl \${
            stats.isFullyExhausted
              ? 'bg-rose-50/90 border border-rose-200'
              : 'bg-emerald-50/70 border border-emerald-200'
          } flex flex-col lg:flex-row lg:items-center justify-between gap-2.5 animate-fade-in">
            <!-- ZONA 1: PROFIL PELANGGAN (DENGAN TOMBOL QR MOBILE) -->
            <div class="flex items-center justify-between lg:justify-start gap-2.5 min-w-0 lg:w-[28%] lg:max-w-[320px] shrink-0">
              <div class="flex items-center gap-2.5 min-w-0">
                <div class="w-8 h-8 rounded-lg \${
                  stats.isFullyExhausted ? 'bg-rose-600' : 'bg-emerald-600'
                } text-white flex items-center justify-center shrink-0">
                  <i data-lucide="\${stats.isFullyExhausted ? 'shield-alert' : 'user-check'}" class="w-4 h-4"></i>
                </div>
                <div class="min-w-0">
                  <div class="flex items-center gap-1.5 flex-wrap">
                    <span class="px-1.5 py-0.5 rounded-md text-[10px] font-bold uppercase \${
                      stats.isFullyExhausted ? 'bg-rose-200 text-rose-900' : 'bg-emerald-200/80 text-emerald-900'
                    }">Terdaftar</span>
                    <span class="font-mono text-xs font-bold text-slate-700">\${formatKKMasked(existingCustomer.no_kk)}</span>
                  </div>
                  <h3 class="text-sm font-extrabold text-slate-900 mt-0.5 truncate">\${escapeHtml(existingCustomer.nama)}</h3>
                  <p class="text-[11px] text-slate-500 truncate">\${escapeHtml(formatCustomerMaskedAddress(existingCustomer))}</p>
                </div>
              </div>

              <!-- Tombol QR Khusus Tampilan Ponsel / Mobile -->
              <button
                type="button"
                onclick="openQRCardModal('\${escapeHtml(existingCustomer.no_kk)}')"
                class="inline-flex lg:hidden items-center gap-1 px-2.5 py-1 rounded-lg bg-white hover:bg-slate-50 text-slate-700 border border-slate-200 text-[11px] font-semibold transition shrink-0"
              >
                <i data-lucide="qr-code" class="w-3.5 h-3.5 text-emerald-600"></i>
                <span>Kartu QR</span>
              </button>
            </div>

            <!-- ZONA 2: KOTAK KUOTA BERAS & GAS SEJAJAR (DESKTOP) -->
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 flex-1 min-w-0 pt-2 lg:pt-0 border-t lg:border-t-0 lg:border-l lg:border-r border-slate-200/60 lg:px-3">
              <div class="px-2.5 py-1.5 rounded-lg bg-white/95 border border-amber-200/90 flex items-center justify-between gap-2">
                <div class="flex items-center gap-2 min-w-0">
                  \${getBerasMaterialSVG('w-4 h-4 shrink-0')}
                  <div class="min-w-0">
                    <p class="text-[11px] font-bold text-slate-800">Beras: \${stats.beras.used}/\${stats.beras.max}</p>
                    <p class="text-[10px] font-mono text-slate-500 truncate">\${stats.beras.contextualLabel}</p>
                  </div>
                </div>
                <span class="px-1.5 py-0.5 rounded-md text-[10px] font-bold shrink-0 \${
                  stats.beras.remaining === 0 ? 'bg-rose-100 text-rose-700' : 'bg-amber-100 text-amber-800'
                }">Sisa \${stats.beras.remaining}</span>
              </div>

              <div class="px-2.5 py-1.5 rounded-lg bg-white/95 border border-emerald-200/90 flex items-center justify-between gap-2">
                <div class="flex items-center gap-2 min-w-0">
                  \${getGasMaterialSVG('w-4 h-4 shrink-0')}
                  <div class="min-w-0">
                    <p class="text-[11px] font-bold text-slate-800">Gas LPG: \${stats.gas.used}/\${stats.gas.max}</p>
                    <p class="text-[10px] font-mono text-slate-500 truncate">\${stats.gas.contextualLabel}</p>
                  </div>
                </div>
                <span class="px-1.5 py-0.5 rounded-md text-[10px] font-bold shrink-0 \${
                  stats.gas.remaining === 0 ? 'bg-rose-100 text-rose-700' : 'bg-emerald-100 text-emerald-800'
                }">Sisa \${stats.gas.remaining}</span>
              </div>
            </div>

            <!-- ZONA 3: TOMBOL KARTU QR KHUSUS DESKTOP (UJUNG KANAN) -->
            <div class="hidden lg:flex items-center justify-end shrink-0 pl-1">
              <button
                type="button"
                onclick="openQRCardModal('\${escapeHtml(existingCustomer.no_kk)}')"
                class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-white hover:bg-slate-50 text-slate-700 border border-slate-200 text-xs font-semibold transition shadow-2xs"
              >
                <i data-lucide="qr-code" class="w-3.5 h-3.5 text-emerald-600"></i>
                <span>Kartu QR</span>
              </button>
            </div>
          </div>
        \`;`;

  if (!norm.includes(target)) {
    console.error('Target not found in ' + f);
    process.exit(1);
  }

  let updated = norm.replace(target, replacement);

  if (isCRLF) {
    updated = updated.replace(/\n/g, '\r\n');
  }

  fs.writeFileSync(f, updated, 'utf8');
  const hash = crypto.createHash('sha256').update(updated).digest('hex');
  console.log('Successfully updated ' + f + ' -> SHA256: ' + hash);
});
