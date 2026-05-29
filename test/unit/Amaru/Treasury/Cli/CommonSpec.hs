{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Cli.CommonSpec
Description : Unit tests for boundary helpers in 'Amaru.Treasury.Cli.Common'
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Covers the structural filter that excludes script-deploy
UTxOs from treasury-fund selection. Two surfaces:

  * Pure helper 'filterFundUtxos' — drops
    @(TxIn, TxOut ConwayEra)@ pairs whose 'TxOut' has a
    'SJust' 'referenceScriptTxOutL'.
  * Live-wiring helper 'queryFlatFunds' — composes
    'filterFundUtxos' with the existing 'queryFlat'-shaped
    summary, so a 'Provider' whose 'queryUTxOs' returns a
    UTxO at the scope's @treasuryDeployedAt@ outref with an
    attached reference script never reaches the wizard
    resolver as a fund row.
-}
module Amaru.Treasury.Cli.CommonSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Lens.Micro ((.~))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts
    ( fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Backend
    ( Provider (..)
    , singleShotWithAcquired
    )
import Amaru.Treasury.Cli.Common
    ( filterFundUtxos
    , queryFlatFunds
    , queryValues
    )
import Amaru.Treasury.IntentJSON.Common (mkHash28)
import Amaru.Treasury.LedgerParse (txInFromText)

spec :: Spec
spec = describe "Amaru.Treasury.Cli.Common" $ do
    describe "filterFundUtxos" $ do
        it
            "drops UTxOs whose TxOut carries a SJust referenceScript"
            $ do
                fundIn <- parseTxIn fundTxRef
                deployIn <- parseTxIn deployedAtTxRef
                let inputs =
                        [ (fundIn, fundTxOut)
                        , (deployIn, deployTxOut)
                        ]
                map fst (filterFundUtxos inputs)
                    `shouldBe` [fundIn]

        it "preserves a list of plain fund TxOuts unchanged" $ do
            fundIn <- parseTxIn fundTxRef
            otherIn <- parseTxIn otherFundTxRef
            let inputs =
                    [ (fundIn, fundTxOut)
                    , (otherIn, fundTxOut)
                    ]
            map fst (filterFundUtxos inputs)
                `shouldBe` [fundIn, otherIn]

    describe "queryFlatFunds" $ do
        it
            "summary excludes the deployedAt outref when its \
            \TxOut carries a reference script"
            $ do
                fundIn <- parseTxIn fundTxRef
                deployIn <- parseTxIn deployedAtTxRef
                let provider =
                        mockProvider
                            [ (fundIn, fundTxOut)
                            , (deployIn, deployTxOut)
                            ]
                rows <- queryFlatFunds provider sampleAddrText
                map fstOfTriple rows `shouldBe` [fundTxRef]

    describe "queryValues" $ do
        it "excludes TxOuts carrying reference scripts" $ do
            fundIn <- parseTxIn fundTxRef
            deployIn <- parseTxIn deployedAtTxRef
            let provider =
                    mockProvider
                        [ (fundIn, fundTxOut)
                        , (deployIn, deployTxOut)
                        ]
            rows <- queryValues provider sampleAddrText
            map fst rows `shouldBe` [fundIn]

-- ----------------------------------------------------
-- Provider mock
-- ----------------------------------------------------

mockProvider :: [(TxIn, TxOut ConwayEra)] -> Provider IO
mockProvider utxos = provider
  where
    provider =
        Provider
            { withAcquired = singleShotWithAcquired provider
            , queryUTxOs = \_ -> pure utxos
            , queryUTxOByTxIn = \_ -> pure Map.empty
            , queryProtocolParams =
                fail "unused queryProtocolParams"
            , queryLedgerSnapshot =
                fail "unused queryLedgerSnapshot"
            , queryStakeRewards = \_ ->
                fail "unused queryStakeRewards"
            , queryRewardAccounts = \_ ->
                fail "unused queryRewardAccounts"
            , queryVoteDelegatees = \_ ->
                fail "unused queryVoteDelegatees"
            , queryTreasury = fail "unused queryTreasury"
            , queryGovernanceState =
                fail "unused queryGovernanceState"
            , evaluateTx = \_ ->
                fail "unused evaluateTx"
            , posixMsToSlot = \_ ->
                fail "unused posixMsToSlot"
            , posixMsCeilSlot = \_ ->
                fail "unused posixMsCeilSlot"
            , queryUpperBoundSlot = \_ ->
                fail "unused queryUpperBoundSlot"
            }

-- ----------------------------------------------------
-- Fixtures
-- ----------------------------------------------------

-- | A plain fund TxOut at the sample treasury address.
fundTxOut :: TxOut ConwayEra
fundTxOut =
    mkBasicTxOut
        sampleAddr
        ( MaryValue
            (Coin 5_000_000)
            (MultiAsset Map.empty)
        )

{- | A reference-script TxOut at the sample treasury
  address (mirrors a per-scope script deploy output).
-}
deployTxOut :: TxOut ConwayEra
deployTxOut =
    mkBasicTxOut
        sampleAddr
        ( MaryValue
            (Coin 2_000_000)
            (MultiAsset Map.empty)
        )
        & referenceScriptTxOutL .~ SJust sampleRefScript

sampleRefScript :: Script ConwayEra
sampleRefScript =
    case mkPlutusScript plutus of
        Just s -> fromPlutusScript s
        Nothing ->
            error
                "Amaru.Treasury.Cli.CommonSpec: \
                \mkPlutusScript returned Nothing"
  where
    plutus =
        Plutus @PlutusV3
            (PlutusBinary (SBS.toShort sampleScriptBlob))
    sampleScriptBlob =
        BS.pack
            [ 0x46
            , 0x01
            , 0x00
            , 0x00
            , 0x33
            , 0x22
            , 0x22
            ]

{- | Bech32 address that 'queryFlatFunds' will parse
  internally. Matches 'sampleScope.smAddress' shape from
  the reorganize-wizard spec (mainnet bech32; the
  'parseAddr' contract accepts mainnet and devnet alike).
-}
sampleAddrText :: Text
sampleAddrText =
    "addr1x90mk0jjjhppr36ethwj8kewpgyrxyc7q6qucl4gqru96dzlhvl999wzz8r4jhway0djuzsgxvf3up5pe3l2sq8ct56qtjz6ah"

sampleAddr :: Addr
sampleAddr =
    Addr
        Mainnet
        (ScriptHashObj sampleScriptHash)
        (StakeRefBase (ScriptHashObj sampleScriptHash))

sampleScriptHash :: ScriptHash
sampleScriptHash =
    ScriptHash (mkHash28 (BS.pack (replicate 28 0x00)))

{- | Sample 'TxIn' references — plain hex/index strings the
  project's 'txInFromText' accepts.
-}
fundTxRef :: Text
fundTxRef =
    "11111111111111111111111111111111\
    \11111111111111111111111111111111#0"

otherFundTxRef :: Text
otherFundTxRef =
    "22222222222222222222222222222222\
    \22222222222222222222222222222222#1"

{- | Matches 'sampleScope.smTreasury.srDeployedAt' from
  'Amaru.Treasury.Tx.ReorganizeWizardSpec'.
-}
deployedAtTxRef :: Text
deployedAtTxRef =
    "87ee53271fb41021efa13c2dbe2998c1\
    \8ead07d32a6ab6dda184853ed7e39aae#0"

-- ----------------------------------------------------
-- Helpers
-- ----------------------------------------------------

parseTxIn :: Text -> IO TxIn
parseTxIn t = case txInFromText t of
    Right txin -> pure txin
    Left err -> do
        expectationFailure
            ( "parseTxIn: failed for "
                <> show t
                <> ": "
                <> err
            )
        error "unreachable"

fstOfTriple :: (a, b, c) -> a
fstOfTriple (a, _, _) = a
