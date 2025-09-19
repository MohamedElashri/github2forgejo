#!/usr/bin/env bash
# GitHub -> Forgejo migrator (safe, non-destructive)
# - Authenticated GitHub API (GITHUB_TOKEN required)
# - No deletions
# - Mirror (continuous) or one-time clone
# - Optional .env loading
# - Optional cron install
# - On reruns in mirror mode: force-sync mirrors and verify default-branch HEAD matches GitHub

set -Eeuo pipefail
IFS=$' \t\n'

# -------- defaults --------
DEFAULT_STRATEGY="mirror"     # mirror|clone
ENV_FILE=""
INSTALL_CRON_DEFAULT="false"
CRON_SCHEDULE_DEFAULT="0 2 * * *"

# -------- utils --------
die() { echo "ERROR: $*" >&2; exit 1; }
req() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
json() { jq -r "$1"; }
trim() { local v="$*"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; printf "%s" "$(echo -n "$v" | xargs)"; }

req curl; req jq; req tput || true

# colors (no-op if tput unavailable)
red=$(tput setaf 1 2>/dev/null || echo '')
grn=$(tput setaf 2 2>/dev/null || echo '')
ylw=$(tput setaf 3 2>/dev/null || echo '')
cyn=$(tput setaf 6 2>/dev/null || echo '')
rst=$(tput sgr0 2>/dev/null || echo '')

usage() {
  cat <<USAGE
Usage: $0 [options]
  --github-user USER          GitHub username (owner of repos)
  --forgejo-url URL           Forgejo base URL (https://forgejo.example.com) [REQUIRED]
  --forgejo-user USER_OR_ORG  Forgejo user/org to receive repos [REQUIRED]
  --strategy mirror|clone     Mirror (default) or one-time clone
  --env FILE                  Optional .env (KEY=VALUE)
  --install-cron              Install a cron to run this script
  --cron-schedule "CRON"      Cron expression (default: "0 2 * * *")
  -h, --help                  Show help

Required env (can be in .env):
  GITHUB_TOKEN   GitHub PAT (read for private repos)
  FORGEJO_TOKEN  Forgejo token (create/import repos)

Optional env:
  GITHUB_USER, FORGEJO_URL, FORGEJO_USER, STRATEGY, CRON_SCHEDULE, INSTALL_CRON
USAGE
}

# -------- capture CLI args --------
GH_USER_CLI=""; FJ_URL_CLI=""; FJ_USER_CLI=""
STRATEGY_CLI=""; INSTALL_CRON_CLI=""; CRON_SCHEDULE_CLI=""

while [ $# -gt 0 ]; do
  case "$1" in
    --github-user) GH_USER_CLI="${2:-}"; shift 2 ;;
    --forgejo-url) FJ_URL_CLI="${2:-}"; shift 2 ;;
    --forgejo-user) FJ_USER_CLI="${2:-}"; shift 2 ;;
    --strategy) STRATEGY_CLI="${2:-}"; shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --install-cron) INSTALL_CRON_CLI="true"; shift ;;
    --cron-schedule) CRON_SCHEDULE_CLI="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# -------- .env loader --------
if [ -n "$ENV_FILE" ]; then
  [ -f "$ENV_FILE" ] || die "Env file not found: $ENV_FILE"
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*)
        key="$(trim "${line%%=*}")"
        val="$(trim "${line#*=}")"
        case "$key" in
          GITHUB_TOKEN|FORGEJO_TOKEN|GITHUB_USER|FORGEJO_URL|FORGEJO_USER|STRATEGY|CRON_SCHEDULE|INSTALL_CRON)
            export "$key=$val"
          ;;
        esac
      ;;
    esac
  done < "$ENV_FILE"
fi

# -------- precedence: CLI > .env/env > defaults --------
GH_USER="$(trim "${GH_USER_CLI:-${GITHUB_USER:-}}")"
FJ_URL="$(trim "${FJ_URL_CLI:-${FORGEJO_URL:-}}")"
FJ_USER="$(trim "${FJ_USER_CLI:-${FORGEJO_USER:-}}")"

STRATEGY_IN="$(trim "${STRATEGY_CLI:-${STRATEGY:-$DEFAULT_STRATEGY}}")"
STRATEGY="$(echo "$STRATEGY_IN" | tr '[:upper:]' '[:lower:]')"

INSTALL_CRON_IN="$(trim "${INSTALL_CRON_CLI:-${INSTALL_CRON:-$INSTALL_CRON_DEFAULT}}")"
INSTALL_CRON="$(echo "$INSTALL_CRON_IN" | tr '[:upper:]' '[:lower:]')"

CRON_SCHEDULE="$(trim "${CRON_SCHEDULE_CLI:-${CRON_SCHEDULE:-$CRON_SCHEDULE_DEFAULT}}")"

# -------- prompts (if missing) --------
prompt_secret() {
  local var="$1" msg="$2"
  if [ -z "${!var:-}" ]; then
    printf "%s " "$msg" >&2
    stty -echo
    local val; IFS= read -r val
    stty echo
    printf "\n" >&2
    val="$(trim "$val")"
    [ -n "$val" ] || die "Missing secret: $var"
    export "$var=$val"
  fi
}
prompt_value() {
  local var="$1" msg="$2"
  if [ -z "${!var:-}" ]; then
    read -r -p "$msg " val
    val="$(trim "$val")"
    [ -n "$val" ] || die "Missing value: $var"
    export "$var=$val"
  fi
}

prompt_secret "GITHUB_TOKEN" "GitHub token:"
prompt_secret "FORGEJO_TOKEN" "Forgejo token:"
[ -z "$GH_USER" ] && prompt_value "GH_USER" "${cyn}GitHub username:${rst}"
[ -z "$FJ_URL"  ] && prompt_value "FJ_URL"  "${cyn}Forgejo URL (https://...):${rst}"
[ -z "$FJ_USER" ] && prompt_value "FJ_USER" "${cyn}Forgejo user/org:${rst}"

# -------- validation --------
FJ_URL="${FJ_URL%/}"
case "$FJ_URL" in
  https://*) ;;
  *) die "FORGEJO_URL must start with https://" ;;
esac
case "$STRATEGY" in mirror|clone) ;; *) die "Invalid --strategy (mirror|clone)";; esac
case "$INSTALL_CRON" in true|false) ;; *) INSTALL_CRON="false";; esac

echo "${grn}Config:${rst} GH_USER=$GH_USER, FJ_USER=$FJ_USER, STRATEGY=$STRATEGY"
echo "${ylw}Mode:${rst} non-destructive (no deletes)"

# -------- HTTP helpers --------
ccurl() { curl --fail --show-error -sS "$@"; }  # safe for GET-like
gh_api() {
  ccurl -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}
# POST JSON; capture code and body
post_json_capture() {
  # usage: post_json_capture URL JSON BODY_OUT CODE_OUTVAR
  local url="$1" data="$2" body_out="$3" __code_var="$4"
  local code
  code="$(curl -sS -H "Authorization: token ${FORGEJO_TOKEN}" \
               -H "Content-Type: application/json" \
               -d "$data" "$url" \
               -o "$body_out" -w "%{http_code}")" || true
  printf -v "$__code_var" "%s" "$code"
}
# force-sync a mirror now
sync_mirror_now() {
  local owner="$1" repo="$2" tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -X POST -H "Authorization: token ${FORGEJO_TOKEN}" \
               "${FJ_URL}/api/v1/repos/${owner}/${repo}/mirror-sync" \
               -o "$tmp" -w "%{http_code}")" || true
  rm -f "$tmp"
  if [ "$code" = "200" ]; then echo "sync-ok"; else echo "sync-err(${code})"; fi
}
# GitHub HEAD SHA of a branch
gh_head_sha() {
  local owner_repo="$1" branch="$2"
  gh_api "https://api.github.com/repos/${owner_repo}/branches/${branch}" | jq -r '.commit.sha'
}
# Forgejo HEAD SHA of a branch (supports .commit.id and .commit.sha)
fj_head_sha() {
  local owner="$1" repo="$2" branch="$3"
  curl -sS -H "Authorization: token ${FORGEJO_TOKEN}" \
       "${FJ_URL}/api/v1/repos/${owner}/${repo}/branches/${branch}" \
  | jq -r '.commit.id // .commit.sha // empty'
}
# Forgejo default branch
fj_default_branch() {
  local owner="$1" repo="$2"
  curl -sS -H "Authorization: token ${FORGEJO_TOKEN}" \
       "${FJ_URL}/api/v1/repos/${owner}/${repo}" \
  | jq -r '.default_branch // empty'
}

# -------- fetch repos (owned by GH_USER) --------
echo "${cyn}Fetching GitHub repositories for ${GH_USER}...${rst}"
page=1
all_repos='[]'
while :; do
  resp="$(gh_api "https://api.github.com/user/repos?visibility=all&affiliation=owner&per_page=100&page=${page}")"
  filtered="$(echo "$resp" | jq --arg GU "$GH_USER" '[.[] | select(.owner.login == $GU)]')"
  count="$(echo "$filtered" | jq 'length')"
  [ "$count" -eq 0 ] && break
  all_repos="$(jq -s 'add' <(echo "$all_repos") <(echo "$filtered"))"
  [ "$count" -lt 100 ] && break
  page=$((page+1))
done

repo_count="$(echo "$all_repos" | jq 'length')"
[ "$repo_count" -gt 0 ] || { echo "No repositories found for $GH_USER."; exit 0; }
echo "${grn}Found ${repo_count} repositories.${rst}"

# -------- migrate each (no subshell) --------
while IFS= read -r repo; do
  name="$(echo "$repo" | json '.name')"
  full_name="$(echo "$repo" | json '.full_name')"
  is_private="$(echo "$repo" | json '.private')"
  clone_url="$(echo "$repo" | json '.clone_url')"    # https://github.com/OWNER/REPO.git
  def_branch="$(echo "$repo" | json '.default_branch')"
  mirror=true; [ "$STRATEGY" = "clone" ] && mirror=false

  payload="$(jq -n \
    --arg addr "$clone_url" \
    --arg owner "$FJ_USER" \
    --arg repo  "$name" \
    --arg user  "$GH_USER" \
    --arg pass  "$GITHUB_TOKEN" \
    --argjson mirror "$mirror" \
    --argjson private "$is_private" '
    {
      clone_addr: $addr,
      repo_owner: $owner,
      repo_name:  $repo,
      mirror:     $mirror,
      private:    $private,
      auth_username: $user,
      auth_password: $pass
    }')"

  printf "%s" "${cyn}Migrating ${full_name} -> ${FJ_URL}/${FJ_USER}/${name} (${STRATEGY})...${rst} "

  body_file="$(mktemp)"; http_code=""
  post_json_capture "${FJ_URL}/api/v1/repos/migrate" "$payload" "$body_file" http_code
  msg="$(jq -r '.message // empty' "$body_file" 2>/dev/null || true)"

  case "$http_code" in
    201)
      echo "${grn}ok${rst}"
      ;;
    409)
      # Already present; in mirror mode, force a sync now to ensure up-to-date
      if [ "$STRATEGY" = "mirror" ]; then
        res="$(sync_mirror_now "${FJ_USER}" "${name}")"
        if [[ "$res" == sync-ok* ]]; then
          echo "${ylw}exists, synced${rst}"
        else
          echo "${ylw}exists${rst} (${res})"
        fi
      else
        echo "${ylw}exists${rst}"
      fi
      ;;
    *)
      if [ -n "$msg" ]; then
        echo "${red}error (${http_code}): ${msg}${rst}"
      else
        echo "${red}error (${http_code})${rst}"
      fi
      ;;
  esac
  rm -f "$body_file"

  # ----- verification: ensure Forgejo default-branch HEAD equals GitHub -----
  # Start from GitHub's default branch; if Forgejo lacks it, fall back to Forgejo default.
  if [ -n "$def_branch" ] && [ "$def_branch" != "null" ]; then
    gh_sha="$(gh_head_sha "$full_name" "$def_branch" || true)"
    fj_sha="$(fj_head_sha "$FJ_USER" "$name" "$def_branch" || true)"

    # If Forgejo doesn't have that branch, fall back to Forgejo default
    if [ -z "$fj_sha" ] || [ "$fj_sha" = "null" ]; then
      fj_def="$(fj_default_branch "$FJ_USER" "$name" || true)"
      if [ -n "$fj_def" ] && [ "$fj_def" != "null" ] && [ "$fj_def" != "$def_branch" ]; then
        fj_sha="$(fj_head_sha "$FJ_USER" "$name" "$fj_def" || true)"
        gh_sha_alt="$(gh_head_sha "$full_name" "$fj_def" || true)"
        if [ -n "$gh_sha_alt" ] && [ "$gh_sha_alt" != "null" ] && [ -n "$fj_sha" ] && [ "$fj_sha" != "null" ]; then
          if [ "$gh_sha_alt" = "$fj_sha" ]; then
            echo "  verified (${fj_def} @ ${fj_sha})"
          else
            echo "  mismatch:${gh_sha_alt}!=${fj_sha} (${fj_def})"
          fi
          continue
        fi
      fi
    fi

    if [ -n "$gh_sha" ] && [ "$gh_sha" != "null" ] && [ -n "$fj_sha" ] && [ "$fj_sha" != "null" ]; then
      if [ "$gh_sha" = "$fj_sha" ]; then
        echo "  verified (${def_branch} @ ${gh_sha})"
      else
        echo "  mismatch:${gh_sha}!=${fj_sha} (${def_branch})"
      fi
    else
      echo "  verify-skip (branch:${def_branch})"
    fi
  else
    echo "  verify-skip (no default_branch)"
  fi
done < <(echo "$all_repos" | jq -c '.[]')

# -------- optional cron --------
if [ "$INSTALL_CRON" = "true" ]; then
  SCRIPT_PATH="$(command -v "$0" || true)"; [ -n "$SCRIPT_PATH" ] || SCRIPT_PATH="$0"
  SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH" 2>/dev/null || realpath "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")"

  CRON_LINE="${CRON_SCHEDULE} ${SCRIPT_PATH} --github-user ${GH_USER} --forgejo-url ${FJ_URL} --forgejo-user ${FJ_USER} --strategy ${STRATEGY}${ENV_FILE:+ --env ${ENV_FILE}} >/dev/null 2>&1"

  current="$(crontab -l 2>/dev/null || true)"
  if echo "$current" | grep -Fq "$SCRIPT_PATH"; then
    echo "${ylw}Cron already present.${rst}"
  else
    { printf "%s\n" "$current"; printf "%s\n" "$CRON_LINE"; } | crontab -
    echo "${grn}Cron installed:${rst} $CRON_LINE"
  fi
fi
