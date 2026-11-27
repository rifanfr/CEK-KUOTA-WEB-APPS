const fs = require('fs');
const html = fs.readFileSync('c:/Users/Rifan Fakhrur Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html', 'utf8');
const lines = html.split('\n');

console.log('=== 1. SETTINGS PIN INPUT (search for adminPin or pin input) ===');
lines.forEach((l, idx) => {
  if (l.includes('set-admin-pin') || l.includes('admin-pin') || l.includes('settings-pin') || l.includes('current-pin') || l.includes('currentPin')) {
    console.log((idx+1) + ': ' + l.trim());
  }
});

console.log('\n=== 2. CLOUD STATUS / BADGE (search for updateCloudStatusUI) ===');
lines.forEach((l, idx) => {
  if (l.includes('updateCloudStatusUI')) {
    console.log((idx+1) + ': ' + l.trim());
    console.log(lines.slice(idx, idx + 25).join('\n'));
  }
});

console.log('\n=== 3. ACTION MENU DROPDOWN (search for z-[70] or action menu) ===');
lines.forEach((l, idx) => {
  if (l.includes('z-[70]')) {
    console.log((idx+1) + ': ' + l.trim());
    console.log(lines.slice(idx - 5, idx + 20).join('\n'));
  }
});

console.log('\n=== 4. SCAN CAMERA FILE PROTOCOL (search for window.location.protocol) ===');
lines.forEach((l, idx) => {
  if (l.includes("window.location.protocol === 'file:'") || l.includes('protocol === "file:"')) {
    console.log((idx+1) + ': ' + l.trim());
    console.log(lines.slice(idx - 5, idx + 25).join('\n'));
  }
});
