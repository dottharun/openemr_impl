#!/usr/bin/env bash
# Destroys ./.db and rebuilds an empty local postgres cluster + database.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ASSUME_YES=0
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && ASSUME_YES=1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Maps a required binary to the brew formula that provides it.
brew_formula_for() {
  case "$1" in
    direnv) echo direnv ;;
    initdb | pg_ctl | createdb | psql | pg_isready) echo postgresql@18 ;;
    *) echo "$1" ;;
  esac
}

check_prereqs() {
  local missing=() formulas=() bin
  for bin in direnv initdb pg_ctl createdb psql pg_isready; do
    command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
  done

  if ((${#missing[@]})); then
    printf 'missing required commands: %s\n\n' "${missing[*]}" >&2
    for bin in "${missing[@]}"; do formulas+=("$(brew_formula_for "$bin")"); done
    # shellcheck disable=SC2207
    formulas=($(printf '%s\n' "${formulas[@]}" | sort -u))
    printf 'install them with:\n  brew install %s\n' "${formulas[*]}" >&2
    printf '\nthen ensure the postgres binaries are on PATH, e.g.\n'  >&2
    printf '  echo '\''export PATH="/opt/homebrew/opt/postgresql@18/bin:$PATH"'\'' >> ~/.zshrc\n' >&2
    exit 1
  fi

  [[ -f "$REPO_ROOT/.envrc" ]] || die ".envrc not found at $REPO_ROOT; see README"
}

# Requires the .envrc vars; refuses to guess, so a stale global PGDATA
# (e.g. ~/pgdata from .zshrc) can never be the deletion target.
check_env() {
  local unset_vars=() var
  for var in PGDATA PGHOST PGPORT PGUSER PGDATABASE; do
    [[ -n "${!var:-}" ]] || unset_vars+=("$var")
  done
  if ((${#unset_vars[@]})); then
    printf 'unset env vars: %s\n\n' "${unset_vars[*]}" >&2
    printf 'load them from .envrc:\n  cd %s && direnv allow\n' "$REPO_ROOT" >&2
    printf 'or for this shell only:\n  set -a; source %s/.envrc; set +a\n' "$REPO_ROOT" >&2
    exit 1
  fi

  local want="$REPO_ROOT/.db"
  [[ "$PGDATA" == "$want" ]] || die "PGDATA is '$PGDATA', expected '$want' (direnv not loaded for this repo?)"
  [[ "$PGHOST" == "$want" ]] || die "PGHOST is '$PGHOST', expected '$want'"
  [[ "$PGPORT" =~ ^[0-9]+$ ]] || die "PGPORT is not numeric: '$PGPORT'"
  [[ "$PGPORT" != 5432 ]] || die "PGPORT 5432 collides with the default cluster; use 5433"
}

confirm() {
  ((ASSUME_YES)) && return 0
  printf 'This DELETES %s and all data in it.\n' "$PGDATA"
  read -r -p 'Continue? [y/N] ' reply
  [[ "$reply" == y || "$reply" == Y ]] || die "aborted"
}

stop_existing() {
  if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
    printf 'stopping running cluster...\n'
    pg_ctl -D "$PGDATA" -m immediate stop >/dev/null
  fi
}

main() {
  check_prereqs
  check_env
  confirm
  stop_existing

  printf 'removing %s\n' "$PGDATA"
  rm -rf -- "$PGDATA"

  printf 'initdb...\n'
  initdb -U "$PGUSER" -A trust >/dev/null

  printf 'starting server on port %s\n' "$PGPORT"
  pg_ctl -o "-p $PGPORT -k $PGDATA" -l "$PGDATA/server.log" start >/dev/null

  printf 'creating database %s\n' "$PGDATABASE"
  createdb "$PGDATABASE"

  psql -c "select current_database(), current_setting('port'), current_setting('data_directory')"
  printf '\nready. shell: psql   stop: pg_ctl stop\n'
}

main "$@"
