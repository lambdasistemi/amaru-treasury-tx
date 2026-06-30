//// Bounded swap-vault — the on-chain safety envelope for delegated SundaeSwap
//// swaps. ONE validator on the wrapper script, two handlers:
////   * spend    — Place (permissioned placer) | Reclaim (scope owner)
////   * withdraw — recall handler (post-expiry, double-satisfaction-safe)
////
//// Logic is a SCAFFOLD (`todo`). Implement RED-first per invariant — see
//// ../AGENTS.md and lib/swap_vault/red_tests.ak. Full theorems T1/T2 in #396.

use cardano/address.{Credential}
use cardano/transaction.{OutputReference, Transaction}
use swap_vault/types.{Place, Reclaim, SwapVaultDatum, VaultRedeemer}

validator swap_vault {
  spend(
    datum: Option<SwapVaultDatum>,
    redeemer: VaultRedeemer,
    _own_ref: OutputReference,
    _self: Transaction,
  ) {
    expect Some(_d) = datum
    when redeemer is {
      // --- Place: the permissioned optimizer path (inv 1-8, 11) ---
      //  1  txSignedBy(placer)
      //  8  EXACTLY ONE input at the wrapper spend credential — count globally,
      //     NEVER scoped to same-datum/out-ref (anti batch-drain, CRITICAL)
      //  3  total decoder pins the produced order: details = Swap{offer,min_received},
      //     destination = Fixed{payout} (reject Self + every non-Swap ctor),
      //     asset = get_asset
      //  2/11 min_received >= ceil(floor_rate*offer); offer >= min_offer_lovelace
      //  4  order.pool_ident in allowed_pools
      //  5/11 max_protocol_fee <= max_scooper_fee AND relative cap (max_fee_per_offer)
      //  B3 order.extension == this datum (datum carrier for recall)
      //  6/7 change -> wrapper, datum verbatim; value conserved incl. native assets
      Place -> todo @"Place: enforce inv 1-8, 11, B3 (see AGENTS.md)"

      // --- Reclaim: scope-owner emergency reclaim of UN-placed funds -> payout ---
      //  10 multisig.satisfied(cancel_authority) && all value -> payout
      Reclaim -> todo @"Reclaim: scope-owner multisig -> payout"
    }
  }

  // --- Recall: post-expiry permissionless return of cancelled orders. THE crux. ---
  // Invoked via the order owner's Script(wrapperStake) withdraw-zero.
  //  8  account for EVERY Script(wrapperStake)-owned cancelled order 1:1; reject
  //     if N cancelled but < N returned (anti batch-cancel, CRITICAL)
  //  B3 each returned wrapper output's datum == the cancelled order's `extension`
  //     (datum conservation — the staking validator can't read a spent input's datum)
  //  B5 reject any tx that ALSO spends a wrapper-script input (isolate Recall/Place)
  withdraw(_redeemer: Data, _account: Credential, _self: Transaction) {
    todo @"Recall: 1:1 accounting + datum conservation (B3) + Place/Recall isolation (B5)"
  }

  else(_) {
    fail
  }
}
