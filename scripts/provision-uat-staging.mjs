const url = process.env.SUPABASE_STAGING_URL?.trim();
const key = process.env.SUPABASE_STAGING_SERVICE_ROLE_KEY?.trim();
const password = process.env.UAT_DEFAULT_PASSWORD?.trim();

if (!url || !url.includes('evexaeyryfayfbffzzhh')) {
  throw new Error('STOP: URL bukan project STAGING evexaeyryfayfbffzzhh!');
}

const headers = {
  'apikey': key,
  'Content-Type': 'application/json'
};
if (key.startsWith('eyJ')) {
  headers['Authorization'] = `Bearer ${key}`;
}

async function run() {
  const r1 = await fetch(`${url}/auth/v1/admin/users/15abd4f8-2ae2-4a18-a554-173905a9e7ad`, {
    method: 'PUT',
    headers,
    body: JSON.stringify({ app_metadata: { role: 'cashier' } })
  });
  const d1 = await r1.json();
  console.log('UPDATE uat-cashier:', r1.status, d1.email || JSON.stringify(d1));

  const users = [
    { email: 'uat-warehouse@catatkuota-staging.invalid', role: 'warehouse_admin' },
    { email: 'uat-supervisor@catatkuota-staging.invalid', role: 'supervisor' },
    { email: 'uat-admin@catatkuota-staging.invalid', role: 'admin' }
  ];

  for (const u of users) {
    const r = await fetch(`${url}/auth/v1/admin/users`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        email: u.email,
        password,
        email_confirm: true,
        app_metadata: { role: u.role }
      })
    });
    const d = await r.json();
    console.log(`CREATE ${u.email} (${u.role}):`, r.status, d.id || JSON.stringify(d));
  }
}

run().catch(console.error);
