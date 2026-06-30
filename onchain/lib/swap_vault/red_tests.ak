//// Adversarial red-test ROADMAP for the bounded swap-vault. Each `fail` test is
//// a placeholder for an attack the validator MUST reject. Part A replaces each
//// `False` body with a real transaction the validator rejects — RED before GREEN
//// (see ../../AGENTS.md). The `fail` keyword asserts the body does not hold, so
//// these compile green today and stay green when the real rejecting tx is wired.

// --- Place (T1) ---
/// inv 1
test place_rejects_unsigned_by_placer() fail { False }

/// inv 8 (CRITICAL): N wrapper inputs, one shared order+change -> drain N-1
test place_rejects_batch_drain_many_inputs_one_order() fail { False }

/// inv 3: only the Swap constructor is admissible
test place_rejects_non_swap_order_variant() fail { False }

/// inv 3 / B6: Self destination strands proceeds in the order script
test place_rejects_self_destination() fail { False }

/// B6: address pinned but a hostile/unusable output datum
test place_rejects_hostile_destination_datum() fail { False }

/// inv 2/3: min_received below floor_rate * offer
test place_rejects_below_floor_min_received() fail { False }

/// inv 11 / B7: floor must be CEILING; floor-division underpays per tranche
test place_rejects_floor_rounding_shortfall() fail { False }

/// inv 4: order routed to a pool not in allowed_pools
test place_rejects_unpinned_pool() fail { False }

/// inv 11 / B4: many dust orders each burning a fixed protocol fee
test place_rejects_dust_tranche_fee_churn() fail { False }

/// inv 6/7: change skimmed / native assets stranded on partial placement
test place_rejects_skimmed_change() fail { False }

/// B3: order.extension must equal the vault datum (the recall datum carrier)
test place_rejects_extension_not_equal_datum() fail { False }

// --- Recall / cancel (T2) — the crux of the audit ---
/// inv 8 (CRITICAL): N expired orders cancelled, only one returned
test recall_rejects_batch_cancel_many_orders_one_returned() fail { False }

/// B3 (CRITICAL): value returned to the wrapper under a weak/empty datum
test recall_rejects_weak_datum_on_returned_output() fail { False }

/// B5 (HIGH): a tx that both Places and Recalls miscounts the Place change
test recall_rejects_tx_that_also_spends_wrapper_input() fail { False }

// --- Reclaim ---
/// inv 10
test reclaim_rejects_without_cancel_authority() fail { False }

// sanity: the module compiles
test scaffold_compiles() {
  True
}
