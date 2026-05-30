{- | Behaviour contract for 'treasuryDecodeTx', the per-transaction
treasury history decoder (issue #243, slice 3).

The decoder takes the block's 'SlotNo' and a 'BlockTx' and yields
one 'TxSummary' per recognised treasury action, or 'Nothing' when the
transaction is not a treasury transaction.

Per answer A-001 every recognised entry must:

  * carry tenant @TenantId "amaru-treasury-tx"@;
  * carry the role's UTF-8 scope text verbatim;
  * echo the supplied 'SlotNo' verbatim;
  * echo the raw transaction-id bytes;
  * carry an empty payload.
  * populate transaction detail fields from the raw 'BlockTx'.

and a non-treasury transaction must decode to 'Nothing'.
-}
module Amaru.Treasury.Indexer.DecoderSpec
    ( spec
    ) where

import Data.ByteString qualified as BS
import Test.Hspec

import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.Indexer.Decoder
    ( TenantId (..)
    , TxSummary
    , summaryFee
    , summaryInputs
    , summaryOutputs
    , summaryPayload
    , summaryRedeemer
    , summaryScope
    , summarySlot
    , summaryTenant
    , summaryTxId
    , treasuryDecodeTx
    )
import Amaru.Treasury.Indexer.DecoderFixtures
    ( RoleFixture (..)
    , contingencyDisburseFixture
    , disburseFixture
    , invalidBlockTx
    , mintRegistryFixture
    , reorganizeFixture
    , swapFixture
    , withdrawFixture
    )

-- | The slot the decoder must echo verbatim into every entry.
suppliedSlot :: SlotNo
suppliedSlot = SlotNo 424242

-- | Assert the full A-001 entry contract for a single role.
itDecodesRole :: String -> RoleFixture -> Spec
itDecodesRole role fixture =
    describe role $ do
        let entries =
                treasuryDecodeTx suppliedSlot (fixtureTx fixture)
        it "decodes to exactly one summary entry" $
            fmap length entries `shouldBe` Just 1
        it "tags the amaru-treasury-tx tenant" $
            fmap summaryTenant (firstEntry entries)
                `shouldBe` Just (TenantId "amaru-treasury-tx")
        it "carries the role scope text verbatim" $
            fmap summaryScope (firstEntry entries)
                `shouldBe` Just (fixtureScope fixture)
        it "echoes the supplied slot verbatim" $
            fmap summarySlot (firstEntry entries)
                `shouldBe` Just suppliedSlot
        it "echoes the raw transaction-id bytes" $
            fmap summaryTxId (firstEntry entries)
                `shouldBe` Just (fixtureTxId fixture)
        it "carries an empty payload" $
            fmap summaryPayload (firstEntry entries)
                `shouldBe` Just BS.empty
        it "populates decoded transaction details" $ do
            fmap (not . null . summaryInputs) (firstEntry entries)
                `shouldBe` Just True
            fmap (not . null . summaryOutputs) (firstEntry entries)
                `shouldBe` Just True
            fmap summaryFee (firstEntry entries)
                `shouldSatisfy` maybe False (maybe False (> 0))
            fmap summaryRedeemer (firstEntry entries)
                `shouldSatisfy` maybe False (maybe False (not . BS.null))

{- | The first decoded entry, if the transaction decoded to a
non-empty list of treasury entries.
-}
firstEntry :: Maybe [TxSummary] -> Maybe TxSummary
firstEntry = \case
    Just (e : _) -> Just e
    _ -> Nothing

spec :: Spec
spec = describe "treasuryDecodeTx" $ do
    itDecodesRole "disburse" disburseFixture
    itDecodesRole "reorganize" reorganizeFixture
    itDecodesRole "withdraw" withdrawFixture
    itDecodesRole "swap" swapFixture
    itDecodesRole "contingency-disburse" contingencyDisburseFixture
    itDecodesRole "mint-registry" mintRegistryFixture
    describe "threads the supplied slot (no hardcode)" $ do
        -- A-001 point 5: two distinct supplied slots must produce
        -- two distinct surfaced slots, forbidding a decoder that
        -- hardcodes a slot or infers it from the tx bytes.
        let slotA = SlotNo 1
            slotB = SlotNo 2
            atSlot s =
                firstEntry
                    (treasuryDecodeTx s (fixtureTx disburseFixture))
        it "echoes slotA when given slotA" $
            fmap summarySlot (atSlot slotA) `shouldBe` Just slotA
        it "echoes slotB when given slotB" $
            fmap summarySlot (atSlot slotB) `shouldBe` Just slotB
        it "different input slots => different surfaced slots" $
            ( fmap summarySlot (atSlot slotA)
                == fmap summarySlot (atSlot slotB)
            )
                `shouldBe` False
    describe "non-treasury transaction" $
        it "decodes to Nothing" $
            treasuryDecodeTx suppliedSlot invalidBlockTx
                `shouldBe` (Nothing :: Maybe [TxSummary])
