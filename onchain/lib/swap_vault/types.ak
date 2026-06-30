//// Types for the bounded swap-vault — the "safety envelope" datum and the
//// spend redeemer. See ../../AGENTS.md for the invariant list these fields
//// enforce, and the pinned SundaeSwap V3 facts they must align with.

use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address}
use cardano/assets.{AssetName, PolicyId}

/// A rate (numerator / denominator). Kept exact so partial placements /
/// tranches preserve the floor proportionally (inv 2).
pub type Rational {
  numerator: Int,
  denominator: Int,
}

/// A single fungible asset class.
pub type AssetClass {
  policy: PolicyId,
  name: AssetName,
}

/// Where a swap order's proceeds must be paid. Pinned in FULL — address AND the
/// exact output datum. Pinning only the address lets a compromised placer attach
/// a hostile/unusable datum and strand the payout (inv 3 / validation B6). `Self`
/// (pay back to the order script) is never accepted by `Place`.
pub type Payout {
  address: Address,
  /// The exact datum the swap output must carry (typically empty/void for a
  /// plain treasury payout). The Place validator compares it byte-for-byte.
  datum: Data,
}

/// A minimal multisig authority (scope owner). The PRODUCTION shape must MATCH
/// SundaeSwap's recursive `MultisigScript` (Signature / AllOf / AnyOf / AtLeast /
/// Before / After / Script) so the same value is reusable as the order owner —
/// see AGENTS.md. This placeholder is replaced in Part A slice A1.
pub type Multisig {
  required: Int,
  signers: List<VerificationKeyHash>,
}

/// The constraints datum locked on every wrapper UTxO — the safety envelope.
/// Treasury-agnostic: every field is a parameter; the validator never assumes a
/// specific owner or payout.
pub type SwapVaultDatum {
  /// The permissioned bot allowed to `Place` (inv 1).
  placer: VerificationKeyHash,
  /// Pinned destination for every swap-order output (inv 3 / B6).
  payout: Payout,
  /// The asset every order must buy (inv 3).
  get_asset: AssetClass,
  /// Min target per offered lovelace. `min_received` must be the CEILING of
  /// `floor_rate * offer` (inv 2 / 11 / B7); covers LP fee + price impact +
  /// sandwich room (inv 9). Set against live pool depth, not a flat constant.
  floor_rate: Rational,
  /// Pinned SundaeSwap pool ident(s) the order may target (inv 4).
  allowed_pools: List<ByteArray>,
  /// Minimum per-order offer — blocks dust-tranche fee-churn (inv 11 / B4).
  min_offer_lovelace: Int,
  /// Absolute scooper-fee cap (inv 5) ...
  max_scooper_fee: Int,
  /// ... paired with a RELATIVE cap so a fixed fee can't dominate a tiny offer
  /// (inv 11): `max_protocol_fee * denominator <= offer * numerator`.
  max_fee_per_offer: Rational,
  /// Scope-owner authority for `Reclaim` of un-placed funds (inv 10).
  cancel_authority: Multisig,
}

/// Spend redeemer for a wrapper UTxO.
pub type VaultRedeemer {
  /// Permissioned: the placer emits exactly one conforming SundaeSwap `Swap`
  /// order paying the pinned destination at >= floor (inv 1-8, 11).
  Place
  /// Scope-owner reclaim of UN-placed wrapper funds back to the payout (inv 10).
  Reclaim
}
