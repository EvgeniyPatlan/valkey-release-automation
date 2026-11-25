#!/bin/bash
# Generate GitHub Pages site with install instructions and signing keys.
# Packages are hosted on S3; this script only builds the static site.
# Usage: publish-repos.sh <version> <gpg_fingerprint> <repo_url> <pages_url> <s3_bucket> <s3_region> <site_dir> <template_dir>
set -euo pipefail

VERSION="$1"
GPG_KEY="$2"
REPO_URL="$3"
PAGES_URL="$4"
S3_BUCKET="$5"
S3_REGION="$6"
SITE_DIR="$7"
TEMPLATE_DIR="$8"

# Alpine instructions appear once APK publishing is enabled, i.e. once the
# repository's public key is committed (see publish-to-s3.sh).
APK_PUBLIC_KEY="$(cd "$(dirname "$0")/.." && pwd)/packaging/common/apk/keys/valkey-packages.rsa.pub"
if [ -f "$APK_PUBLIC_KEY" ]; then
  APK_ENABLED=true
else
  APK_ENABLED=false
fi

MAJOR="${VERSION%%.*}"
MINOR_PART="${VERSION#*.}"
MINOR="${MINOR_PART%%.*}"

echo "Generating site: version=${VERSION}, major=${MAJOR}, minor=${MINOR}"
echo "  Repo URL (S3):       ${REPO_URL}"
echo "  Pages URL (GH Pages): ${PAGES_URL}"

mkdir -p "${SITE_DIR}"

################################################################################
# Detect available versions from S3 bucket
################################################################################
echo "Listing versions from s3://${S3_BUCKET}/packaging/..."
AVAILABLE_VERSIONS=""
# Fail closed on discovery errors: a transient listing failure must abort
# rather than publish an index.html that hides every other release line.
# aws s3 ls exits 1 with NO output on either stream for a nonexistent prefix,
# which is the legitimate first-ever publication. A real API failure such as
# AccessDenied also exits 1 with empty stdout, so stderr is what separates
# them and both streams are checked here.
LS_ERR_FILE=$(mktemp)
trap 'rm -f "$LS_ERR_FILE"' EXIT
# Prints the listing of an S3 prefix: empty for a prefix that does not exist,
# a failure for anything else.
s3_ls() {
  local out rc=0 err
  out=$(aws s3 ls "$1" --region "$S3_REGION" 2>"$LS_ERR_FILE") || rc=$?
  err=$(cat "$LS_ERR_FILE")
  if [ "$rc" -ne 0 ] && { [ "$rc" -ne 1 ] || [ -n "$out" ] || [ -n "$err" ]; }; then
    echo "ERROR: could not list $1 (exit ${rc}): ${err:-no stderr}; refusing to publish a partial index." >&2
    return 1
  fi
  printf '%s\n' "$out"
}
LS_OUT=$(s3_ls "s3://${S3_BUCKET}/packaging/") || exit 1
S3_DIRS=$(printf '%s\n' "$LS_OUT" | awk '/PRE valkey-/ {gsub(/PRE /,""); gsub(/\//,""); print}')

for vdir in $S3_DIRS; do
  ver="${vdir#valkey-}"
  if [ -n "$AVAILABLE_VERSIONS" ]; then
    AVAILABLE_VERSIONS="${AVAILABLE_VERSIONS},${ver}"
  else
    AVAILABLE_VERSIONS="${ver}"
  fi
done

# Always include current version
CURRENT_VER="${MAJOR}.${MINOR}"
if ! echo ",${AVAILABLE_VERSIONS}," | grep -q ",${CURRENT_VER},"; then
  if [ -n "$AVAILABLE_VERSIONS" ]; then
    AVAILABLE_VERSIONS="${AVAILABLE_VERSIONS},${CURRENT_VER}"
  else
    AVAILABLE_VERSIONS="${CURRENT_VER}"
  fi
fi
echo "Detected versions: ${AVAILABLE_VERSIONS}"

# Lines with an APK repository, so the page never offers Alpine for a line
# that was never published for it (7.2, or lines published before APK).
APK_VERSIONS=""
APK_KEY_FINGERPRINT=""
if [ "$APK_ENABLED" = true ]; then
  for ver in ${AVAILABLE_VERSIONS//,/ }; do
    # Same rule as above: only a missing prefix means "no APK repository";
    # any other error fails, so it cannot drop Alpine from the page.
    APK_LS=$(s3_ls "s3://${S3_BUCKET}/packaging/valkey-${ver}/apk/") || exit 1
    if [ -n "$APK_LS" ]; then
      APK_VERSIONS="${APK_VERSIONS:+${APK_VERSIONS},}${ver}"
    fi
  done
  APK_KEY_FINGERPRINT=$(openssl pkey -pubin -in "$APK_PUBLIC_KEY" -outform DER | sha256sum | cut -d' ' -f1)
  echo "Versions with APK repositories: ${APK_VERSIONS:-none}"
fi

################################################################################
# Generate index.html from template
################################################################################
cp "${TEMPLATE_DIR}/index.html" "${SITE_DIR}/index.html"
sed -i "s|%%PAGES_URL%%|${PAGES_URL}|g" "${SITE_DIR}/index.html"
sed -i "s|%%REPO_URL%%|${REPO_URL}|g" "${SITE_DIR}/index.html"
sed -i "s|%%VERSIONS%%|${AVAILABLE_VERSIONS}|g" "${SITE_DIR}/index.html"
sed -i "s|%%APK_ENABLED%%|${APK_ENABLED}|g" "${SITE_DIR}/index.html"
sed -i "s|%%APK_VERSIONS%%|${APK_VERSIONS}|g" "${SITE_DIR}/index.html"
sed -i "s|%%APK_KEY_FINGERPRINT%%|${APK_KEY_FINGERPRINT}|g" "${SITE_DIR}/index.html"

################################################################################
# Static files
################################################################################
touch "${SITE_DIR}/.nojekyll"
gpg --armor --export "$GPG_KEY" > "${SITE_DIR}/GPG-KEY-valkey.asc"
if [ "$APK_ENABLED" = true ]; then
  cp "$APK_PUBLIC_KEY" "${SITE_DIR}/valkey-packages.rsa.pub"
fi

echo "Site ready at ${SITE_DIR}"
