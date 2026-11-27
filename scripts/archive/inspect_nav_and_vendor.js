const fs = require('fs');
const html = fs.readFileSync('c:/Users/Rifan Fakhrur Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html', 'utf8');
const lines = html.split('\n');

console.log('=== CSS STYLES FOR SHAKE & MOBILE ===');
lines.forEach((l, idx) => {
  if (l.includes('shake') || l.includes('@keyframes') || l.includes('mobile-bottom-nav')) {
    if (idx < 500) console.log((idx+1) + ': ' + l.trim());
  }
});

console.log('=== MOBILE BOTTOM NAV ELEMENT ===');
lines.forEach((l, idx) => {
  if (l.includes('id="mobile-bottom-nav"') || l.includes("id='mobile-bottom-nav'")) {
    console.log((idx+1) + ': ' + l.trim());
    console.log(lines.slice(idx, idx + 35).join('\n'));
  }
});

console.log('=== VENDOR DIRECTORY ASSETS CHECK ===');
const vendorDir = 'c:/Users/Rifan Fakhrur Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/vendor';
if (fs.existsSync(vendorDir)) {
  fs.readdirSync(vendorDir).forEach(f => {
    const stat = fs.statSync(vendorDir + '/' + f);
    console.log(`- ${f}: ${(stat.size / 1024).toFixed(1)} KB`);
  });
} else {
  console.log('vendor dir missing!');
}
