# Signing keys

`<name>.asc` is the armored key, read by `home/bootstrap.nix`. `<name>.fpr` is
its fingerprint, recorded so a rotation shows up in review as a changed
fingerprint rather than as a silent replacement of an opaque blob.

Nothing verifies `.fpr` against `.asc` at build time, on purpose: that would
put gpg in the closure of every generation to re-check a fact a reader can see
in one `git diff`. `test/apt-sources.sh` is the real check, and it is stronger
— it fetches `InRelease` from each repository, so a key that does not verify
fails whatever its fingerprint says.
