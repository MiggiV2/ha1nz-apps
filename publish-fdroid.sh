#!/usr/bin/env bash
# Publish the F-Droid repo + homepage to the k3s cluster.
#
#   ./publish-fdroid.sh [path/to/new.apk ...]
#
# With APK arguments: copies them into repo/ first, so `fdroid update`
# picks up the new version(s). Without arguments: just rebuilds the signed
# index from whatever is already in repo/ and re-syncs.
#
# Secrets (keystore.p12, keystore passwords in config.yml) stay local and are
# never sent anywhere except into the signed index. Only public artifacts
# (index + APKs + homepage) are copied to the cluster.
set -euo pipefail

cd "$(dirname "$0")"

# --- config ---
NAMESPACE="fdroid"
DEPLOYMENT="fdroid"
DOCROOT="/usr/share/nginx/html"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_HOME
export PATH="$PATH:$ANDROID_HOME/build-tools/36.1.0"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }

# --- sanity checks ---
[ -f config.yml ]   || { red "config.yml not found — run 'fdroid init' first."; exit 1; }
[ -f keystore.p12 ] || { red "keystore.p12 not found — the repo signing key is missing."; exit 1; }
[ -d .venv ]        || { red ".venv not found — create it and 'pip install fdroidserver'."; exit 1; }

# shellcheck disable=SC1091
. .venv/bin/activate

# --- optionally ingest new APKs ---
if [ "$#" -gt 0 ]; then
  for apk in "$@"; do
    [ -f "$apk" ] || { red "APK not found: $apk"; exit 1; }
    blue "📥 Adding $(basename "$apk") to repo/"
    cp "$apk" repo/
  done
fi

# --- rebuild + sign the index ---
blue "🔏 Generating signed index (fdroid update)…"
fdroid update 2>&1 | grep -vE "WARNING: (A restricted|java.lang.System|Use --enable|Restricted methods)" || true

# --- find the running pod ---
POD="$(kubectl -n "$NAMESPACE" get pod -l app="$DEPLOYMENT" \
        -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || { red "No running pod found in namespace $NAMESPACE."; exit 1; }
blue "🚚 Publishing to pod $POD"

# --- push the homepage + repo files into the PVC ---
# Wipe the remote repo dir first so re-runs stay clean (no repo/repo nesting,
# and files deleted locally also disappear on the server).
kubectl -n "$NAMESPACE" exec "$POD" -- sh -c "mkdir -p $DOCROOT/fdroid && rm -rf $DOCROOT/fdroid/repo"
kubectl -n "$NAMESPACE" cp site/index.html "$POD:$DOCROOT/index.html"
kubectl -n "$NAMESPACE" cp repo             "$POD:$DOCROOT/fdroid/repo"

green "✅ Published."
green "   Homepage: https://fdroid.ha1nz.de/"
green "   Repo:     https://fdroid.ha1nz.de/fdroid/repo"
