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
green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }

# Newest build-tools rather than a pinned one: fdroid update needs apksigner,
# and a laptop with only 36.0.0 installed silently got an empty PATH entry.
BUILD_TOOLS="$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | sort -V | tail -1)"
[ -n "$BUILD_TOOLS" ] || { red "No build-tools found under $ANDROID_HOME."; exit 1; }
export PATH="$PATH:${BUILD_TOOLS%/}"

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

# --- render the homepage + README from that index ---
# Version, size, licence, icon and download link of every app come out of
# repo/index-v2.json. Typed by hand they drifted two releases behind the repo,
# and Tankblick was served for weeks without ever appearing on the page.
blue "🧾 Rendering site/index.html and README.md from the index…"
python3 site/render.py

# --- find the running pod ---
POD="$(kubectl -n "$NAMESPACE" get pod -l app="$DEPLOYMENT" \
        -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || { red "No running pod found in namespace $NAMESPACE."; exit 1; }
blue "🚚 Publishing to pod $POD"

# --- push the homepage + repo files into the PVC ---
# Incremental: APK filenames carry the versionCode, so an APK that already
# exists remotely with the same size is byte-identical and gets skipped.
# Everything else (index, icons, diffs) is small and always re-sent.
# `kubectl cp` has no delta transfer, so re-copying every APK on each run
# would mean re-uploading the whole repo (hundreds of MB) for nothing.
REMOTE_REPO="$DOCROOT/fdroid/repo"
kubectl -n "$NAMESPACE" exec "$POD" -- mkdir -p "$REMOTE_REPO"

# name<TAB>size of every remote file, relative to the repo root
remote_list="$(kubectl -n "$NAMESPACE" exec "$POD" -- \
  find "$REMOTE_REPO" -type f -exec stat -c "%n	%s" {} + 2>/dev/null \
  | sed "s|^$REMOTE_REPO/||" || true)"

# Files to send: everything except APKs that are already there at the same size.
send_list="$(mktemp)"
delete_list="$(mktemp)"
trap 'rm -f "$send_list" "$delete_list"' EXIT

while IFS= read -r f; do
  case "$f" in
    *.apk)
      size="$(stat -c '%s' "repo/$f")"
      if printf '%s\n' "$remote_list" | grep -qxF "$f	$size"; then
        continue
      fi
      ;;
  esac
  printf '%s\n' "$f" >> "$send_list"
done < <(cd repo && find . -type f -printf '%P\n' | sort)

# Remote files that no longer exist locally (e.g. archived old versions).
while IFS="	" read -r f _; do
  [ -n "$f" ] || continue
  [ -e "repo/$f" ] || printf '%s\n' "$f" >> "$delete_list"
done < <(printf '%s\n' "$remote_list")

skipped=$(( $(cd repo && find . -type f | wc -l) - $(wc -l < "$send_list") ))
blue "📦 Sending $(wc -l < "$send_list") file(s), skipping $skipped unchanged APK(s)"

kubectl -n "$NAMESPACE" cp site/index.html "$POD:$DOCROOT/index.html"

if [ -s "$send_list" ]; then
  tar -c -C repo -T "$send_list" -f - \
    | kubectl -n "$NAMESPACE" exec -i "$POD" -- tar -x -C "$REMOTE_REPO"
fi

if [ -s "$delete_list" ]; then
  blue "🗑  Removing $(wc -l < "$delete_list") stale remote file(s)"
  while IFS= read -r f; do
    kubectl -n "$NAMESPACE" exec "$POD" -- rm -f "$REMOTE_REPO/$f"
  done < "$delete_list"
fi

green "✅ Published."
green "   Homepage: https://fdroid.ha1nz.de/"
green "   Repo:     https://fdroid.ha1nz.de/fdroid/repo"
