{- |
Module      : DisburseFixture
Description : Shared fixture-recorder helper for disburse goldens (skeleton)
License     : Apache-2.0

Skeleton for feature 004 phase 4 (T030/T032). The
@runDisburseBuildFromFixtures@ helper builds a
'ChainContext' from the @utxos.json@ + @pparams.json@
fixtures (no @Provider IO@, no node socket) and invokes
@runDisburseBuild@ directly. Both 'AdaDisburseGoldenSpec'
and 'UsdmDisburseGoldenSpec' import it.

The helper itself is intentionally empty until phase 4
lands the build pipeline.
-}
module DisburseFixture
    (
    ) where
