# Aplikasi Pemilihan Ketua OSIS
## SMPN 13 Penajam Paser Utara

Aplikasi web untuk pemilihan Ketua OSIS secara daring, digunakan oleh ±400 siswa pemilih.

---

## Struktur File

```
osis/
├── index.html          ← Halaman voting (NISN → Pilih Paslon → Terima Kasih)
├── admin.html          ← Panel admin (Login, Kontrol, Paslon, Pemilih, Tautan)
├── quickcount.html     ← Layar quick count real-time (proyektor)
├── analytics.html      ← Dashboard analitik
├── css/
│   └── main.css        ← Design system lengkap
├── js/
│   └── config.js       ← Konfigurasi Supabase (WAJIB diisi)
└── sql/
    └── schema.sql      ← Schema database + RPC Supabase
```

---

## Langkah Setup

### 1. Buat Proyek Supabase

1. Buka [supabase.com](https://supabase.com) → **New Project**
2. Pilih region **Singapore** (ap-southeast-1) untuk latensi rendah
3. Catat **Project URL** dan **anon/public key** dari **Settings → API**

### 2. Jalankan SQL Schema

1. Buka **SQL Editor** di dashboard Supabase
2. Paste seluruh isi file `sql/schema.sql`
3. Klik **Run**

### 3. Isi Konfigurasi

Buka `js/config.js` dan ganti nilai berikut:

```js
const SUPABASE_URL = 'https://XXXXX.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...';
```

### 4. Deploy ke GitHub Pages

1. Buat repo GitHub publik: `osis-smpn13`
2. Upload semua file dari folder ini
3. Buka **Settings → Pages → Branch: main, folder: / (root)**
4. Akses via `https://{username}.github.io/osis-smpn13/`

---

## Sandi Default

| Peran | Sandi |
|-------|-------|
| Admin | `guru13` |

**Mengubah sandi admin** — jalankan SQL berikut di Supabase SQL Editor:

```sql
UPDATE election_config
SET admin_password = crypt('sandiBaruAnda', gen_salt('bf'))
WHERE id = 1;
```

---

## Alur Penggunaan

### Hari Pemilihan

1. Admin login ke `admin.html` dengan sandi `guru13`
2. Import data siswa via CSV (format: `nisn,name,class`)
3. Tambahkan data paslon (foto, visi, misi)
4. Buka `quickcount.html` di tab baru → tampilkan di proyektor
5. Klik **Buka Pemilihan** di Tab Kontrol
6. Siswa membuka `index.html` dari masing-masing laptop → masukkan NISN → pilih paslon
7. Quick count otomatis terperbaruai setiap 3 detik
8. Setelah selesai, klik **Tutup Pemilihan**
9. Buka `analytics.html` untuk analisis mendalam

### Format CSV Pemilih

Baris pertama adalah header:
```csv
nisn,name,class
0123456789,Ahmad Fauzi,7A
9876543210,Siti Rahmah,8B
```

---

## Keamanan

- Sandi admin disimpan sebagai **bcrypt hash** di database
- NISN tidak dicatat ke console
- Token admin disimpan di **sessionStorage** (hilang saat tab ditutup)
- Seluruh akses data melalui **RPC + RLS deny-all**
- `cast_vote` menggunakan `SELECT ... FOR UPDATE` untuk mencegah double vote

---

## Spesifikasi Teknis

| Komponen | Teknologi |
|----------|-----------|
| Frontend | HTML + CSS + Vanilla JS |
| Hosting | GitHub Pages |
| Database | Supabase (PostgreSQL) |
| Backend logic | Supabase RPC (PL/pgSQL) |
| Chart library | Chart.js 4 via CDN |
| CSV parser | PapaParse via CDN |
| Supabase SDK | @supabase/supabase-js v2 via CDN |
