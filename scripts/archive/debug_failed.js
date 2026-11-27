const fs = require('fs');
const html = fs.readFileSync('c:/Users/Rifan Fakhrur Rozi/.gemini/antigravity/scratch/DesignTools/cekkuota-kk/dispatch-console.html', 'utf8');

console.log('--- POIN 13 DETAILS ---');
const plainMatch = html.match(/const\s+WAREHOUSE_PIN\s*=\s*['"](\d+)['"]/);
const hasShaFn = html.includes('hashPinSHA256') && html.includes('verifyPinAgainstStored');
const hasMaskedInput = html.includes('input-settings-current-pin');
console.log('plainMatch:', plainMatch ? plainMatch[0] : null);
console.log('hasShaFn:', hasShaFn);
console.log('hasMaskedInput:', hasMaskedInput);

console.log('\n--- POIN 36 DETAILS ---');
const hasUpdateCloud = html.includes('updateCloudStatusUI');
const hasBadgeCloud = html.includes('badge-cloud-status');
console.log('hasUpdateCloud:', hasUpdateCloud);
console.log('hasBadgeCloud:', hasBadgeCloud);

console.log('\n--- POIN 42 DETAILS ---');
const hasFixedPos = html.includes('position: fixed');
const hasCalcActionMenu = html.includes('calcActionMenuPosition');
const hasZ70 = html.includes('z-[70]');
console.log('hasFixedPos:', hasFixedPos);
console.log('hasCalcActionMenu:', hasCalcActionMenu);
console.log('hasZ70:', hasZ70);

console.log('\n--- POIN 48 DETAILS ---');
const hasFileProtocolCheck = html.includes("window.location.protocol === 'file:'");
const hasManualBtn1 = html.includes('fallback-manual-btn');
const hasManualBtn2 = html.includes('Buka Form Input KK Manual');
console.log('hasFileProtocolCheck:', hasFileProtocolCheck);
console.log('hasManualBtn1:', hasManualBtn1);
console.log('hasManualBtn2:', hasManualBtn2);
