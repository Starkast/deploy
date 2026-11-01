#!/bin/sh
# Runs bin/deploy-secrets against throwaway keys. Needs age and ssh-keygen.
set -eu

tool=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/bin/deploy-secrets
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

failures=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    echo "ok - $1"
  else
    echo "not ok - $1: expected '$2', got '$3'"
    failures=$((failures + 1))
  fi
}
fails() { # description, command...
  description=$1
  shift
  if "$@" > /dev/null 2>&1; then
    check "$description" failure success
  else
    check "$description" failure failure
  fi
}

ssh-keygen -q -t ed25519 -N '' -C alice -f alice
ssh-keygen -q -t ed25519 -N '' -C bob -f bob
age-keygen -o vm 2> /dev/null
mkdir -p github
{
  cat alice.pub
  echo 'sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29t unusable'
} > github/alice.keys
export DEPLOY_SECRETS_GITHUB="file://$tmp/github"
export DEPLOY_SECRETS_IDENTITY="$tmp/alice"

fails "set needs a recipient" sh -c "echo x | '$tool' set TOKEN"

"$tool" add-github alice
check "add-github skips keys age can't use" 1 "$(grep -c '^ssh-' secrets/recipients)"
check "add-github notes where keys came from" 1 "$(grep -c '^# github.com/alice$' secrets/recipients)"
"$tool" add-github alice
check "add-github doesn't add a key twice" 1 "$(grep -c '^ssh-' secrets/recipients)"
fails "add-github needs a usable key" "$tool" add-github nobody
"$tool" add "$(age-keygen -y vm)" vm.example.net
fails "add rejects what age can't use" "$tool" add 'sk-ssh-ed25519@openssh.com AAAA'

printf 'value with spaces\n' | "$tool" set TOKEN
check "get decrypts what set encrypted" "value with spaces" "$("$tool" get TOKEN)"
check "the file doesn't hold the value" 0 "$(grep -c 'value with spaces' secrets/TOKEN.age || true)"
check "the host's key can read it" "value with spaces" "$(age --decrypt --identity vm secrets/TOKEN.age)"

printf 'A=1\nB=x=y\nC=not imported\n' | "$tool" import A B
check "import keeps = in values" "x=y" "$("$tool" get B)"
check "import only takes the names given" "A
B
TOKEN" "$("$tool" list)"
fails "import needs every name" sh -c "echo A=1 | '$tool' import MISSING"

for name in 1A A-B 'A B' ../A ''; do
  fails "set rejects the name '$name'" sh -c "echo x | '$tool' set '$name'"
done
fails "set rejects an empty value" sh -c "printf '' | '$tool' set EMPTY"
fails "get fails for a missing secret" "$tool" get MISSING

fails "bob can't read before a rekey" env DEPLOY_SECRETS_IDENTITY="$tmp/bob" "$tool" get TOKEN
message=$("$tool" add "$(cat bob.pub)" bob 2>&1)
check "add says when a rekey is needed" 1 "$(printf '%s\n' "$message" | grep -c rekey)"
"$tool" rekey
check "bob can read after a rekey" "value with spaces" "$(DEPLOY_SECRETS_IDENTITY="$tmp/bob" "$tool" get TOKEN)"
check "a rekey keeps the value for the host" "x=y" "$(age --decrypt --identity vm secrets/B.age)"
fails "a key not on the list can't rekey" env DEPLOY_SECRETS_IDENTITY="$tmp/vm-missing" "$tool" rekey

"$tool" rm A
check "rm removes the secret" "B
TOKEN" "$("$tool" list)"
check "no temporary files are left" 0 "$(find secrets -name '.*' -type f | wc -l | tr -d ' ')"

[ "$failures" -eq 0 ] || {
  echo "$failures failed"
  exit 1
}
echo "all passed"
