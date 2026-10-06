# Launch 2 adaptation

Deploy `FrenArtChunk3`, then `FrenArtChunk4`, from `src/FrenArtChunks.sol`, with no constructor arguments and zero
ETH. Both already have nonpayable, argument-free constructors compatible with the protected factory's CREATE2
path. Neither has ownership, storage, initialization calls or executable behavior beyond its leading STOP.
No application contract required modification. The generated art, index, renderer, build configuration and
dependencies are unchanged. No token or launch manifest was added.

## Changes and reasons

- `test/FrenRenderer.t.sol`: fixed reproduced audit finding
  `119a12da4fc9ca716c13e0177ec2a31e34958ba7986a183ceae23a73eabfc9ad`.
  With Forge 1.8.3, the original `forge test --match-test test_LaunchesFitTransactions -vv` reported
  1,000,622 / 957,524 / 1,295,967 gas. Launch 2's runtime sizes are 23,479 + 21,187 bytes, whose code deposit alone
  costs 8,933,200 gas, confirming the missing cost. The revised budget explicitly adds 200 gas/runtime byte,
  32,000 per creation, and 8 gas per separately rounded initcode word (2 for EIP-3860 and 6 for CREATE2 hashing).
  It also includes the measured execution, 21,000 transaction base gas, 16 gas/initcode calldata byte,
  1 KiB of additional calldata and a 100,000-gas allowance for factory overhead. Explicit creation charges are
  retained even if a Foundry version already meters some of them, conservatively double counting those charges.
  Runtime and initcode limits are checked for each contract; the renderer's seven encoded address arguments are
  included in its initcode length. Gas constants follow [EIP-3860](https://eips.ethereum.org/EIPS/eip-3860) and
  [EIP-1014](https://eips.ethereum.org/EIPS/eip-1014).
  Added regressions check that launch 2's deposit remains included with zero metered execution and that a
  hypothetical batch of four chunk-3 contracts exceeds the cap. The original cap check retains 5% headroom.
  Added an offline CREATE2 rehearsal for the requested pair, in order, checking exact runtime bytes against
  deployments accepted by the renderer, STOP behavior and complete PUSH32 framing. This covers the launch's
  factory-compatibility and immutable-art requirements without changing the contracts.
- `README.md`: corrected the unsupported gas figures, described the cost model and its overhead assumptions,
  and listed the new regression and factory tests. The numbers describe a rehearsal budget; final signed
  transaction simulation by the deployment service remains necessary because the production factory is not
  part of this repository.
- `ADAPTATION.md`: recorded the required change rationale, audit disposition and local validation.

## Informational audit coverage

Finding `f21e7b9c15cb3fadb1f24a5aa2ba970f9896707e293027ec7df7af463d773bc3` reported no defect, so it required
no contract change. Local checks corroborated its launch-2 claims: independent Python parsing of the Solidity
hex literals plus `cast keccak` verified all seven runtime hashes, sizes, STOP prefixes and admission scans
against `FrenArtIndex`. All 70 indexed entries match the art kit binaries after removing framing. Chunk 4 has
642 PUSH32 frames and six zero padding bytes. Compiled ABIs confirm both constructors are nonpayable with
no arguments; their initcode lengths are 28,320 and 25,852 bytes, below 49,152.

| Contract | Runtime bytes | Runtime keccak256 |
| --- | ---: | --- |
| FrenArtChunk3 | 23,479 | `d73ecfd95e853d3bf20224d02e30889477ac2627bc1970c5e6b0ca5ef202c9a8` |
| FrenArtChunk4 | 21,187 | `54bd89d96a8e4b1a1530687bb8442321920166014b5b7a89a414bae379f1a49b` |

The deployed launch-819 chunks, NFT contract and external control-plane implementation were not independently
verified. No RPC was configured; the existing fork test skipped. No reported defect failed to reproduce: the
low-severity finding reproduced and was fixed; the other entry is informational coverage.

## Validation

- `forge build`: passed with the repository's unchanged configuration and existing renderer lint warnings.
- `forge test -vv`: 10 passed, 0 failed, 1 fork test skipped. This includes all original renderer/art checks and
  the three new regression/deployment tests. Revised launch budgets: 10,823,238 / 10,084,652 / 14,055,991 gas,
  all below 15,938,355 (95% of 2^24).
- Independent byte/hash/art-kit checks described above passed. No dependencies were installed, no keys were
  read, and no transactions were broadcast. Slither and Mythril were not run.
