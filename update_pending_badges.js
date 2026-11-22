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
  const lines = content.split(/\r?\n/);

  let modifiedTable = false;
  let modifiedMobile = false;

  for (let i = 0; i < lines.length; i++) {
    // 1. Table cell in Riwayat Pengambilan
    if (lines[i].includes('formatShortDateID(l.date)') && lines[i].includes('text-slate-400 font-normal') && !lines[i].includes('is_dirty')) {
      lines[i] = `                  <div class="flex items-center gap-1.5">
                    <span>\${formatShortDateID(l.date)} <span class="text-slate-400 font-normal">(\${l.time})</span></span>
                    \${
                      l.is_dirty
                        ? '<span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-sans font-bold bg-amber-100 text-amber-800 border border-amber-300" title="Tersimpan lokal di perangkat (Pending Sync)"><i data-lucide="cloud-off" class="w-2.5 h-2.5"></i> Pending Sync</span>'
                        : '<span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-sans font-medium bg-slate-100 text-slate-500" title="Tersinkron ke Supabase Cloud"><i data-lucide="cloud-check" class="w-2.5 h-2.5 text-emerald-600"></i> Cloud</span>'
                    }
                  </div>`;
      modifiedTable = true;
    }

    // 2. Mobile card in Riwayat Pengambilan
    if (lines[i].includes('formatShortDateID(l.date)') && lines[i].includes('font-mono text-[11px]') && !lines[i].includes('is_dirty')) {
      lines[i] = `                    <div class="flex items-center gap-1.5">
                      <p class="font-mono text-[11px] font-bold text-slate-600">\${formatShortDateID(l.date)} • \${l.time}</p>
                      \${
                        l.is_dirty
                          ? '<span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-sans font-bold bg-amber-100 text-amber-800 border border-amber-300" title="Pending Sync"><i data-lucide="cloud-off" class="w-2.5 h-2.5"></i> Pending</span>'
                          : '<span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-sans font-medium bg-slate-100 text-slate-500" title="Tersinkron"><i data-lucide="cloud-check" class="w-2.5 h-2.5 text-emerald-600"></i> Cloud</span>'
                      }
                    </div>`;
      modifiedMobile = true;
    }
  }

  if (!modifiedTable || !modifiedMobile) {
    console.error('Failed modification in ' + f + ' table: ' + modifiedTable + ', mobile: ' + modifiedMobile);
    process.exit(1);
  }

  const separator = isCRLF ? '\r\n' : '\n';
  let newContent = lines.join(separator);

  // 3. Post-sync refreshAllUI update
  const targetSync = 'const dirtyLogsToSend = state.logs.filter((l) => l.is_dirty);';
  if (newContent.includes(targetSync)) {
    newContent = newContent.replace(
      /const dirtyLogsToSend = state\.logs\.filter\(\(l\) => l\.is_dirty\);[\s\S]*?const dirtyWhToSend = state\.warehouseLogs\.filter\(\(w\) => w\.is_dirty\);[\s\S]*?for \(const w of dirtyWhToSend\) \{[\s\S]*?pushWarehouseMutationToSupabase\(w\)\.catch\(\(\) => \{\}\);[\s\S]*?\}/,
      `const dirtyLogsToSend = state.logs.filter((l) => l.is_dirty);
        if (dirtyLogsToSend.length > 0) {
          await Promise.allSettled(dirtyLogsToSend.map(async (l) => {
            const isExistingOnCloud = cloudLogIds.has(l.id);
            try {
              if (isExistingOnCloud) {
                await updateLogOnSupabase(l);
              } else {
                await pushSingleLogToSupabase(l);
              }
            } catch (err) {
              if (err && err.message && (err.message.includes('Pelanggaran Kuota') || err.message.includes('chk_') || err.message.includes('Server menolak'))) {
                state.logs = state.logs.filter((item) => item.id !== l.id);
                state.warehouseLogs = state.warehouseLogs.filter((w) => w.logId !== l.id);
                persistState();
              }
            }
          }));
          refreshAllUI();
        }

        const dirtyWhToSend = state.warehouseLogs.filter((w) => w.is_dirty);
        if (dirtyWhToSend.length > 0) {
          await Promise.allSettled(dirtyWhToSend.map((w) => pushWarehouseMutationToSupabase(w).catch(() => {})));
        }`
    );
  }

  fs.writeFileSync(f, newContent, 'utf8');
  const hash = crypto.createHash('sha256').update(newContent).digest('hex');
  console.log('Updated ' + f + ' -> SHA256: ' + hash);
});
