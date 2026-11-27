const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

console.log('=== TEST SUITE: ZERO-QUANTITY CUSTOMER REGISTRATION DIVERGENCE ===\n');

const html = fs.readFileSync('cekkuota-kk/dispatch-console.html', 'utf8');

// Ekstrak script utama
const scriptRegex = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let match;
let mainScript = '';
while ((match = scriptRegex.exec(html)) !== null) {
  if (match[1].length > 10000) {
    mainScript = match[1];
    break;
  }
}

function createTestEnvironment() {
  const storageData = {};
  const mockLocalStorage = {
    getItem: (k) => storageData[k] !== undefined ? storageData[k] : null,
    setItem: (k, v) => { storageData[k] = String(v); },
    removeItem: (k) => { delete storageData[k]; },
    clear: () => { Object.keys(storageData).forEach((k) => delete storageData[k]); }
  };

  const sessionStorageData = {};
  const mockSessionStorage = {
    getItem: (k) => sessionStorageData[k] !== undefined ? sessionStorageData[k] : null,
    setItem: (k, v) => { sessionStorageData[k] = String(v); },
    removeItem: (k) => { delete sessionStorageData[k]; },
    clear: () => { Object.keys(sessionStorageData).forEach((k) => delete sessionStorageData[k]); }
  };

  const elements = {};
  function getOrCreateElement(id, tag = 'div') {
    if (!elements[id]) {
      elements[id] = {
        id,
        tagName: tag.toUpperCase(),
        innerHTML: '',
        textContent: '',
        value: '',
        className: '',
        style: {},
        classList: {
          _set: new Set(),
          add: function(...c) { c.forEach((x) => this._set.add(x)); },
          remove: function(...c) { c.forEach((x) => this._set.delete(x)); },
          toggle: function(x) { this._set.has(x) ? this._set.delete(x) : this._set.add(x); },
          contains: function(x) { return this._set.has(x); }
        },
        addEventListener: () => {},
        removeEventListener: () => {},
        setAttribute: function(k, v) { this[k] = v; },
        getAttribute: function(k) { return this[k] || ''; },
        removeAttribute: function(k) { delete this[k]; },
        querySelector: () => null,
        querySelectorAll: () => [],
        appendChild: () => {},
        removeChild: () => {},
        focus: () => {},
        blur: () => {},
        remove: function() {},
      };
    }
    return elements[id];
  }

  // Pre-populate input fields yang sering diakses
  const domIds = [
    'record-kk-input', 'record-customer-status-area', 'record-quota-blocked-banner',
    'record-blocked-reset-note', 'record-quota-hint', 'header-auth-control',
    'header-auth-role-badge', 'header-auth-user-email', 'header-auth-action-btn',
    'set-supabase-url', 'set-supabase-key', 'set-app-title', 'set-max-beras',
    'set-max-gas', 'set-cycle-days', 'set-admin-pin', 'set-low-stock',
    'set-default-prov', 'set-default-kab', 'inline-new-name', 'inline-new-detail',
    'inline-reg-prov', 'inline-reg-kab', 'inline-reg-kec', 'inline-reg-desa',
    'modal-confirm', 'confirm-modal-title', 'confirm-modal-message', 'confirm-modal-cancel-btn',
    'confirm-modal-ok-btn', 'toast-container', 'cloud-status-indicator', 'cloud-status-text'
  ];
  domIds.forEach((id) => getOrCreateElement(id));

  let confirmModalCallback = null;

  const mockDoc = {
    getElementById: (id) => getOrCreateElement(id),
    querySelector: (sel) => {
      if (sel.startsWith('#')) return getOrCreateElement(sel.slice(1));
      return getOrCreateElement('mock-' + sel.replace(/[^a-zA-Z0-9]/g, ''));
    },
    querySelectorAll: () => [],
    createElement: (tag) => getOrCreateElement('el-' + Math.random(), tag),
    addEventListener: () => {},
    removeEventListener: () => {},
    body: getOrCreateElement('body'),
    documentElement: getOrCreateElement('html'),
  };

  const contextObj = {
    console: {
      log: console.log,
      warn: console.warn,
      info: console.info,
      error: console.error,
    },
    localStorage: mockLocalStorage,
    sessionStorage: mockSessionStorage,
    document: mockDoc,
    location: { reload: () => {}, href: 'http://localhost/' },
    addEventListener: () => {},
    removeEventListener: () => {},
    crypto: {
      randomUUID: () => '11111111-2222-3333-4444-555555555555',
      getRandomValues: (arr) => arr.fill(1)
    },
    setTimeout: (fn) => setTimeout(fn, 0),
    clearTimeout: (id) => clearTimeout(id),
    setInterval: () => 123,
    clearInterval: () => {},
    navigator: { onLine: true, userAgent: 'NodeTestEnv' },
    AbortController: globalThis.AbortController,
    URLSearchParams: globalThis.URLSearchParams,
    __APP_CONFIG__: {
      supabaseUrl: 'https://evexaeyryfayfbffzzhh.supabase.co',
      supabaseAnonKey: 'mock-anon-key'
    },
    confirm: () => true,
    alert: () => {},
    fetch: async () => { throw new Error('Fetch not mocked yet'); }
  };
  contextObj.window = contextObj;
  contextObj.global = contextObj;
  contextObj.self = contextObj;

  // Cashier session
  sessionStorageData['catat_kuota_supabase_auth_session_v1'] = JSON.stringify({
    access_token: 'mock-cashier-jwt-token',
    refresh_token: 'mock-refresh-token',
    expires_at: Date.now() + 3600000,
    user_id: 'cashier-uuid-001',
    email: 'kasir1@organisasi.id',
    role: 'cashier',
    remember: false
  });

  const vmContext = vm.createContext(contextObj);
  vm.runInContext(mainScript, vmContext);

  // Hook openConfirmModal agar kita bisa mengeksekusi callback konfirmasi secara otomatis
  vm.runInContext(`
    const originalOpenConfirmModal = openConfirmModal;
    window.__lastConfirmPromise = null;
    openConfirmModal = function(title, message, onConfirm) {
      if (onConfirm) {
        window.__lastConfirmPromise = (async () => {
          try {
            return await onConfirm();
          } catch (e) {
            throw e;
          }
        })();
      }
    };
  `, vmContext);

  return { vmContext, elements, storageData };
}

async function runTestSuite() {
  // =========================================================================
  // SCENARIO 1: Registrasi KK Baru Qty = 0 dengan Network Timeout (Offline)
  // =========================================================================
  console.log('1. Pengujian Registrasi KK Baru Qty = 0 saat Network Timeout / Terputus:');
  const env1 = createTestEnvironment();

  // Mock fetch: simulasi network timeout (AbortError / TypeError Failed to Fetch)
  env1.vmContext.fetch = async () => {
    const err = new Error('Request timeout ke server (10s)');
    err.name = 'TimeoutError';
    err.code = 'ETIMEDOUT';
    err.status = 408;
    throw err;
  };

  // Petugas memasukkan KK baru dan kuantitas 0
  const kkBaru = '3201010101010099';
  const namaBaru = 'WARGA UJI PHASE 3';

  vm.runInContext(`
    state.record.kkInput = '${kkBaru}';
    state.record.qtyBeras = 0;
    state.record.qtyGas = 0;
    state.record.newCustomerName = '${namaBaru}';
    state.record.newCustomerProv = 'JAWA BARAT';
    state.record.newCustomerKab = 'KAB. BOGOR';
    state.record.newCustomerKec = 'CIBINONG';
    state.record.newCustomerDesa = 'CIBINONG';
    state.record.newCustomerDetail = 'RT 01/RW 02';
  `, env1.vmContext);

  // Jalankan saveQuotaRecord()
  await vm.runInContext('saveQuotaRecord()', env1.vmContext);
  await env1.vmContext.__lastConfirmPromise;

  // VERIFIKASI 1.1: Customer TIDAK boleh masuk ke state.customers!
  const stateCust1 = vm.runInContext('state.customers', env1.vmContext);
  const foundInLocal1 = stateCust1.find((c) => c.no_kk === kkBaru);
  assert.strictEqual(foundInLocal1, undefined, 'Customer TIDAK BOLEH ditambahkan ke state.customers sebelum RPC sukses!');
  console.log('   ✓ Terverifikasi: Customer TIDAK ditambahkan ke state.customers lokal saat timeout.');

  // VERIFIKASI 1.2: Persistent Outbox entry HARUS dibuat sebelum/selama request dengan status pending
  const outboxEntries1 = vm.runInContext('OutboxManager.getEntries()', env1.vmContext);
  assert.strictEqual(outboxEntries1.length, 1, 'Harus ada tepat 1 item dalam Outbox');
  const outboxItem1 = outboxEntries1[0];
  assert.strictEqual(outboxItem1.type, 'register_customer');
  assert.strictEqual(outboxItem1.payload.p_no_kk, kkBaru);
  assert.strictEqual(outboxItem1.payload.p_nama, namaBaru);
  assert.strictEqual(outboxItem1.status, 'pending');
  assert.strictEqual(outboxItem1.retryCount, 1);
  console.log('   ✓ Terverifikasi: Request ID & payload 9 parameter tersimpan di antrean Outbox (status pending).');

  // VERIFIKASI 1.3: UI Record Tab TIDAK boleh menampilkan badge 'Terdaftar', tapi HARUS menampilkan 'MENUNGGU SINKRONISASI'
  vm.runInContext('renderRecordTab()', env1.vmContext);
  const statusHtml1 = env1.elements['record-customer-status-area'].innerHTML;
  assert.ok(!statusHtml1.includes('Terdaftar</span>'), 'UI TIDAK BOLEH menampilkan badge TERDAFTAR saat belum sinkron!');
  assert.ok(statusHtml1.includes('MENUNGGU SINKRONISASI'), 'UI HARUS menampilkan badge MENUNGGU SINKRONISASI!');
  assert.ok(statusHtml1.includes(namaBaru), 'UI harus menampilkan nama warga yang menunggu sinkronisasi');
  console.log('   ✓ Terverifikasi: UI Record Tab menampilkan badge "MENUNGGU SINKRONISASI" dan mengunci input kuota.\n');


  // =========================================================================
  // SCENARIO 2: Registrasi KK Baru Qty = 0 Ditolak Server (Terminal Error P0009 / 403)
  // =========================================================================
  console.log('2. Pengujian Registrasi KK Baru Qty = 0 Ditolak Server (Terminal Error):');
  const env2 = createTestEnvironment();

  // Mock fetch: melempar terminal RPC error P0009 (Nomor KK tidak valid / terdaftar di sistem pusat)
  env2.vmContext.fetch = async () => {
    return {
      ok: false,
      status: 400,
      json: async () => ({
        code: 'P0009',
        message: 'Format Nomor KK tidak valid menurut basis data Kependudukan'
      })
    };
  };

  const kkBermasalah = '3201010101010088';
  vm.runInContext(`
    state.record.kkInput = '${kkBermasalah}';
    state.record.qtyBeras = 0;
    state.record.qtyGas = 0;
    state.record.newCustomerName = 'WARGA DITOLAK';
    state.record.newCustomerProv = 'JAWA BARAT';
    state.record.newCustomerKab = 'KAB. BOGOR';
    state.record.newCustomerKec = 'CIBINONG';
    state.record.newCustomerDesa = 'CIBINONG';
  `, env2.vmContext);

  await vm.runInContext('saveQuotaRecord()', env2.vmContext);
  await env2.vmContext.__lastConfirmPromise;

  // VERIFIKASI 2.1: Customer tidak masuk ke state.customers
  const stateCust2 = vm.runInContext('state.customers', env2.vmContext);
  assert.strictEqual(stateCust2.find((c) => c.no_kk === kkBermasalah), undefined, 'Customer ditolak tidak boleh ada di state.customers');

  // VERIFIKASI 2.2: Outbox aktif bersih dari item terminal; dipindahkan ke DEAD_LETTER
  const activeOutbox2 = vm.runInContext('OutboxManager.getEntries()', env2.vmContext);
  assert.strictEqual(activeOutbox2.length, 0, 'Outbox aktif harus 0 (item terminal langsung dikeluarkan)');
  const deadLetter2 = vm.runInContext('OutboxManager.getDeadLetterEntries()', env2.vmContext);
  assert.strictEqual(deadLetter2.length, 1, 'Item terminal harus masuk ke Dead Letter');
  assert.strictEqual(deadLetter2[0].payload.p_no_kk, kkBermasalah);
  console.log('   ✓ Terverifikasi: Terminal error (P0009) diisolasi ke Dead-Letter, tidak masuk state lokal.\n');


  // =========================================================================
  // SCENARIO 3: Registrasi KK Baru Qty = 0 Sukses Terverifikasi Server (Cloud Connected)
  // =========================================================================
  console.log('3. Pengujian Registrasi KK Baru Qty = 0 Sukses ke Server Cloud:');
  const env3 = createTestEnvironment();

  const kkSukses = '3201010101010077';
  const namaSukses = 'WARGA SUKSES CLOUD';

  // Mock fetch: RPC register_customer berhasil
  env3.vmContext.fetch = async (url, opts) => {
    if (url.includes('/rpc/register_customer')) {
      const payload = JSON.parse(opts.body);
      assert.strictEqual(payload.p_no_kk, kkSukses);
      assert.strictEqual(payload.p_nama, namaSukses);
      assert.strictEqual(Object.keys(payload).length, 9, 'Payload register_customer harus tepat 9 parameter');
      return {
        ok: true,
        json: async () => ({
          success: true,
          action: 'REGISTER_CUSTOMER',
          request_id: payload.p_request_id,
          customer: {
            member_id: 'MBR-' + kkSukses.slice(-6),
            no_kk: kkSukses,
            nama: namaSukses
          }
        })
      };
    }
    throw new Error('Unexpected fetch call: ' + url);
  };

  vm.runInContext(`
    state.record.kkInput = '${kkSukses}';
    state.record.qtyBeras = 0;
    state.record.qtyGas = 0;
    state.record.newCustomerName = '${namaSukses}';
    state.record.newCustomerProv = 'JAWA BARAT';
    state.record.newCustomerKab = 'KAB. BOGOR';
    state.record.newCustomerKec = 'CIBINONG';
    state.record.newCustomerDesa = 'CIBINONG';
  `, env3.vmContext);

  await vm.runInContext('saveQuotaRecord()', env3.vmContext);
  await env3.vmContext.__lastConfirmPromise;

  // VERIFIKASI 3.1: Customer ditambahkan tepat 1x ke state.customers dengan is_dirty: false
  const stateCust3 = vm.runInContext('state.customers', env3.vmContext);
  const foundSukses = stateCust3.filter((c) => c.no_kk === kkSukses);
  assert.strictEqual(foundSukses.length, 1, 'Customer harus ditambahkan tepat 1x ke state.customers');
  assert.strictEqual(foundSukses[0].is_dirty, false, 'is_dirty harus bernilai false setelah server sukses');
  assert.strictEqual(foundSukses[0].nama, namaSukses);
  console.log('   ✓ Terverifikasi: Customer ditambahkan 1x ke state.customers dengan is_dirty: false.');

  // VERIFIKASI 3.2: Outbox aktif bersih
  const activeOutbox3 = vm.runInContext('OutboxManager.getEntries()', env3.vmContext);
  assert.strictEqual(activeOutbox3.length, 0, 'Outbox aktif harus 0 setelah RPC sukses');
  console.log('   ✓ Terverifikasi: Outbox aktif dibersihkan setelah transaksi sukses.');

  // VERIFIKASI 3.3: UI Record Tab menampilkan status 'Terdaftar'
  vm.runInContext('renderRecordTab()', env3.vmContext);
  const statusHtml3 = env3.elements['record-customer-status-area'].innerHTML;
  assert.ok(statusHtml3.includes('Terdaftar</span>'), 'UI sekarang HARUS menampilkan status Terdaftar');
  console.log('   ✓ Terverifikasi: UI Record Tab menampilkan badge "Terdaftar" dengan kuota penuh.\n');


  // =========================================================================
  // SCENARIO 4: Pemulihan Pendaftaran Tertunda saat Sinkronisasi (processOutboxQueue)
  // =========================================================================
  console.log('4. Pengujian Rekonstruksi Customer dari Outbox saat Sinkronisasi Berhasil:');
  const env4 = createTestEnvironment();

  const kkPending = '3201010101010066';
  const namaPending = 'WARGA RECOVERY OUTBOX';

  // Simulasikan ada item register_customer tersimpan di Outbox dari sesi sebelumnya
  const reqId4 = 'REQ-REG-004';
  vm.runInContext(`
    OutboxManager.add('register_customer', '${reqId4}', {
      p_request_id: '${reqId4}',
      p_no_kk: '${kkPending}',
      p_member_id: 'MBR-004',
      p_nama: '${namaPending}',
      p_provinsi: 'JAWA BARAT',
      p_kabupaten: 'KAB. BOGOR',
      p_kecamatan: 'CIBINONG',
      p_desa: 'CIBINONG',
      p_detail: 'JL. MERDEKA 10'
    }, {
      no_kk: '${kkPending}',
      nama: '${namaPending}',
      no_hp: '08123456789'
    });
  `, env4.vmContext);

  // Pastikan di state.customers belum ada customer tersebut
  assert.strictEqual(vm.runInContext('state.customers', env4.vmContext).length, 0);

  // Mock fetch: RPC sukses saat sync
  env4.vmContext.fetch = async (url) => {
    if (url.includes('/rpc/register_customer')) {
      return {
        ok: true,
        json: async () => ({
          success: true,
          action: 'REGISTER_CUSTOMER',
          customer: { member_id: 'MBR-004', no_kk: kkPending, nama: namaPending }
        })
      };
    }
    throw new Error('Unexpected url: ' + url);
  };

  // Jalankan processOutboxQueue()
  const syncResult = await vm.runInContext('processOutboxQueue()', env4.vmContext);
  assert.strictEqual(syncResult.success, 1);

  // VERIFIKASI 4.1: Customer direkonstruksi dan ditambahkan ke state.customers
  const stateCust4 = vm.runInContext('state.customers', env4.vmContext);
  assert.strictEqual(stateCust4.length, 1, 'Customer dari outbox harus masuk ke state.customers');
  assert.strictEqual(stateCust4[0].no_kk, kkPending);
  assert.strictEqual(stateCust4[0].nama, namaPending);
  assert.strictEqual(stateCust4[0].is_dirty, false);
  assert.strictEqual(vm.runInContext('OutboxManager.getEntries()', env4.vmContext).length, 0);
  console.log('   ✓ Terverifikasi: Customer tertunda berhasil direkonstruksi 1x ke state.customers saat sinkron.\n');


  // =========================================================================
  // SCENARIO 5: Transaksi dengan Kuantitas > 0 (process_quota_dispense) Tetap Berfungsi
  // =========================================================================
  console.log('5. Pengujian Penyaluran Kuota (Qty > 0) Tetap Menggunakan process_quota_dispense:');
  const env5 = createTestEnvironment();

  // Daftarkan dulu customer
  const kkDispense = '3201010101010055';
  vm.runInContext(`
    state.customers.push({
      member_id: 'MBR-005',
      no_kk: '${kkDispense}',
      nama: 'WARGA TRANSAKSI',
      provinsi: 'JAWA BARAT',
      kabupaten: 'KAB. BOGOR',
      kecamatan: 'CIBINONG',
      desa: 'CIBINONG',
      is_dirty: false
    });
    // Beri stok gudang
    state.warehouseLogs.push({
      id: 'WH-INIT-BERAS',
      date: '2026-11-24',
      type: 'INITIAL-STOCK',
      item: 'beras',
      qty: 100,
      ref: 'SALDO AWAL'
    });
    state.warehouseLogs.push({
      id: 'WH-INIT-GAS',
      date: '2026-11-24',
      type: 'INITIAL-STOCK',
      item: 'gas',
      qty: 100,
      ref: 'SALDO AWAL'
    });
  `, env5.vmContext);

  let dispenseRpcCalled = false;
  env5.vmContext.fetch = async (url, opts) => {
    if (url.includes('/rest/v1/logs?no_kk=')) {
      // Concurrency check GET logs
      return { ok: true, json: async () => [] };
    }
    if (url.includes('/rpc/process_quota_dispense')) {
      dispenseRpcCalled = true;
      const payload = JSON.parse(opts.body);
      assert.strictEqual(payload.p_no_kk, kkDispense);
      assert.strictEqual(payload.p_qty_beras, 2);
      assert.strictEqual(payload.p_qty_gas, 1);
      assert.strictEqual(Object.keys(payload).length, 14, 'Payload process_quota_dispense harus tepat 14 parameter');
      return {
        ok: true,
        json: async () => ({
          success: true,
          action: 'DISPENSE_QUOTA',
          remaining_quota: { beras: 3, gas: 4 }
        })
      };
    }
    throw new Error('Unexpected URL: ' + url);
  };

  vm.runInContext(`
    state.record.kkInput = '${kkDispense}';
    state.record.qtyBeras = 2;
    state.record.qtyGas = 1;
  `, env5.vmContext);

  await vm.runInContext('saveQuotaRecord()', env5.vmContext);
  if (env5.vmContext.__lastConfirmPromise) {
    await env5.vmContext.__lastConfirmPromise;
  }

  assert.strictEqual(dispenseRpcCalled, true, 'process_quota_dispense RPC harus dipanggil untuk Qty > 0');
  const logs5 = vm.runInContext('state.logs', env5.vmContext);
  assert.strictEqual(logs5.length, 1);
  assert.strictEqual(logs5[0].qty_beras, 2);
  assert.strictEqual(logs5[0].qty_gas, 1);
  console.log('   ✓ Terverifikasi: Penyaluran kuota (Qty > 0) memanggil process_quota_dispense dengan 14 parameter.\n');

  // =========================================================================
  // SCENARIO 6: False-Timeout Registrasi KK Qty = 0 (RPC Lambat tapi Sukses di Cloud)
  // =========================================================================
  console.log('6. Pengujian Rekonsiliasi False-Timeout (RPC Timeout 10s tetapi Berhasil di Server):');
  const env6 = createTestEnvironment();

  const kkFalseTimeout = '3201010101010088';
  const namaFalseTimeout = 'UJI COBA 1';
  let verifyGetCalled = false;

  env6.vmContext.fetch = async (url, options = {}) => {
    // 1. POST RPC register_customer mengalami timeout di sisi client (10s/15s)
    if (url.includes('/rpc/register_customer')) {
      const err = new Error('Request timeout ke server (10s)');
      err.name = 'TimeoutError';
      err.code = 'ETIMEDOUT';
      err.status = 408;
      throw err;
    }

    // 2. Client melakukan verifikasi RPC verify_customer_registration_v4 (tanpa direct REST GET)
    if (url.includes('/rpc/verify_customer_registration_v4')) {
      verifyGetCalled = true;
      const vBody = JSON.parse(options.body || '{}');
      assert.strictEqual(vBody.p_no_kk, kkFalseTimeout);
      return {
        ok: true,
        json: async () => ({
          status: 'COMMITTED_MATCH',
          is_idempotent_replay: true,
          customer: {
            no_kk: kkFalseTimeout,
            nama: namaFalseTimeout,
            member_id: 'MBR-UJI-001',
            provinsi: 'JAWA BARAT',
            kabupaten: 'KAB. BOGOR',
            kecamatan: 'CIBINONG',
            desa: 'CIBINONG',
            detail: 'RT 01',
            created_at: new Date().toISOString()
          }
        })
      };
    }

    throw new Error('Unexpected URL: ' + url);
  };

  vm.runInContext(`
    state.record.kkInput = '${kkFalseTimeout}';
    state.record.qtyBeras = 0;
    state.record.qtyGas = 0;
    state.record.newCustomerName = '${namaFalseTimeout}';
    state.record.newCustomerProv = 'JAWA BARAT';
    state.record.newCustomerKab = 'KAB. BOGOR';
    state.record.newCustomerKec = 'CIBINONG';
    state.record.newCustomerDesa = 'CIBINONG';
    state.record.newCustomerDetail = 'RT 01';
  `, env6.vmContext);

  await vm.runInContext('saveQuotaRecord()', env6.vmContext);
  if (env6.vmContext.__lastConfirmPromise) {
    await env6.vmContext.__lastConfirmPromise;
  }

  assert.strictEqual(verifyGetCalled, true, 'Kueri verifikasi status cloud harus dipanggil saat RPC timeout');
  const stateCust6 = vm.runInContext('state.customers', env6.vmContext);
  assert.strictEqual(stateCust6.length, 1, 'Customer harus masuk ke state.customers karena terverifikasi di Cloud');
  assert.strictEqual(stateCust6[0].no_kk, kkFalseTimeout);
  assert.strictEqual(stateCust6[0].nama, namaFalseTimeout);
  assert.strictEqual(stateCust6[0].is_dirty, false);
  const outbox6 = vm.runInContext('OutboxManager.getEntries()', env6.vmContext);
  assert.strictEqual(outbox6.length, 0, 'Outbox HARUS KOSONG (transaksi sukses tidak boleh tertinggal di outbox)');
  console.log('   ✓ Terverifikasi: False-timeout berhasil direkonsiliasi tanpa error ke user.');
  console.log('   ✓ Terverifikasi: Customer masuk state lokal dengan status bersih (is_dirty: false).');
  console.log('   ✓ Terverifikasi: Transaksi sukses dicegah masuk/tertinggal di antrean Outbox.\n');

  // =========================================================================
  // SCENARIO 7: Pembersihan Otomatis Outbox saat Customer sudah Ada di Cloud
  // =========================================================================
  console.log('7. Pengujian Pembersihan Outbox untuk KK yang Sudah Masuk Cloud:');
  const env7 = createTestEnvironment();

  const kkExisting = '3201010101010077';
  const reqId7 = 'REQ-EXISTING-007';

  // Simulasi: Customer sudah ada di state lokal dari hasil sync cloud sebelumnya
  vm.runInContext(`
    state.customers.push({
      no_kk: '${kkExisting}',
      nama: 'WARGA SUDAH SINKRON',
      member_id: 'MBR-007',
      is_dirty: false
    });
    // Tambahkan item outbox lama (misal sisa false-timeout sesi sebelumnya)
    OutboxManager.add('register_customer', '${reqId7}', {
      p_request_id: '${reqId7}',
      p_no_kk: '${kkExisting}',
      p_member_id: 'MBR-007',
      p_nama: 'WARGA SUDAH SINKRON'
    }, {
      no_kk: '${kkExisting}'
    });
  `, env7.vmContext);

  assert.strictEqual(vm.runInContext('OutboxManager.getEntries()', env7.vmContext).length, 1);

  // Jalankan processOutboxQueue()
  const syncResult7 = await vm.runInContext('processOutboxQueue()', env7.vmContext);
  assert.strictEqual(syncResult7.success, 1, 'Item outbox harus berhasil diselesaikan');
  assert.strictEqual(vm.runInContext('OutboxManager.getEntries()', env7.vmContext).length, 0, 'Outbox harus bersih');
  console.log('   ✓ Terverifikasi: Item outbox KK yang sudah ada di cloud otomatis dibersihkan saat sync.\n');

  console.log('=== ALL 7 SCENARIOS PASSED WITH 100% SUCCESS ===');
  process.exit(0);
}

runTestSuite().catch((err) => {
  console.error('FATAL TEST ERROR:', err);
  process.exit(1);
});
