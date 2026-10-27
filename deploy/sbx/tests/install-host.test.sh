#!/usr/bin/env bash
# Tests for deploy/sbx/install-host.sh with systemctl and journalctl mocked: what it writes, that
# two workers never share a slice, jail or workspace root (SBX0 §8.2), that --uninstall leaves
# workspace data alone, and that moca-egress is installed and wired beside the worker (#623).
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MOCK_LOG="$TMP/mock.log"
mkdir -p "$TMP/bin"
fail() { echo "FAIL: $*" >&2; [[ -f "$TMP/out" ]] && sed 's/^/  | /' "$TMP/out" >&2; exit 1; }
pass() { echo "ok - $*"; }

cat >"$TMP/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_LOG"
[[ "$1" == show ]] && { echo "InvocationID=abc123"; exit 0; }
[[ "$1" == is-active ]] && exit "${MOCK_ACTIVE_RC:-0}"
exit 0
MOCK
# journalctl: MOCK_JOURNAL_DIR holds the whole journal as the Nth look sees it (files 1, 2, ...;
# the last one keeps being served), so a test can script the worker's log growing between looks.
cat >"$TMP/bin/journalctl" <<'MOCK'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >>"$MOCK_LOG"
if [[ -n "${MOCK_JOURNAL_DIR:-}" ]]; then
  n=$(($(cat "$MOCK_JOURNAL_DIR/count" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$MOCK_JOURNAL_DIR/count"
  while ((n > 1)) && [[ ! -f "$MOCK_JOURNAL_DIR/$n" ]]; do n=$((n - 1)); done
  cat "$MOCK_JOURNAL_DIR/$n"
  exit 0
fi
[[ -n "${MOCK_NO_ATTACH:-}" ]] || echo 'microvm-worker: attached, serving execs'
MOCK
chmod +x "$TMP/bin/systemctl" "$TMP/bin/journalctl"
export PATH="$TMP/bin:$PATH" SBX_UNIT_DIR="$TMP/units" SBX_ENV_DIR="$TMP/etc" SBX_SRV="$TMP/srv"
export SBX_SKIP_ROOT_CHECK=1 SBX_ATTACH_TIMEOUT=2 SBX_ATTACH_SETTLE=1
INSTALL="$SRC/deploy/sbx/install-host.sh"
mkdir -p "$SBX_SRV/snapshots/default" "$SBX_SRV/snapshots/py312"
# moca-egress is the operator's binary, and the worker waits for its control socket: fake both, so
# every install below passes the binary check and the socket wait. A socket FILE is all `-S` tests.
export SBX_BIN_DIR="$TMP/usrbin" MOCA_EGRESS_SOCKET="$TMP/run/control.sock" MOCA_EGRESS_READY_TIMEOUT=2
mkdir -p "$SBX_BIN_DIR" "$TMP/run"
fake_egress() { : >"$SBX_BIN_DIR/moca-egress"; chmod +x "$SBX_BIN_DIR/moca-egress"; }
fake_socket() { rm -f "$MOCA_EGRESS_SOCKET"; python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$MOCA_EGRESS_SOCKET"; }
fake_egress
fake_socket

bundle() { # bundle ID [EXTRA_LINES]: a worker bundle as setup.sh writes it, plus EXTRA_LINES
  local d="$TMP/bundles/$1"
  mkdir -p "$d"
  printf 'RELAY_ADDR=sbx-attach.apps.example.invalid:443\nRELAY_TLS=true\nSANDBOX_ID=%s\nSANDBOX_TOKEN=%s\n%s' \
    "$1" "$(printf '%064d' 7)" "${2-$'SH_WORKSPACE_IDLE=216h\nSH_WORKSPACE_IMAGE_MB=2048\n'}" >"$d/worker.env"
  printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' >"$d/relay-ca.crt"
  echo "$d"
}

# Refusals
! bash "$INSTALL" "$(bundle sbx_default)" >"$TMP/out" 2>&1 || fail 'installed without --snapshot'
! bash "$INSTALL" "$(bundle sbx_default)" --snapshot missing >"$TMP/out" 2>&1 || fail 'installed a missing snapshot'
grep -q 'no snapshot' "$TMP/out" || fail 'missing-snapshot refusal does not say why'
b="$(bundle sbx_bad)"; sed -i.bak 's/^SANDBOX_TOKEN=.*/SANDBOX_TOKEN=short/' "$b/worker.env"
! bash "$INSTALL" "$b" --snapshot default >"$TMP/out" 2>&1 || fail 'accepted a malformed token'
! grep -q 'short' "$TMP/out" || fail 'the refusal printed the token value'
for extra in 'SH_WORKSPACE_IDLE=9d' 'SH_WORKSPACE_IDLE=0h' 'SH_WORKSPACE_IMAGE_MB=2g' 'SH_WORKSPACE_IMAGE_MB=0'; do
  : >"$MOCK_LOG"
  # The bad line last: env_value takes the last one, so it overrides the valid idle before it.
  ! bash "$INSTALL" "$(bundle sbx_bad $'SH_WORKSPACE_IDLE=216h\n'"$extra"$'\n')" --snapshot default >"$TMP/out" 2>&1 || fail "accepted $extra"
  grep -q "${extra%%=*} in" "$TMP/out" || fail "the $extra refusal does not name the setting"
  ! grep -q systemctl "$MOCK_LOG" || fail "touched systemd before refusing $extra"
done
# A bundle with no SH_WORKSPACE_IDLE predates 1b's rule (idle = lifetime + 2 days): refused, not defaulted.
: >"$MOCK_LOG"
! bash "$INSTALL" "$(bundle sbx_bad $'SH_WORKSPACE_IMAGE_MB=2048\n')" --snapshot default >"$TMP/out" 2>&1 || fail 'accepted a bundle with no SH_WORKSPACE_IDLE'
grep -q 'SH_WORKSPACE_IDLE' "$TMP/out" && grep -q 'deploy/sbx/setup.sh' "$TMP/out" ||
  fail 'the missing-idle refusal does not name SH_WORKSPACE_IDLE and setup.sh'
! grep -q systemctl "$MOCK_LOG" || fail 'touched systemd before refusing a bundle with no SH_WORKSPACE_IDLE'
pass 'refuses a missing snapshot, a missing --snapshot, a malformed token (without printing it), a missing or bad idle, a bad image size'

bash "$INSTALL" "$(bundle sbx_default)" --snapshot default >"$TMP/out" 2>&1 || fail 'install sbx_default'
bash "$INSTALL" "$(bundle sbx_py312 $'SH_WORKSPACE_IDLE=240h\nSH_WORKSPACE_IMAGE_MB=4096\n')" --snapshot py312 --budget-mb 8192 \
  >"$TMP/out" 2>&1 || fail 'install sbx_py312'

A="$SBX_ENV_DIR/workers/sbx_default.env" B="$SBX_ENV_DIR/workers/sbx_py312.env"
for f in "$A" "$B"; do
  [[ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" == 600 ]] || fail "$f is not 0600"
  grep -qx 'RELAY_TLS=true' "$f" || fail "$f: RELAY_TLS"
done
grep -qx 'SH_WORKSPACE_IDLE=216h' "$A" || fail "$A: SH_WORKSPACE_IDLE is not the bundle's 216h"
grep -qx 'SH_WORKSPACE_IMAGE_MB=2048' "$A" || fail "$A: SH_WORKSPACE_IMAGE_MB is not the bundle's 2048"
grep -qx 'SH_WORKSPACE_IDLE=240h' "$B" || fail "$B: SH_WORKSPACE_IDLE is not the bundle's 240h"
grep -qx 'SH_WORKSPACE_IMAGE_MB=4096' "$B" || fail "$B: SH_WORKSPACE_IMAGE_MB is not the bundle's 4096"
[[ "$(grep -c '^SH_WORKSPACE_IDLE=' "$B")" == 1 ]] || fail "$B: SH_WORKSPACE_IDLE written twice"
grep -qx 'SH_SNAPSHOT_IMAGE=py312' "$B" || fail 'snapshot not set'
grep -qx 'SH_MAX_COMMITTED_MB=8192' "$B" || fail 'budget not set'
for k in SH_PARENT_CGROUP SH_CHROOT_BASE SH_WORKSPACE_ROOT; do
  va="$(grep "^$k=" "$A" | cut -d= -f2-)" vb="$(grep "^$k=" "$B" | cut -d= -f2-)"
  [[ -n "$va" && "$va" != "$vb" ]] || fail "$k is shared between workers ($va)"
done
grep -qx 'SH_PARENT_CGROUP=sbx.slice/sbx-sbx_py312.slice' "$B" || fail 'parent cgroup is not the worker slice'
pass "two workers: 0600 env files, own slice, jail and workspace root, the bundle's idle and image size"

# A bundle without SH_WORKSPACE_IMAGE_MB gets microvm-worker's default, 2048 MiB.
bash "$INSTALL" "$(bundle sbx_old $'SH_WORKSPACE_IDLE=216h\n')" --snapshot default >"$TMP/out" 2>&1 || fail 'install a bundle with no image size'
grep -qx 'SH_WORKSPACE_IMAGE_MB=2048' "$SBX_ENV_DIR/workers/sbx_old.env" || fail 'SH_WORKSPACE_IMAGE_MB is not the 2048 default'
bash "$INSTALL" --uninstall sbx_old >"$TMP/out" 2>&1 || fail 'uninstall sbx_old'
pass 'a bundle without the image size gets the 2048 MiB default'

[[ -f "$SBX_UNIT_DIR/sbx-worker@.service" && -f "$SBX_UNIT_DIR/sbx.slice" ]] || fail 'template unit or parent slice missing'
[[ -f "$SBX_UNIT_DIR/sbx-sbx_py312.slice" ]] || fail 'per-worker slice missing'
grep -qx 'Slice=sbx-%i.slice' "$SBX_UNIT_DIR/sbx-worker@.service" || fail 'unit is not in its worker slice'
grep -qx 'AssertPathExists=/dev/kvm' "$SBX_UNIT_DIR/sbx-worker@.service" || fail 'unit lacks AssertPathExists=/dev/kvm'
grep -qx 'StartLimitIntervalSec=300' "$SBX_UNIT_DIR/sbx-worker@.service" || fail 'unit lacks StartLimitIntervalSec=300'
grep -qx 'StartLimitBurst=5' "$SBX_UNIT_DIR/sbx-worker@.service" || fail 'unit lacks StartLimitBurst=5'
grep -qx 'systemctl enable sbx-worker@sbx_py312.service' "$MOCK_LOG" || fail 'unit not enabled'
! grep -q 'systemctl enable --now' "$MOCK_LOG" || fail 'enable --now plus restart starts a fresh unit twice'
[[ "$(grep -cx 'systemctl restart sbx-worker@sbx_py312.service' "$MOCK_LOG")" == 1 ]] || fail 'the worker is not restarted exactly once'
grep -q 'sbx-worker@sbx_py312' "$SBX_ENV_DIR/manifest" || fail 'manifest does not record the worker'
pass 'installs the template unit, the slices, enables and restarts the worker once and records it'

# A worker that crash-looped into `failed` refuses a restart until reset: reset-failed comes first.
grep -A1 -x 'systemctl reset-failed sbx-worker@sbx_py312.service' "$MOCK_LOG" | grep -qx 'systemctl restart sbx-worker@sbx_py312.service' ||
  fail 'reset-failed does not run right before the restart (a failed unit would refuse it)'
pass 'clears a failed state (reset-failed) right before restarting the worker'

: >"$MOCK_LOG"
! MOCK_NO_ATTACH=1 bash "$INSTALL" "$(bundle sbx_default)" --snapshot default >"$TMP/out" 2>&1 || fail 'reported success with no attach'
grep -q 'journalctl -u sbx-worker@sbx_default _SYSTEMD_INVOCATION_ID=abc123' "$TMP/out" || fail 'no-attach failure does not name the journal'
grep -q 'about a minute to reach the relay' "$TMP/out" || fail 'the timeout does not mention the Secret sync delay'
pass 'fails, naming the journal and the token-sync delay, when the worker never logs an attach'

# The attach rule of setup-microvm.sh: an earlier refusal does not fail the wait, a later attach that
# holds succeeds, and an attach followed by `stream ended` with no re-attach fails.
ATTACHED='microvm-worker: attached, serving execs'
ENDED='microvm-worker: stream ended (rpc error: code = Unauthenticated desc = bad token); reconnecting in 612ms'
journal() { # journal DIR LOOK... -- each LOOK is the full journal at that look, lines separated by |
  local d="$1" i=0 look
  rm -rf "$d" && mkdir -p "$d" && shift
  for look in "$@"; do i=$((i + 1)); printf '%s\n' "$look" | tr '|' '\n' >"$d/$i"; done
}
journal "$TMP/j1" "$ATTACHED" "$ATTACHED|$ENDED" "$ATTACHED|$ENDED|$ATTACHED"
MOCK_JOURNAL_DIR="$TMP/j1" SBX_ATTACH_TIMEOUT=10 bash "$INSTALL" "$(bundle sbx_default)" --snapshot default >"$TMP/out" 2>&1 ||
  fail 'a refusal followed by an attach that holds was reported as a failure'
grep -q 'sbx-worker@sbx_default attached to the relay' "$TMP/out" || fail 'no attached message'
pass 'an attach that holds after an earlier refusal (Secret not yet synced) succeeds'

journal "$TMP/j2" "$ATTACHED" "$ATTACHED|$ENDED"
! MOCK_JOURNAL_DIR="$TMP/j2" SBX_ATTACH_TIMEOUT=3 bash "$INSTALL" "$(bundle sbx_default)" --snapshot default >"$TMP/out" 2>&1 ||
  fail 'an attach followed by stream ended and no re-attach was reported as attached'
grep -q 'journalctl -u sbx-worker@sbx_default _SYSTEMD_INVOCATION_ID=abc123' "$TMP/out" || fail 'the failure does not name the journal'
pass 'an attach that ends and never comes back fails, naming the journal'

: >"$MOCK_LOG"
! SBX_ATTACH_SETTLE=0 bash "$INSTALL" "$(bundle sbx_default)" --snapshot default >"$TMP/out" 2>&1 || fail 'accepted SBX_ATTACH_SETTLE=0'
grep -q 'SBX_ATTACH_SETTLE' "$TMP/out" || fail 'the SBX_ATTACH_SETTLE refusal does not say why'
! grep -q 'systemctl' "$MOCK_LOG" || fail 'touched systemd before refusing SBX_ATTACH_SETTLE=0'
pass 'refuses SBX_ATTACH_SETTLE below 1 before touching anything'

: >"$MOCK_LOG"
mkdir -p "$SBX_SRV/workspaces/sbx_py312/sbx-keepme"
bash "$INSTALL" --uninstall sbx_py312 >"$TMP/out" 2>&1 || fail 'uninstall'
grep -q 'systemctl disable --now sbx-worker@sbx_py312.service' "$MOCK_LOG" || fail 'unit not disabled'
grep -A1 'systemctl disable --now sbx-worker@sbx_py312.service' "$MOCK_LOG" | grep -qx 'systemctl stop sbx-sbx_py312.slice' ||
  fail 'the worker slice is not stopped after the unit is disabled (VMs left by a timed-out stop stay resident)'
[[ ! -f "$B" && ! -f "$SBX_UNIT_DIR/sbx-sbx_py312.slice" ]] || fail 'env file or slice kept'
[[ -d "$SBX_SRV/workspaces/sbx_py312/sbx-keepme" ]] || fail 'uninstall removed workspace data'
grep -q "left in place: $SBX_SRV/workspaces/sbx_py312" "$TMP/out" || fail 'uninstall does not say what it kept'
pass '--uninstall stops and removes the worker, keeps (and names) its workspace data'

# Uninstall matches the worker's manifest lines exactly: removing `a` keeps `ba`'s.
bash "$INSTALL" "$(bundle a)" --snapshot default >"$TMP/out" 2>&1 || fail 'install a'
bash "$INSTALL" "$(bundle ba)" --snapshot default >"$TMP/out" 2>&1 || fail 'install ba'
bash "$INSTALL" --uninstall a >"$TMP/out" 2>&1 || fail 'uninstall a'
M="$SBX_ENV_DIR/manifest"
! grep -q 'sbx-worker@a \|/a-relay-ca\.crt' "$M" || fail "a's manifest lines kept: $(cat "$M")"
grep -qx "worker sbx-worker@ba $SBX_ENV_DIR/workers/ba.env $SBX_UNIT_DIR/sbx-ba.slice" "$M" || fail "uninstalling a dropped ba's worker line: $(cat "$M")"
grep -qx "file $SBX_ENV_DIR/workers/ba-relay-ca.crt" "$M" || fail "uninstalling a dropped ba's CA line: $(cat "$M")"
[[ -f "$SBX_ENV_DIR/workers/ba-relay-ca.crt" && -f "$SBX_ENV_DIR/workers/ba.env" ]] || fail "uninstalling a removed ba's files"
pass "--uninstall a keeps worker ba's manifest lines and files (fixed-string match)"

# The shared units stay while any worker is left, and go with the last one (spec §8.2's undo).
[[ -f "$SBX_UNIT_DIR/sbx-worker@.service" && -f "$SBX_UNIT_DIR/sbx.slice" ]] || fail 'shared units removed while workers remain'
grep -qx "unit $SBX_UNIT_DIR/sbx.slice" "$M" || fail 'the manifest lost the shared units while workers remain'
bash "$INSTALL" --uninstall ba >"$TMP/out" 2>&1 || fail 'uninstall ba'
bash "$INSTALL" --uninstall sbx_default >"$TMP/out" 2>&1 || fail 'uninstall sbx_default (no worker after it)'
[[ ! -e "$SBX_UNIT_DIR/sbx-worker@.service" && ! -e "$SBX_UNIT_DIR/sbx.slice" ]] || fail 'shared units kept after the last worker'
grep -q "removed $SBX_UNIT_DIR/sbx-worker@.service" "$TMP/out" && grep -q "removed $SBX_UNIT_DIR/sbx.slice" "$TMP/out" ||
  fail 'the last uninstall does not say it removed the shared units'
[[ ! -s "$M" ]] || fail "the manifest still lists something after the last worker: $(cat "$M")"
[[ -d "$SBX_SRV/workspaces/sbx_default" ]] || fail 'the last uninstall removed workspace data'
# daemon-reload runs after the unit files are gone, so systemd forgets them.
bash "$INSTALL" "$(bundle sbx_default)" --snapshot default >"$TMP/out" 2>&1 || fail 'reinstall sbx_default'
: >"$MOCK_LOG"
bash "$INSTALL" --uninstall sbx_default >"$TMP/out" 2>&1 || fail 'uninstall sbx_default again'
[[ "$(tail -1 "$MOCK_LOG")" == 'systemctl daemon-reload' ]] || fail "daemon-reload is not the last step of the undo: $(tail -1 "$MOCK_LOG")"
[[ ! -e "$SBX_UNIT_DIR/sbx-worker@.service" ]] || fail 'reinstall + uninstall left the template unit'
pass '--uninstall of the last worker removes the shared unit and sbx.slice, then daemon-reloads; workspace data stays'

# The janitor (spec §8.3): --janitor BUNDLE_DIR installs the script, its env, its token and the two
# units, enables the timer and records all of it as its own manifest kind; --uninstall-janitor
# reverses it; uninstalling the last worker leaves it alone.
export SBX_LIBEXEC_DIR="$TMP/libexec"
JTOKEN="$(printf 'k%.0s' {1..64})"
jbundle() { # jbundle [ENV_TEXT]: a janitor bundle as setup.sh writes it
  local d="$TMP/jbundle"
  rm -rf "$d" && mkdir -p "$d"
  printf '%s' "${1-$'SBX_API_URL=https://sbx-api.apps.example.invalid\nSBX_JANITOR_AGE=3900\n'}" >"$d/janitor.env"
  printf '%s' "$JTOKEN" >"$d/janitor.token"
  echo "$d"
}
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
M="$SBX_ENV_DIR/manifest"

# Refusals, before anything is written or systemd is touched.
for bad in 'SBX_API_URL=http://sbx-api.example.invalid' 'SBX_API_URL=https://x/../y' 'SBX_JANITOR_AGE=1h' \
  $'SBX_API_URL=https://sbx-api.example.invalid\nSBX_JANITOR_AGE=03600' $'SBX_API_URL=https://sbx-api.example.invalid\nSBX_JANITOR_AGE=0900' \
  $'SBX_API_URL=https://sbx-api.example.invalid\nSBX_JANITOR_AGE=60' $'SBX_API_URL=https://sbx-api.example.invalid\nSBX_JANITOR_AGE=0' \
  $'SBX_API_URL=https://sbx-api.example.invalid\nSBX_JANITOR_AGE=3900\nSBX_JANITOR_TOKEN=leaked'; do
  : >"$MOCK_LOG"
  ! bash "$INSTALL" --janitor "$(jbundle "$bad"$'\n')" >"$TMP/out" 2>&1 || fail "installed a janitor bundle with: $bad"
  ! grep -q systemctl "$MOCK_LOG" || fail "touched systemd before refusing: $bad"
  [[ ! -e "$SBX_LIBEXEC_DIR/sbx-janitor.sh" ]] || fail "wrote the janitor before refusing: $bad"
done
d="$(jbundle)"; printf 'tooShortSecret' >"$d/janitor.token"
! bash "$INSTALL" --janitor "$d" >"$TMP/out" 2>&1 || fail 'installed a token under 32 characters'
! grep -q tooShortSecret "$TMP/out" || fail 'the short-token refusal printed the token'
d="$(jbundle)"; printf 'not a cert' >"$d/api-ca.crt"
! bash "$INSTALL" --janitor "$d" >"$TMP/out" 2>&1 || fail 'installed an api-ca.crt that holds no certificate'
mkdir -p "$TMP/nojq"
for t in bash cat grep sed install mkdir chmod rm mv id tail cut touch dirname; do ln -sf "$(command -v "$t")" "$TMP/nojq/$t"; done
ln -sf "$TMP/bin/systemctl" "$TMP/nojq/systemctl"
! PATH="$TMP/nojq" "$TMP/nojq/bash" "$INSTALL" --janitor "$(jbundle)" >"$TMP/out" 2>&1 || fail 'installed the janitor on a host without jq and curl'
grep -q 'needs jq' "$TMP/out" || fail 'the missing-jq refusal does not say so'
pass '--janitor refuses a bad URL, a wait with a leading zero or of 60 s or less, a token in janitor.env, a short token, a bad CA, and a host without jq/curl'

: >"$MOCK_LOG"
d="$(jbundle)"
printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' >"$d/api-ca.crt"
bash "$INSTALL" --janitor "$d" >"$TMP/out" 2>&1 || fail 'install the janitor'
JE="$SBX_ENV_DIR/janitor.env" JT="$SBX_ENV_DIR/janitor.token" JS="$SBX_LIBEXEC_DIR/sbx-janitor.sh"
[[ "$(mode "$JE")" == 600 && "$(mode "$JT")" == 600 && "$(mode "$JS")" == 755 ]] ||
  fail "modes: env $(mode "$JE"), token $(mode "$JT"), script $(mode "$JS")"
[[ "$(cat "$JT")" == "$JTOKEN" ]] || fail 'janitor.token is not the bundle token'
! grep -qF "$JTOKEN" "$JE" || fail 'the token is in janitor.env'
grep -qx 'SBX_API_URL=https://sbx-api.apps.example.invalid' "$JE" && grep -qx 'SBX_JANITOR_AGE=3900' "$JE" || fail "janitor.env: $(cat "$JE")"
grep -qx "SBX_API_CA_FILE=$SBX_ENV_DIR/janitor-api-ca.crt" "$JE" || fail 'janitor.env does not point at the installed API CA'
[[ -f "$SBX_ENV_DIR/janitor-api-ca.crt" ]] || fail 'the API CA was not installed'
cmp -s "$JS" "$SRC/deploy/sbx/janitor.sh" || fail 'the installed script is not deploy/sbx/janitor.sh'
S="$SBX_UNIT_DIR/sbx-janitor.service"
grep -qx "EnvironmentFile=$SBX_ENV_DIR/janitor.env" "$S" || fail 'the service does not read the installed janitor.env'
grep -qx "Environment=SBX_JANITOR_TOKEN_FILE=$SBX_ENV_DIR/janitor.token" "$S" || fail 'the service does not name the installed token'
grep -qx "Environment=SBX_ENV_DIR=$SBX_ENV_DIR" "$S" && grep -qx "Environment=SBX_SRV=$SBX_SRV" "$S" || fail 'the service does not name the env dir and srv'
grep -qx "ReadWritePaths=-$SBX_SRV/workspaces" "$S" || fail 'the service cannot write the workspace roots'
grep -qx "ExecStart=$JS" "$S" || fail 'the service does not run the installed script'
! grep -q '/etc/sbx\|/srv/sbx\|/usr/local/libexec' "$S" || fail "the service keeps a default path: $(grep -n '/etc/sbx\|/srv/sbx\|/usr/local/libexec' "$S")"
cmp -s "$SBX_UNIT_DIR/sbx-janitor.timer" "$SRC/deploy/sbx/sbx-janitor.timer" || fail 'the timer is not deploy/sbx/sbx-janitor.timer'
grep -A1 -x 'systemctl daemon-reload' "$MOCK_LOG" | grep -qx 'systemctl enable --now sbx-janitor.timer' || fail "the timer is not enabled after a daemon-reload: $(cat "$MOCK_LOG")"
! grep -qF "$JTOKEN" "$MOCK_LOG" "$TMP/out" || fail 'the token reached systemctl argv or the log'
for f in "$JE" "$JT" "$JS" "$S" "$SBX_UNIT_DIR/sbx-janitor.timer" "$SBX_ENV_DIR/janitor-api-ca.crt"; do
  grep -qx "janitor $f" "$M" || fail "the manifest does not record janitor $f: $(cat "$M")"
done
! grep -q '^unit .*janitor' "$M" || fail 'the janitor is recorded as a shared unit (the last worker uninstall would remove it)'
pass '--janitor installs the 0755 script, 0600 env and token, the CA and both units, enables the timer, records each as janitor'

# Re-run without a CA: the CA and its env line go; nothing else changes.
bash "$INSTALL" --janitor "$(jbundle)" >"$TMP/out" 2>&1 || fail 're-install the janitor without a CA'
! grep -q SBX_API_CA_FILE "$JE" && [[ ! -e "$SBX_ENV_DIR/janitor-api-ca.crt" ]] || fail 'a re-install without a CA keeps it'
! grep -qx "janitor $SBX_ENV_DIR/janitor-api-ca.crt" "$M" || fail 'the manifest keeps the dropped CA'
[[ "$(grep -c "^janitor $JE\$" "$M")" == 1 ]] || fail 'a re-install records janitor.env twice'
pass 'a re-install without api-ca.crt drops it and records nothing twice'

# The installed janitor runs from its unit's environment: SBX_ENV_DIR's env file and token.
mkdir -p "$TMP/jbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q\necho %q\n' "$TMP/jcurl.log" '{"live":[],"terminated":[]}' >"$TMP/jbin/curl"
chmod +x "$TMP/jbin/curl"
(
  set -a
  # shellcheck disable=SC1090 # the installed env file
  . "$JE"
  set +a
  SBX_JANITOR_TOKEN_FILE="$JT" PATH="$TMP/jbin:$PATH" "$JS"
) >"$TMP/out" 2>&1 || fail 'the installed janitor does not run from its env file'
grep -q '"janitor":"summary"' "$TMP/out" || fail 'the installed janitor printed no summary'
pass 'the installed janitor runs from the installed env file and token'

# Uninstalling the last worker leaves the janitor; --uninstall-janitor removes exactly it.
bash "$INSTALL" "$(bundle sbx_default)" --snapshot default >"$TMP/out" 2>&1 || fail 'install sbx_default beside the janitor'
bash "$INSTALL" --uninstall sbx_default >"$TMP/out" 2>&1 || fail 'uninstall the last worker'
[[ ! -e "$SBX_UNIT_DIR/sbx-worker@.service" ]] || fail 'the last worker uninstall left the template unit'
[[ -f "$S" && -f "$SBX_UNIT_DIR/sbx-janitor.timer" && -f "$JS" && -f "$JE" && -f "$JT" ]] || fail 'the last worker uninstall removed the janitor'
grep -q '^janitor ' "$M" || fail 'the last worker uninstall dropped the janitor from the manifest'
bash "$INSTALL" "$(bundle sbx_py312)" --snapshot py312 >"$TMP/out" 2>&1 || fail 'install sbx_py312 beside the janitor'
: >"$MOCK_LOG"
bash "$INSTALL" --uninstall-janitor >"$TMP/out" 2>&1 || fail '--uninstall-janitor'
[[ -f "$SBX_ENV_DIR/workers/sbx_py312.env" && -f "$SBX_UNIT_DIR/sbx-worker@.service" && -f "$SBX_UNIT_DIR/sbx-sbx_py312.slice" ]] ||
  fail "--uninstall-janitor removed a worker's files"
grep -q '^worker sbx-worker@sbx_py312 ' "$M" && grep -q '^unit ' "$M" || fail "--uninstall-janitor dropped worker lines: $(cat "$M")"
! grep -q 'disable --now sbx-worker' "$MOCK_LOG" || fail '--uninstall-janitor stopped a worker'
grep -qx 'systemctl disable --now sbx-janitor.timer' "$MOCK_LOG" || fail 'the timer was not disabled'
[[ "$(tail -1 "$MOCK_LOG")" == 'systemctl daemon-reload' ]] || fail 'daemon-reload is not the last step of --uninstall-janitor'
for f in "$S" "$SBX_UNIT_DIR/sbx-janitor.timer" "$JS" "$JE" "$JT"; do [[ ! -e "$f" ]] || fail "--uninstall-janitor left $f"; done
! grep -q '^janitor ' "$M" || fail "--uninstall-janitor left manifest lines: $(cat "$M")"
[[ -d "$SBX_SRV/workspaces/sbx_default" ]] || fail '--uninstall-janitor removed workspace data'
bash "$INSTALL" --uninstall-janitor >"$TMP/out" 2>&1 || fail 'a second --uninstall-janitor fails (it should be a no-op)'
bash "$INSTALL" --uninstall sbx_py312 >"$TMP/out" 2>&1 || fail 'uninstall sbx_py312'
[[ ! -s "$M" ]] || fail "the manifest is not empty once the janitor and every worker are gone: $(cat "$M")"
! bash "$INSTALL" --janitor "$(jbundle)" --uninstall sbx_py312 >"$TMP/out" 2>&1 || fail 'accepted --janitor with --uninstall'
pass 'the last worker uninstall leaves the janitor; --uninstall-janitor removes exactly its files and lines, never a worker'

# Egress (#623): one moca-egress per host, a seeded allowlist, the worker wired to its socket. The
# state is clean here (no worker, no janitor, an empty manifest), so the first install installs the unit.
EM="$SBX_ENV_DIR/manifest"
U="$SBX_UNIT_DIR/moca-egress.service" E="$SBX_ENV_DIR/moca-egress.env"
[[ ! -e "$U" && ! -s "$EM" ]] || fail 'the egress block does not start from a clean host'
: >"$MOCK_LOG"
bash "$INSTALL" "$(bundle sbx_eg)" --snapshot default >"$TMP/out" 2>&1 || fail 'install with egress'
grep -qx "EnvironmentFile=$E" "$U" || fail 'egress unit does not read this host env file'
! grep -q '^#' "$U" || fail 'egress unit kept source comments'
grep -qx 'ExecStart=/usr/local/bin/moca-egress' "$U" || fail 'egress unit lost its ExecStart'
[[ "$(mode "$E")" == 644 ]] || fail "the egress env file is not 0644 ($(mode "$E"))"
grep -qx 'MOCA_EGRESS_ALLOW=api.github.com,github.com,codeload.github.com,objects.githubusercontent.com' "$E" || fail 'allowlist not seeded'
grep -qx 'MOCA_EGRESS_CONTROL_SOCK=/run/moca-egress/control.sock' "$SBX_ENV_DIR/workers/sbx_eg.env" || fail 'worker not wired to the egress socket'
grep '^After=' "$SBX_UNIT_DIR/sbx-worker@.service" | grep -q 'moca-egress.service' || fail 'worker not ordered after moca-egress'
grep '^Wants=' "$SBX_UNIT_DIR/sbx-worker@.service" | grep -q 'moca-egress.service' || fail 'worker does not want moca-egress'
grep -qx 'systemctl enable moca-egress.service' "$MOCK_LOG" || fail 'moca-egress not enabled'
e="$(grep -nx 'systemctl restart moca-egress.service\|systemctl start moca-egress.service' "$MOCK_LOG" | head -1 | cut -d: -f1)"
w="$(grep -nx 'systemctl restart sbx-worker@sbx_eg.service' "$MOCK_LOG" | cut -d: -f1)"
[[ -n "$e" && -n "$w" ]] && ((e < w)) || fail "moca-egress not started before the worker (egress line '$e', worker line '$w')"
grep -qx "egress unit $U" "$EM" && grep -qx "egress file $E" "$EM" || fail 'egress files not in the manifest'
pass 'installs moca-egress before the worker, seeds the allowlist, wires the socket, records it'

# A second worker shares the one moca-egress: nothing to restart, and the unit stays when one worker goes.
: >"$MOCK_LOG"
bash "$INSTALL" "$(bundle sbx_eg2)" --snapshot default >"$TMP/out" 2>&1 || fail 'install a second worker with egress'
! grep -q 'systemctl \(re\)\{0,1\}start moca-egress' "$MOCK_LOG" || fail 'an unchanged moca-egress was restarted'
grep -qx 'systemctl enable moca-egress.service' "$MOCK_LOG" || fail 'the second install did not keep moca-egress enabled'
bash "$INSTALL" --uninstall sbx_eg2 >"$TMP/out" 2>&1 || fail 'uninstall the second worker'
[[ -f "$U" && -f "$E" ]] || fail 'uninstalling one of two workers removed the shared moca-egress'
pass 'a second worker shares moca-egress without restarting it; one uninstall leaves it'

# A moca-egress that is not running is started (after clearing a failed state), not just enabled.
: >"$MOCK_LOG"
MOCK_ACTIVE_RC=3 bash "$INSTALL" "$(bundle sbx_eg)" --snapshot default >"$TMP/out" 2>&1 || fail 're-install with moca-egress inactive'
grep -A1 -x 'systemctl reset-failed moca-egress.service' "$MOCK_LOG" | grep -qx 'systemctl start moca-egress.service' ||
  fail 'an inactive moca-egress was not reset and started'
pass 'starts an inactive moca-egress (reset-failed first)'

# An operator's edit survives a re-run.
echo 'MOCA_EGRESS_ALLOW=pypi.org' >"$E"
bash "$INSTALL" "$(bundle sbx_eg)" --snapshot default >"$TMP/out" 2>&1 || fail 're-install with egress'
grep -qx 'MOCA_EGRESS_ALLOW=pypi.org' "$E" || fail 'a re-run overwrote the allowlist'
pass 'a re-run keeps an edited allowlist'

# The last uninstall removes the unit it installed, and keeps an env file the operator edited.
bash "$INSTALL" --uninstall sbx_eg >"$TMP/out" 2>&1 || fail 'uninstall sbx_eg'
[[ ! -e "$U" ]] || fail 'the last uninstall kept the egress unit it installed'
grep -qx 'systemctl disable --now moca-egress.service' "$MOCK_LOG" || fail 'moca-egress was not stopped before its unit was removed'
[[ "$(cat "$E")" == 'MOCA_EGRESS_ALLOW=pypi.org' ]] && grep -q "kept $E (edited)" "$TMP/out" || fail 'the last uninstall dropped an edited allowlist'
! grep -q '^egress' "$EM" || fail "egress lines left in the manifest: $(cat "$EM")"
rm -f "$E"
bash "$INSTALL" "$(bundle sbx_eg)" --snapshot default >"$TMP/out" 2>&1 || fail 're-install sbx_eg'
bash "$INSTALL" --uninstall sbx_eg >"$TMP/out" 2>&1 || fail 'uninstall sbx_eg again'
[[ ! -e "$U" && ! -e "$E" ]] || fail 'the last uninstall kept an unedited egress env file'
pass 'the last uninstall removes the egress unit, and the env file unless it was edited'

# A unit this script did not install is reused, not overwritten.
echo '# P6-owned' >"$U"
: >"$MOCK_LOG"
bash "$INSTALL" "$(bundle sbx_eg)" --snapshot default >"$TMP/out" 2>&1 || fail 'install beside a P6 moca-egress'
[[ "$(cat "$U")" == '# P6-owned' ]] || fail 'overwrote a moca-egress.service it did not install'
grep -q 'reusing the existing moca-egress.service' "$TMP/out" || fail 'did not say it reused the unit'
! grep -q '^egress' "$EM" || fail 'recorded a unit it does not own'
[[ ! -e "$E" ]] || fail 'wrote an allowlist beside a unit it does not own'
! grep -q 'moca-egress.service' "$MOCK_LOG" || fail 'touched a moca-egress.service it does not own'
grep -qx 'MOCA_EGRESS_CONTROL_SOCK=/run/moca-egress/control.sock' "$SBX_ENV_DIR/workers/sbx_eg.env" || fail 'worker not wired to the reused moca-egress'
bash "$INSTALL" --uninstall sbx_eg >"$TMP/out" 2>&1 || fail 'uninstall beside P6'
[[ "$(cat "$U")" == '# P6-owned' ]] || fail 'uninstall removed a unit it did not install'
rm -f "$U"
pass 'reuses (and never removes) a moca-egress.service it did not install'

# Refusals and the opt-out.
rm "$SBX_BIN_DIR/moca-egress"; : >"$MOCK_LOG"
! bash "$INSTALL" "$(bundle sbx_eg)" --snapshot default >"$TMP/out" 2>&1 || fail 'installed with no moca-egress binary'
grep -q 'go build -o /usr/local/bin/moca-egress' "$TMP/out" || fail 'missing-binary refusal does not name the build'
! grep -q 'systemctl' "$MOCK_LOG" || fail 'touched systemd before refusing a missing binary'
[[ ! -e "$U" ]] || fail 'wrote the egress unit before refusing a missing binary'
bash "$INSTALL" "$(bundle sbx_ne)" --snapshot default --no-egress >"$TMP/out" 2>&1 || fail '--no-egress install'
! grep -q MOCA_EGRESS_CONTROL_SOCK "$SBX_ENV_DIR/workers/sbx_ne.env" || fail '--no-egress still wired the socket'
[[ ! -e "$U" ]] || fail '--no-egress installed the egress unit'
bash "$INSTALL" --uninstall sbx_ne >"$TMP/out" 2>&1 || fail 'uninstall sbx_ne'
pass 'refuses a missing binary before touching systemd; --no-egress installs a worker without egress'

# A socket that never appears fails, naming moca-egress's journal.
fake_egress; rm -f "$MOCA_EGRESS_SOCKET"
! bash "$INSTALL" "$(bundle sbx_eg)" --snapshot default >"$TMP/out" 2>&1 || fail 'succeeded with no control socket'
grep -q 'journalctl -u moca-egress' "$TMP/out" || fail 'socket timeout does not name the journal'
fake_socket
bash "$INSTALL" --uninstall sbx_eg >"$TMP/out" 2>&1 || fail 'uninstall after the socket timeout'
rm -f "$E"
[[ ! -s "$EM" ]] || fail "the manifest is not empty after the egress block: $(cat "$EM")"
pass 'fails naming journalctl -u moca-egress when the control socket never appears'
