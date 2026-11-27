const fs = require('fs');
const html = fs.readFileSync('c:/Users/Rifan Fakhrur Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html', 'utf8');
const lines = html.split('\n');

console.log('=== DEFINITION OF updateCloudStatusUI ===');
lines.forEach((l, idx) => {
  if (l.includes('function updateCloudStatusUI')) {
    console.log(lines.slice(idx, idx + 45).join('\n'));
  }
});

console.log('\n=== DEFINITION OF showCameraFallback ===');
lines.forEach((l, idx) => {
  if (l.includes('const showCameraFallback =') || l.includes('function showCameraFallback')) {
    console.log(lines.slice(idx, idx + 35).join('\n'));
  }
});
