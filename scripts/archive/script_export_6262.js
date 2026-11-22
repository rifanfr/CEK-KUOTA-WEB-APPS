const fs = require('fs');
const path = require('path');
const live = fs.readFileSync(path.resolve(__dirname, 'recovered_live.html'), 'utf8');

console.log('1. Catatan 1 (warehouse-balance-cards):', live.includes('warehouse-balance-cards'));
console.log('2. Catatan 2 (Pilih Cepat Pelanggan):', live.includes('Pilih Cepat Pelanggan Terdaftar'));
console.log('3. Catatan 3 (modal-edit-customer md:grid-cols-2):', live.includes('modal-edit-customer') && live.includes('md:grid-cols-2'));
console.log('4. Catatan 4 (customer-search-col):', live.includes('customer-search-col'));
console.log('5. Catatan 4 (toggleCustomerActionMenu):', live.includes('toggleCustomerActionMenu'));
console.log('6. Intermezzo (modal-export md:grid-cols-2):', live.includes('modal-export') && live.includes('md:grid-cols-2'));
console.log('7. Intermezzo (Mutasi Fisik Gudang in modal export):', live.includes('Mutasi Fisik Gudang'));
console.log('8. History search (hist-search-badge):', live.includes('hist-search-badge'));
console.log('9. History action dropdown (hist-action-dropdown):', live.includes('hist-action-dropdown'));
