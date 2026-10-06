# Frontend overrides

Files here replace the reference app's compiled assets of the same logical path (the key in
`public/assets/.manifest.json`). `bin/override-assets` writes each one to `public/assets` under a new
digest, points the manifest and `app/views/layouts/_assets.html` at it, and removes the reference's
copy. `bin/import-assets` runs it after every import.

| File | Differs from the reference by |
|---|---|
| `models/file_uploader.js` | No `X-CSRF-Token` header: pages carry no CSRF token (forgery protection is by `Sec-Fetch-Site`), and the reference's `document.querySelector("meta[name=csrf-token]").content` throws without one |
