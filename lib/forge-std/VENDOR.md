# Vendored forge-std

Upstream: https://github.com/foundry-rs/forge-std
Tag:      v1.9.6
Commit:   3b20d60d14b343ee4f908cb8079495c07f5e8981

Copied, not submoduled, so a plain clone builds with no submodule step.
Only `src/` is vendored — that is all the `forge-std/=lib/forge-std/src/` remapping
resolves, and forge-std v1.9.6 `src/` imports no `ds-test`, so the tree is self-contained.

Test-only: nothing here reaches deployed bytecode.
