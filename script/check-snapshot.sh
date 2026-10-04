#!/usr/bin/env bash
# `forge snapshot --check` made independent of the directory the repository is checked out in.
#
# Twenty tests read this repository's own files (`vm.readFile(string.concat(vm.projectRoot(),
# ...))`) or otherwise depend on the checkout path, and their gas follows the length and bytes of
# that path: the same tree gives different figures in /a/evm and in /b/c/d/evm. The invariant
# runs (`invariant_*`) are path-dependent too: their revert counts change with the path. They are excluded
# here, and only here, from the SNAPSHOT. They still run in `forge test`, with every assertion
# intact. docs/ci-gates.md §8 has the list and the measurement.
#
# Usage:  ./script/check-snapshot.sh           # compare against .gas-snapshot (exit 1 on a diff)
#         ./script/check-snapshot.sh --write   # regenerate .gas-snapshot
set -euo pipefail
export PATH="${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

PATH_DEPENDENT='(testFuzz_onlyTheNamedBuyersOwnKeyAuthorisesEitherDoor|test_boundary_theDeadlineAdmitsItsOwnInstant|test_everyBytes32ConstantInTypesSolIsNamedATypehash|test_everyRegisteredTypehashMatchesItsCompiledStruct|test_everyTypehashDeclaredInTypesSolIsRegistered|test_paramSetCarriesItsDeclaredWidthsAndOrder|test_probeArtifactsAreEmittedBecauseTheProbesAreReferenced|test_recoveryHappensAtExactlyOneCallSiteInSrc|test_theAbiDerivationReproducesTheFullTypeString|test_theBatchDelegatesToTheOneRedeemPathInTheSource|test_theConfigFunctionSurfaceIsPinnedByName|test_theDeployScriptUsesTheAtomicForm|test_theDeploymentScriptsCarryTheFunctionSurfaceGate|test_theExitPaysMsgSenderAndTheAbiHasNoOtherWithdrawDoor|test_theSignatureComparisonIsUnconditionalInTheSource|test_theStakeFunctionSurfaceIsPinnedByName|test_theWeakVerifierCannotSeeAnUnrecordedUpgrade|test_theWithdrawDelayOutlivesEveryVoucherSignedBeforeTheRequest|test_wrongState_oneNonceServesBothDoors|test_noProviderAddressIsExemptFromTheSignatureGuard|invariant_)'

case "${1:-}" in
  --write) exec forge snapshot --no-match-path "test/fork/*" --no-match-test "$PATH_DEPENDENT" ;;
  "")      exec forge snapshot --check --no-match-path "test/fork/*" --no-match-test "$PATH_DEPENDENT" ;;
  *)       echo "usage: $0 [--write]" >&2; exit 2 ;;
esac
