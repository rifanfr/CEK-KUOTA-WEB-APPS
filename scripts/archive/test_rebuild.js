const fs = require('fs');
const path = require('path');

const src = path.resolve(__dirname, 'recovered_live.html');
const testOut = path.resolve(__dirname, 'test_output.html');

fs.copyFileSync(src, testOut);
console.log('Copied recovered_live to test_output.html');
