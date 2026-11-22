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

  const target = `            <!-- ZONA 2: KOTAK KUOTA BERAS & GAS SEJAJAR (DESKTOP) -->
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
            </div>`;

  const replacement = `            <!-- ZONA 2: KOTAK KUOTA BERAS & GAS SEJAJAR (1 BARIS RINGKAS & TEPAT) -->
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 flex-1 min-w-0 pt-2 lg:pt-0 border-t lg:border-t-0 lg:border-l lg:border-r border-slate-200/60 lg:px-3">
              <div class="px-2.5 py-2 rounded-lg bg-white/95 border \${stats.beras.remaining === 0 ? 'border-rose-200 bg-rose-50/50' : 'border-amber-200/90'} flex items-center justify-between gap-2 min-h-[38px]">
                <div class="flex items-center gap-2 min-w-0">
                  \${getBerasMaterialSVG('w-4 h-4 shrink-0')}
                  <div class="flex items-center gap-1.5 min-w-0">
                    <span class="text-xs font-bold text-slate-800">Beras:</span>
                    \${
                      stats.beras.remaining > 0
                        ? \`<span class="text-xs font-bold text-amber-700">Tersedia \${stats.beras.remaining} Lagi</span>\`
                        : \`<span class="text-xs font-bold text-rose-700">0 (Habis)</span>\`
                    }
                  </div>
                </div>
                \${
                  stats.beras.remaining === 0 && stats.beras.nextCycleDate
                    ? \`<span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[10px] font-bold bg-rose-100 text-rose-800 border border-rose-200 shrink-0 whitespace-nowrap"><i data-lucide="calendar" class="w-2.5 h-2.5"></i> Beli lagi \${formatShortDateID(stats.beras.nextCycleDate)}</span>\`
                    : ''
                }
              </div>

              <div class="px-2.5 py-2 rounded-lg bg-white/95 border \${stats.gas.remaining === 0 ? 'border-rose-200 bg-rose-50/50' : 'border-emerald-200/90'} flex items-center justify-between gap-2 min-h-[38px]">
                <div class="flex items-center gap-2 min-w-0">
                  \${getGasMaterialSVG('w-4 h-4 shrink-0')}
                  <div class="flex items-center gap-1.5 min-w-0">
                    <span class="text-xs font-bold text-slate-800">Gas LPG:</span>
                    \${
                      stats.gas.remaining > 0
                        ? \`<span class="text-xs font-bold text-emerald-700">Tersedia \${stats.gas.remaining} Lagi</span>\`
                        : \`<span class="text-xs font-bold text-rose-700">0 (Habis)</span>\`
                    }
                  </div>
                </div>
                \${
                  stats.gas.remaining === 0 && stats.gas.nextCycleDate
                    ? \`<span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[10px] font-bold bg-rose-100 text-rose-800 border border-rose-200 shrink-0 whitespace-nowrap"><i data-lucide="calendar" class="w-2.5 h-2.5"></i> Beli lagi \${formatShortDateID(stats.gas.nextCycleDate)}</span>\`
                    : ''
                }
              </div>
            </div>`;

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
