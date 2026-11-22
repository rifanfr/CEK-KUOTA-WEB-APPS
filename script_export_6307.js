const fs = require('fs');
const path = require('path');
const readline = require('readline');

async function findExport() {
  const fileStream = fs.createReadStream('C:/Users/Rifan Fakhrur Rozi/.gemini/antigravity/brain/7139f775-ac4b-4ee2-9afd-21ff9891a429/.system_generated/logs/transcript_full.jsonl');
  const rl = readline.createInterface({ input: fileStream, crlfDelay: Infinity });

  let lineNum = 0;
  for await (const line of rl) {
    lineNum++;
    if (line.includes('modal-export') && line.includes('write_file')) {
      console.log('Script with modal-export at line #' + lineNum);
      const data = JSON.parse(line);
      for (const tc of data.tool_calls || []) {
        const args = tc.args || tc.arguments;
        if (args && args.Content) {
          fs.writeFileSync(path.resolve(__dirname, `script_export_${lineNum}.js`), args.Content);
          console.log(`Saved script_export_${lineNum}.js! Length:`, args.Content.length);
        }
      }
    }
  }
}
findExport();
