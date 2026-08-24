# ha1nz Apps — an F-Droid repository

**Built by machines, tested by humans.**

A small, self-hosted [F-Droid](https://f-droid.org) repository for modern Android
apps. Each app is coded by AI (Claude / Claude Code) and put through its paces by
a human who actually uses it — the human is the product owner: they decide what
to build, review the code, test every release, and sign & publish it.

- **Homepage:** https://fdroid.ha1nz.de/
- **Repo URL:** `https://fdroid.ha1nz.de/fdroid/repo`
- **Fingerprint (SHA-256):** `2DF848F5A8BCCF5EFCF307727D41C28EACA96393D1409A833F289F3A15BD446D`

## Apps

| App | Summary | Version | License | Source |
|-----|---------|---------|---------|--------|
| **SimpleDay** | Minimalist Markdown diary with app lock and your-own-cloud WebDAV sync | 1.2.0 | GPL-3.0-only | [MiggiV2/SimpleDay](https://github.com/MiggiV2/SimpleDay) |
| **Movie Mobile** | Browse your Movie Archive collection, online or offline | 1.3.0 | MIT | [Miggi/movie-mobile2](https://code.mymiggi.de/Miggi/movie-mobile2) |
| **Piko Pop** | Sticker-first, cozy Matrix messenger — encrypted, no password field | 0.1.0 (pre-release) | GPL-3.0-or-later | [Miggi/Piko-Pop](https://code.mymiggi.de/Miggi/Piko-Pop) |

---

## Add this repo to your phone

You need an F-Droid-compatible client. Any of these work:

- [F-Droid](https://f-droid.org/) or [F-Droid Basic](https://f-droid.org/packages/org.fdroid.basic/)
- [Neo Store](https://github.com/NeoApplications/Neo-Store)
- [Obtainium](https://github.com/ImranR98/Obtainium)

Then add the repository one of these ways:

**Easiest — from the homepage:** open <https://fdroid.ha1nz.de/> on your phone and
tap **“Add to F-Droid client”**. Your client opens with the URL and fingerprint
prefilled — confirm and you’re done.

**Manually:** in your client go to *Settings → Repositories → Add*, then enter:

```
URL:         https://fdroid.ha1nz.de/fdroid/repo
Fingerprint: 2DF848F5A8BCCF5EFCF307727D41C28EACA96393D1409A833F289F3A15BD446D
```

Once added, install **SimpleDay** from the client and get automatic update
notifications for every new release.

> **First install:** Android will ask you to allow installing apps from your
> F-Droid client the first time. This is normal for any store outside Google Play.

---

## How it works

This repo is just static files behind an nginx server:

```
https://fdroid.ha1nz.de/
├── index.html              ← the homepage
└── fdroid/repo/
    ├── index-v2.json        ← signed app index (what clients read)
    ├── index-v1.jar         ← signed legacy index
    └── *.apk                ← the app binaries
```

The **index is signed** with a repo key that lives only on the maintainer’s
machine. Clients pin the fingerprint above, so they reject any index that
wasn’t signed with that exact key — a tampered mirror can’t inject apps.

Hosting is a personal [k3s](https://k3s.io) cluster, deployed via Flux (GitOps).
The Kubernetes manifest is in [`k8s/fdroid.yaml`](k8s/fdroid.yaml): an nginx
`Deployment` serving a Longhorn `PersistentVolumeClaim`, a `Service`, and a
Traefik `Ingress` with a cert-manager TLS certificate.

---

## Maintainer setup

Everything below is for running your **own** copy of this repo.

### Prerequisites

- Python 3 + [`fdroidserver`](https://f-droid.org/docs/Build_Server_Setup/)
- A JDK (for `keytool`/`apksigner`) and the Android SDK build-tools (`apksigner`, `aapt`)
- `kubectl` with access to the target cluster (only needed to publish)

### One-time init

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install fdroidserver

export ANDROID_HOME=$HOME/Android/Sdk
fdroid init          # generates config.yml + keystore.p12 (your repo signing key)
```

Then edit `config.yml` (see [`config.example.yml`](config.example.yml)) to set
`repo_url`, `repo_name`, and `repo_description`.

> ⚠️ **Guard two things forever:** `keystore.p12` (the signing key) and the
> passwords in `config.yml`. Both are gitignored. Back up `keystore.p12` —
> losing it means every user has to remove and re-add the repo.

### Add an app / publish a new version

Drop the signed release APK in and publish:

```bash
./publish-fdroid.sh path/to/app-release.apk
```

The script:

1. copies the APK into `repo/`,
2. runs `fdroid update` to rebuild and **sign** the index,
3. syncs the homepage + `repo/` into the cluster PVC **incrementally** — an APK
   that already exists on the server with the same filename and size is
   skipped, and files deleted locally are removed remotely.

Run it with **no arguments** to just re-sign the index and re-sync (e.g. after
editing the homepage or an app’s metadata under `metadata/`).

Because the index, icons, and screenshots are always re-sent while APKs are
matched by filename + size, a typical re-publish moves a few MB instead of the
whole repo. The versionCode is part of every APK filename, so same name + same
size means the same bytes. If you ever rebuild an APK **without** changing its
filename, delete it from the server first (or rename it) so the new build is
actually uploaded.

### Multi-ABI (split) APKs

For apps built with ABI splits, give each ABI its own versionCode — the usual
scheme is `baseVersionCode * 1000 + abiCode` with the ABIs numbered so that the
preferred one sorts highest (e.g. `armeabi-v7a=1`, `arm64-v8a=2`). F-Droid
clients install the highest versionCode whose `nativecode` matches the device,
so a 64-bit phone gets the arm64 APK and a 32-bit one falls back to armeabi-v7a.

Two consequences worth remembering:

- Once you publish `*1000`-style codes, **every** later release must keep the
  multiplier. A bare `versionCode 5` would rank below an already-published
  `4002` and F-Droid would treat it as a downgrade and ignore it.
- Keep the older universal APK in `repo/` if you still want to serve ABIs the
  splits don’t cover (e.g. `x86_64` emulators); its lower versionCode means
  split-capable devices still prefer the smaller APK.

---

## Repository layout

```
.
├── site/index.html            # homepage (served at /)
├── metadata/                   # per-app F-Droid metadata (name, summary, license…)
├── k8s/fdroid.yaml             # Kubernetes manifest (nginx + PVC + Ingress)
├── publish-fdroid.sh           # build signed index + push to the cluster
├── config.example.yml          # template for config.yml (real one is gitignored)
└── .gitignore                  # keeps keystore + passwords + binaries out of git
```

## License

The apps have their own licenses (see the table above). This repository’s
tooling and homepage are provided as-is.
