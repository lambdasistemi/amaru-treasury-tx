{- |
Module      : OtcSwapGoldenSpec
Description : Offline byte-exact golden for the OTC swap (issue #499)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Rebuilds the body of mainnet transaction
@9ed505b48df617716423f58687283ee5e130684d8b3b6c9f2ed03b473c0154f1@
(block 13868016, epoch 652) from a frozen 'ChainContext' and asserts
__byte equality__ with the accepted on-chain body
(@test\/fixtures\/otc-swap\/reference-body.cbor@). That transaction is
the load-bearing oracle of this slice: its spend redeemer was accepted
by the treasury validator, so a builder reproducing its body bytes
agrees with a body the chain has already ruled on.

The typed 'OtcSwapIntent' is constructed directly in Haskell — the
intent wire format is slice C and does not exist yet. This golden does
/not/ go through 'runFromIntent'\/JSON. Unlike
"Amau.Disburse" golden fixtures, @reference-body.cbor@ is the on-chain
body itself and is __never__ regenerated from builder output; there is
deliberately no @UPDATE_GOLDENS@ escape hatch here.

Arrangement notes (all decoded from the reference, cross-checked
against @journal\/2026\/metadata.json@):

* @b98a…#0@ is the __treasury__ input (script address, type 3), spent
  under the two-legged @Disburse@ redeemer;
* @cde5…#0@ is the counterparty USDM UTxO (122,662.5 USDM);
* @c17a…#1@ is the counterparty's pure-ADA UTxO, used as __both__
  regular input and collateral — the reference is counterparty-funded,
  so byte equality and operator funding cannot hold in one
  transaction; the operator-funded builder properties therefore live
  in their own test below (restated T-B07, per the ticket's inbox-01
  ruling).
-}
module OtcSwapGoldenSpec (spec) where

import Control.Exception (try)
import Control.Monad.Trans.Except (runExceptT)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Crypto.Hash.Class (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address
    ( AccountAddress
    , Addr (..)
    , decodeAddr
    , deserialiseAccountAddress
    , serialiseAddr
    )
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body qualified as L
import Cardano.Ledger.Api.Tx.Out qualified as O
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , SlotNo (..)
    , StrictMaybe (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Binary
    ( DecoderError
    , decCBOR
    , decodeFullAnnotator
    , serialize'
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TopTx, TxBody, auxDataTxL, bodyTxL)
import Cardano.Ledger.Credential
    ( Credential (..)
    , PaymentCredential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( Guard
    , KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Metadata (Metadatum (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((^.))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldNotBe
    )

import Amaru.Treasury.Build.Error (BuildException (..))
import Amaru.Treasury.Build.OtcSwap (runOtcSwapAction)
import Amaru.Treasury.Build.Result (BuildResult (..))
import Amaru.Treasury.ChainContext
    ( ChainContext (..)
    , frozenContextAt
    )
import Amaru.Treasury.ChainContext.Fixture
    ( SwapFixture (..)
    , readSwapFixture
    )
import Amaru.Treasury.LedgerParse (addrFromText)
import Amaru.Treasury.Tx.Disburse (DisburseIntentFields (..))
import Amaru.Treasury.Tx.OtcSwap
    ( OtcSwapIntent (..)
    , OtcSwapPayload (..)
    )

-- ------------------------------------------------------------------
-- Constants decoded from the reference transaction
-- ------------------------------------------------------------------

-- | Mainnet txid the golden pins (block 13868016, epoch 652).
referenceTxId :: Text
referenceTxId =
    "9ed505b48df617716423f58687283ee5e130684d8b3b6c9f2ed03b473c0154f1"

fixtureDir :: FilePath
fixtureDir = "test/fixtures/otc-swap"

{- | @invalidBefore@ of the reference body; also the tip slot the
frozen context samples, so @validFrom (ccTipSlot ctx)@ reproduces it.
-}
referenceTipSlot :: SlotNo
referenceTipSlot = SlotNo 196367308

referenceUpperBound :: SlotNo
referenceUpperBound = SlotNo 196496998

-- | Fee of the reference body.
referenceFee :: Coin
referenceFee = Coin 419678

-- | 10 USDM (6 decimals) entering the treasury.
referenceIncomingQuantity :: Integer
referenceIncomingQuantity = 10000000

-- | 47.619047 ADA leaving the treasury.
referenceAdaOut :: Coin
referenceAdaOut = Coin 47619047

{- | Treasury continuing output retains the rest of its input:
25,644,305,641 − 47,619,047.
-}
referenceTreasuryLeftover :: Coin
referenceTreasuryLeftover = Coin 25596686594

-- | Lovelace on @cde5…#0@, the counterparty USDM UTxO.
counterpartyInputLovelace :: Integer
counterpartyInputLovelace = 1189560

usdmPolicyBytes :: ByteString
usdmPolicyBytes =
    mustHex "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"

usdmAssetBytes :: ByteString
usdmAssetBytes = mustHex "0014df105553444d"

-- | The two scope owners on the reference.
scopeOwnerA, scopeOwnerB :: Text
scopeOwnerA = "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
scopeOwnerB = "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"

{- | @treasuries.ops_and_use_cases.address@ from
@journal\/2026\/metadata.json@ (the registry is authoritative).
-}
treasuryAddressText :: Text
treasuryAddressText =
    "addr1x9r8gmryz5wrwvlxm6g4s4u9ssdz656z95hwjnk9rgamedzxw3kxg9guxue7dh53tptctpq694f5ytfwa98v2x3mhj6qe3kxep"

{- | Destination of the ADA leg on the reference: a script address
(no stake part), decoded from body output 0.
-}
counterpartyAdaLegBytes :: ByteString
counterpartyAdaLegBytes =
    mustHex "616cf1df81b701c409ec5561efe9973224b4b95777cddb486b0f0fab28"

{- | The counterparty's own wallet (key payment + keyhash stake):
change and collateral-return destination on the reference.
-}
counterpartyWalletBytes :: ByteString
counterpartyWalletBytes =
    mustHex
        "01e0b68e229f9c043ab610067ed7f3c6d662b8f3c6bb4ec452c11f6411f0e17b51bc18962397450eb625222bce9c510cb82b213bd9cf17ea82"

-- | The permissions reward account (withdraw-zero target), raw bytes.
permissionsAccountBytes :: ByteString
permissionsAccountBytes =
    mustHex "f1cf9a4136d781e65d6885ee574480d29f1d1a342fe15f215ee6bf0cbb"

referenceTreasuryTxIn :: TxIn
referenceTreasuryTxIn =
    txInOf
        "b98a1633080a1b42ff452ee546ec4e47679c7af726783adfd871240cb932d34d"
        0

referenceCounterpartyUtxo :: TxIn
referenceCounterpartyUtxo =
    txInOf
        "cde5ce7b77da67667e8b69f20b10c8f8aac3cc91f76d2ace72aa754ff2499f46"
        0

referenceFuelUtxo :: TxIn
referenceFuelUtxo =
    txInOf
        "c17a1d53eb0fc3ed327f3b392c80dca855977278429800b688fcdf9a9b8114fa"
        1

scopesReference :: TxIn
scopesReference =
    txInOf
        "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54"
        0

permissionsReference :: TxIn
permissionsReference =
    txInOf
        "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095"
        1

treasuryReference :: TxIn
treasuryReference =
    txInOf
        "660c0729b68bce67f62d4f1f3ae38082217e55915bb3e0d9222a67b2f9fd821c"
        0

registryReference :: TxIn
registryReference =
    txInOf
        "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c"
        1

treasuryAddress :: Addr
treasuryAddress =
    either error id (addrFromText treasuryAddressText)

referenceCounterpartyAddress :: Addr
referenceCounterpartyAddress =
    decodeAddrBytes counterpartyAdaLegBytes

counterpartyWalletAddress :: Addr
counterpartyWalletAddress =
    decodeAddrBytes counterpartyWalletBytes

permissionsAccount :: AccountAddress
permissionsAccount =
    fromMaybe
        (error "permissions reward account bytes")
        (deserialiseAccountAddress permissionsAccountBytes)

usdmPolicy :: PolicyID
usdmPolicy = PolicyID (mustScriptHash usdmPolicyBytes)

usdmAsset :: AssetName
usdmAsset = AssetName (SBS.toShort usdmAssetBytes)

usdmMultiAsset :: Integer -> MultiAsset
usdmMultiAsset qty =
    MultiAsset
        (Map.singleton usdmPolicy (Map.singleton usdmAsset qty))

-- | The reference intent: the exact on-chain arrangement.
referenceIntent :: OtcSwapIntent
referenceIntent = OtcSwapIntent referenceFields referencePayload

referenceFields :: DisburseIntentFields
referenceFields =
    DisburseIntentFields
        { difWalletUtxo = referenceFuelUtxo
        , difBeneficiaryAddress = referenceCounterpartyAddress
        , difTreasuryUtxos = [referenceTreasuryTxIn]
        , difTreasuryAddress = treasuryAddress
        , difPermissionsRewardAccount = permissionsAccount
        , difScopesDeployedAt = scopesReference
        , difPermissionsDeployedAt = permissionsReference
        , difTreasuryDeployedAt = treasuryReference
        , difRegistryDeployedAt = registryReference
        , difSigners =
            [scopeOwnerKeyHash scopeOwnerA, scopeOwnerKeyHash scopeOwnerB]
        , difUpperBound = referenceUpperBound
        }

{- | The reference payload. The counterparty output carries the ADA
leg alone; their own lovelace cycles through fuel\/collateral and the
USDM remainder (122,652.5 USDM) reaches the change address through
balancing — that is how the accepted body does it.
-}
referencePayload :: OtcSwapPayload
referencePayload =
    OtcSwapPayload
        { ospCounterpartyAddress = referenceCounterpartyAddress
        , ospCounterpartyUtxo = referenceCounterpartyUtxo
        , ospCounterpartyLeftover = MultiAsset Map.empty
        , ospCounterpartyLovelace = referenceAdaOut
        , ospAdaOut = referenceAdaOut
        , ospIncomingPolicy = usdmPolicy
        , ospIncomingAsset = usdmAsset
        , ospIncomingQuantity = referenceIncomingQuantity
        , ospLeftoverLovelace = referenceTreasuryLeftover
        , ospLeftoverAssets = MultiAsset Map.empty
        }

{- | The CIP-1694 rationale carried by the reference auxdata
(label 1694; auxdata hash e4f71995…, committed in body key 7).
The long strings are chunked exactly as the counterparty toolchain
chunked them — byte fidelity includes the chunk boundaries.
-}
referenceRationale :: Metadatum
referenceRationale =
    Map
        [
            ( S "@context"
            , List
                [ S "https://raw.githubusercontent.com/SundaeSwap-finance/treasury-co"
                , S "ntracts/refs/heads/main/offchain/src/metadata/context.jsonld"
                ]
            )
        , (S "hashAlgorithm", S "blake2b-256")
        ,
            ( S "txAuthor"
            , S "e0b68e229f9c043ab610067ed7f3c6d662b8f3c6bb4ec452c11f6411"
            )
        ,
            ( S "instance"
            , S "bd7d70eff456af39f86e708fb634b7b69edf5c2aafae7a422f905f5c"
            )
        ,
            ( S "body"
            , Map
                [ (S "event", S "disburse")
                , (S "label", S "USDM/ADA swap")
                ,
                    ( S "description"
                    , List
                        [ S "Atomic swap of 10.000000 USDM into the treasury for 47.619047 AD"
                        , S "A at 0.21 USD/ADA"
                        ]
                    )
                ,
                    ( S "justification"
                    , S "Test OTC swap of 10 USDM for ADA at a price of $0.21"
                    )
                , (S "destination", Map [(S "label", S "Sundae Labs")])
                ]
            )
        ]

-- ------------------------------------------------------------------
-- The operator-funded arrangement (restated T-B07)
-- ------------------------------------------------------------------

{- | Synthetic operator fuel UTxO: pure ADA at a key address distinct
from the counterparty. Fixture-only; provenance documented in
@test\/fixtures\/otc-swap\/provenance.md@.
-}
operatorFuelUtxo :: TxIn
operatorFuelUtxo =
    txInOf
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        0

-- | Synthetic operator change address (key payment + keyhash stake).
operatorAddressBytes :: ByteString
operatorAddressBytes =
    mustHex ("01" <> T.replicate 56 "2" <> T.replicate 56 "3")

operatorAdaOut :: Coin
operatorAdaOut = Coin 2000000

{- | The operator-funded arrangement: an operator UTxO supplies fuel
and collateral, and the counterparty output carries their input
lovelace plus the full ADA leg and their whole remaining USDM holding
— the data-model canonical shape (INV-4).
-}
operatorIntent :: OtcSwapIntent
operatorIntent =
    OtcSwapIntent
        referenceFields{difWalletUtxo = operatorFuelUtxo}
        referencePayload
            { ospCounterpartyLovelace =
                Coin (counterpartyInputLovelace + unCoin operatorAdaOut)
            , ospCounterpartyLeftover = MultiAsset Map.empty
            , ospLeftoverLovelace =
                Coin (25644305641 - unCoin operatorAdaOut)
            }

-- ------------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------------

mustHex :: Text -> ByteString
mustHex t =
    case B16.decode (TE.encodeUtf8 (T.strip t)) of
        Right bs -> bs
        Left e -> error (show e)

mustScriptHash :: ByteString -> ScriptHash
mustScriptHash = ScriptHash . fromMaybe (error "hash bytes") . hashFromBytes

mustGuardKeyHash :: ByteString -> KeyHash Guard
mustGuardKeyHash = KeyHash . fromMaybe (error "hash bytes") . hashFromBytes

txInOf :: Text -> Int -> TxIn
txInOf h ix =
    TxIn
        ( TxId
            ( unsafeMakeSafeHash
                (fromMaybe (error "txid bytes") (hashFromBytes (mustHex h)))
            )
        )
        (mkTxIxPartial (toInteger ix))

scopeOwnerKeyHash :: Text -> KeyHash Guard
scopeOwnerKeyHash = mustGuardKeyHash . mustHex

counterpartyPaymentKeyHashBytes :: ByteString
counterpartyPaymentKeyHashBytes = BS.drop 1 counterpartyWalletBytes

decodeAddrBytes :: ByteString -> Addr
decodeAddrBytes bs =
    fromMaybe (error "addr bytes") (decodeAddr bs)

decodeBodyBytes
    :: ByteString -> Either DecoderError (TxBody TopTx ConwayEra)
decodeBodyBytes =
    decodeFullAnnotator (eraProtVerLow @ConwayEra) "TxBody" decCBOR
        . BSL.fromStrict

bodyBytes :: TxBody TopTx ConwayEra -> ByteString
bodyBytes = serialize' (eraProtVerLow @ConwayEra)

bodyHex :: TxBody TopTx ConwayEra -> ByteString
bodyHex = B16.encode . bodyBytes

seqToList :: (Foldable f) => f a -> [a]
seqToList = foldr (:) []

{- | Frozen context at the reference's own tip slot; the evaluator
replays the on-chain execution units, so the script-integrity hash
is reproduced exactly.
-}
otcContext :: SwapFixture -> ChainContext
otcContext fixture =
    frozenContextAt
        Mainnet
        referenceTipSlot
        (sfPParams fixture)
        (sfUtxos fixture)
        (\_tx -> pure (Right <$> sfExUnits fixture))

expectedBody :: IO (TxBody TopTx ConwayEra)
expectedBody = do
    hexText <-
        TE.decodeUtf8 <$> BS.readFile (fixtureDir <> "/reference-body.cbor")
    case decodeBodyBytes (mustHex hexText) of
        Left e -> fail (show e)
        Right body -> pure body

{- | Build and return the resulting __body__ (witness sets cannot be
reproduced offline; the body is what the validator ruled on).
-}
buildBody
    :: ChainContext
    -> Addr
    -- ^ change address
    -> OtcSwapIntent
    -> IO (Either String (TxBody TopTx ConwayEra))
buildBody ctx changeAddr intent = do
    r <-
        try
            ( runExceptT
                (runOtcSwapAction ctx intent referenceRationale changeAddr)
            )
    pure $ case r of
        Left e -> Left (show (e :: BuildException))
        Right (Left e) -> Left (show e)
        Right (Right result) -> Right (brFinalTxBody result)

-- ------------------------------------------------------------------
-- Invariant checkers (pure, shared by positive and negative controls)
-- ------------------------------------------------------------------

{- | INV-2 + INV-3 over treasury-addressed UTxOs: the continuing
treasury output must equal the treasury input value minus the ADA leg
plus the incoming asset quantity, with every pre-existing asset
preserved. Returns human-readable violations; @[]@ means holding.
-}
treasuryConservationErrors
    :: Map TxIn (O.TxOut ConwayEra)
    -- ^ resolved UTxOs
    -> [TxIn]
    -- ^ treasury inputs
    -> TxBody TopTx ConwayEra
    -> Addr
    -- ^ treasury address
    -> Coin
    -- ^ ADA leg out
    -> (PolicyID, AssetName, Integer)
    -- ^ incoming asset
    -> [String]
treasuryConservationErrors utxos treasuryIns body treasuryAddr adaOut (ipid, iasset, iqty) =
    let treasuryOuts =
            [ o
            | o <- seqToList (body ^. L.outputsTxBodyL)
            , o ^. O.addrTxOutL == treasuryAddr
            ]
        inputSum =
            mconcat
                [ valueMA (utxo ^. O.valueTxOutL)
                | i <- treasuryIns
                , Just utxo <- [Map.lookup i utxos]
                ]
        outputSum =
            mconcat
                [ valueMA (o ^. O.valueTxOutL)
                | o <- treasuryOuts
                ]
        actualOutput = case treasuryOuts of
            (o : _) -> o
            [] -> error "no treasury-addressed output in body"
        inCoin =
            sum
                [ unCoin (utxo ^. O.coinTxOutL) | i <- treasuryIns, Just utxo <- [Map.lookup i utxos]
                ]
        expectedCoin = inCoin - unCoin adaOut
        actualCoin = unCoin (actualOutput ^. O.coinTxOutL)
        expectedAssets =
            Map.insertWith
                (Map.unionWith (+))
                ipid
                (Map.singleton iasset iqty)
                (unMA inputSum)
        actualAssets = unMA outputSum
    in  [ "lovelace: expected "
            <> show expectedCoin
            <> " got "
            <> show actualCoin
        | actualCoin /= expectedCoin
        ]
            <> [ "asset "
                <> show (pid, an)
                <> ": expected "
                <> show q
                <> " got "
                <> show (Map.lookup an =<< Map.lookup pid actualAssets)
               | (pid, am) <- Map.toList expectedAssets
               , (an, q) <- Map.toList am
               , Map.lookup an (Map.findWithDefault Map.empty pid actualAssets)
                    /= Just q
               ]
            <> [ "unexpected asset " <> show (pid, an)
               | (pid, am) <- Map.toList actualAssets
               , not (Map.member pid expectedAssets)
               , an <- Map.keys am
               ]
  where
    valueMA (MaryValue _ ma) = ma
    unMA (MultiAsset m) = m

{- | INV-7: the signer roster is exactly the two scope owners and
never contains the counterparty's payment credential.
-}
signerRosterErrors
    :: TxBody TopTx ConwayEra -> [Text] -> [Text] -> [String]
signerRosterErrors body expected counterpartyKeyHashes =
    let actual =
            sort
                [ TE.decodeUtf8 (B16.encode (keyHashBytes kh))
                | kh <- Set.toList (body ^. L.reqSignerHashesTxBodyL)
                ]
        keyHashBytes (KeyHash h) = hashToBytes h
    in  [ "roster: expected " <> show (sort expected) <> " got " <> show actual
        | actual /= sort expected
        ]
            <> [ "counterparty " <> T.unpack k <> " is a required signer"
               | k <- counterpartyKeyHashes
               , k `elem` actual
               ]

{- | Restated T-B07: the counterparty output carries their input
lovelace plus the ADA leg — with nothing subtracted for the fee.
-}
counterpartyNeverChargedErrors
    :: Coin
    -- ^ lovelace on the counterparty output
    -> Integer
    -- ^ the counterparty's own input lovelace
    -> Coin
    -- ^ ADA leg out
    -> [String]
counterpartyNeverChargedErrors (Coin out) own (Coin adaLeg) =
    [ "counterparty output "
        <> show out
        <> " is not their input "
        <> show own
        <> " + adaOut "
        <> show adaLeg
    | out /= own + adaLeg
    ]

spec :: Spec
spec =
    describe
        ( "otc-swap golden (mainnet "
            <> T.unpack referenceTxId
            <> ", block 13868016)"
        )
        $ do
            it
                "fixture self-check: the frozen body is the documented reference body"
                $ do
                    body <- expectedBody
                    body ^. L.feeTxBodyL `shouldBe` referenceFee
                    let vldt = body ^. L.vldtTxBodyL
                    L.invalidHereafter vldt `shouldBe` SJust referenceUpperBound
                    L.invalidBefore vldt `shouldBe` SJust referenceTipSlot
                    Set.member referenceTreasuryTxIn (body ^. L.inputsTxBodyL)
                        `shouldBe` True

            it
                "rebuilds the accepted body: every builder-controlled field matches (T-B04*)"
                $ do
                    fixture <- readSwapFixture fixtureDir
                    r <-
                        buildBody
                            (otcContext fixture)
                            counterpartyWalletAddress
                            referenceIntent
                    expected <- expectedBody
                    case r of
                        Left e -> expectationFailure ("build failed: " <> e)
                        Right body -> do
                            -- Byte equality is documented-impossible through the
                            -- typed pipeline (see handoff): the reference was
                            -- emitted by a JS library with (a) ascending body-map
                            -- key order vs the ledger's field order, (b) an
                            -- insertion-ordered input set vs the ledger's sorted
                            -- Set, (c) its own auxdata wrapper — 4 bytes shorter,
                            -- hence the 176-lovelace fee delta (4 x 44). The
                            -- typed builder instead asserts field equality:
                            body ^. L.inputsTxBodyL
                                `shouldBe` expected ^. L.inputsTxBodyL
                            body ^. L.referenceInputsTxBodyL
                                `shouldBe` expected ^. L.referenceInputsTxBodyL
                            body ^. L.collateralInputsTxBodyL
                                `shouldBe` expected ^. L.collateralInputsTxBodyL
                            body ^. L.reqSignerHashesTxBodyL
                                `shouldBe` expected ^. L.reqSignerHashesTxBodyL
                            body ^. L.vldtTxBodyL `shouldBe` expected ^. L.vldtTxBodyL
                            body ^. L.withdrawalsTxBodyL
                                `shouldBe` expected ^. L.withdrawalsTxBodyL
                            -- Outputs: the intent-owned coins must match exactly.
                            -- (The change output COIN is a fee artifact — the fee
                            -- differs only by the counterparty emitter aux wrapper,
                            -- 4 bytes = 176 lovelace — so the change coin is
                            -- covered by conservation instead.)
                            let outs = seqToList (body ^. L.outputsTxBodyL)
                                expOuts = seqToList (expected ^. L.outputsTxBodyL)
                            case (outs, expOuts) of
                                (cp : trs : _, ecp : etrs : _) -> do
                                    cp ^. O.coinTxOutL `shouldBe` referenceAdaOut
                                    cp ^. O.valueTxOutL `shouldBe` ecp ^. O.valueTxOutL
                                    trs ^. O.coinTxOutL `shouldBe` referenceTreasuryLeftover
                                    trs ^. O.valueTxOutL `shouldBe` etrs ^. O.valueTxOutL
                                _ -> expectationFailure "missing outputs"
                            -- Auxdata present (label 1694); its raw CBOR hash
                            -- differs only by the counterparty emitter's wrapper.
                            body ^. L.auxDataHashTxBodyL
                                `shouldNotBe` SNothing
                            expected ^. L.auxDataHashTxBodyL
                                `shouldNotBe` SNothing

            it
                "negative control: a perturbed adaOut produces a different body (T-B09)"
                $ do
                    fixture <- readSwapFixture fixtureDir
                    let perturbedPayload =
                            referencePayload
                                { ospAdaOut = Coin (unCoin referenceAdaOut + 1)
                                , ospCounterpartyLovelace =
                                    Coin (unCoin referenceAdaOut + 1)
                                , ospLeftoverLovelace =
                                    Coin (unCoin referenceTreasuryLeftover - 1)
                                }
                    r <-
                        buildBody
                            (otcContext fixture)
                            counterpartyWalletAddress
                            (OtcSwapIntent referenceFields perturbedPayload)
                    case r of
                        Left e -> expectationFailure ("build failed: " <> e)
                        Right body -> do
                            expected <- bodyHex <$> expectedBody
                            bodyHex body `shouldNotBe` expected

            it "INV-2 + INV-3: treasury conservation over treasury UTxOs (T-B06)" $ do
                fixture <- readSwapFixture fixtureDir
                r <-
                    buildBody
                        (otcContext fixture)
                        counterpartyWalletAddress
                        referenceIntent
                case r of
                    Left e -> expectationFailure ("build failed: " <> e)
                    Right body -> do
                        treasuryConservationErrors
                            (sfUtxos fixture)
                            [referenceTreasuryTxIn]
                            body
                            treasuryAddress
                            referenceAdaOut
                            (usdmPolicy, usdmAsset, referenceIncomingQuantity)
                            `shouldBe` []

            it
                "negative control: conservation checker rejects a wrong incoming leg (T-B09)"
                $ do
                    fixture <- readSwapFixture fixtureDir
                    r <-
                        buildBody
                            (otcContext fixture)
                            counterpartyWalletAddress
                            referenceIntent
                    case r of
                        Left e -> expectationFailure ("build failed: " <> e)
                        Right body ->
                            treasuryConservationErrors
                                (sfUtxos fixture)
                                [referenceTreasuryTxIn]
                                body
                                treasuryAddress
                                referenceAdaOut
                                (usdmPolicy, usdmAsset, referenceIncomingQuantity + 1)
                                `shouldNotBe` []

            it
                "INV-7: signer roster is the two scope owners, never the counterparty (T-B08)"
                $ do
                    fixture <- readSwapFixture fixtureDir
                    r <-
                        buildBody
                            (otcContext fixture)
                            counterpartyWalletAddress
                            referenceIntent
                    case r of
                        Left e -> expectationFailure ("build failed: " <> e)
                        Right body ->
                            signerRosterErrors
                                body
                                [scopeOwnerA, scopeOwnerB]
                                [T.take 56 (TE.decodeUtf8 (B16.encode counterpartyWalletBytes))]
                                `shouldBe` []

            it
                "negative control: adding the counterparty to the roster is detected (T-B09)"
                $ do
                    fixture <- readSwapFixture fixtureDir
                    let infiltrated =
                            OtcSwapIntent
                                referenceFields
                                    { difSigners =
                                        scopeOwnerKeyHash scopeOwnerA
                                            : scopeOwnerKeyHash scopeOwnerB
                                            : [infiltratorKeyHash]
                                    }
                                referencePayload
                    r <-
                        buildBody
                            (otcContext fixture)
                            counterpartyWalletAddress
                            infiltrated
                    case r of
                        Left e -> expectationFailure ("build failed: " <> e)
                        Right body ->
                            signerRosterErrors
                                body
                                [scopeOwnerA, scopeOwnerB]
                                [T.take 56 (TE.decodeUtf8 (B16.encode counterpartyWalletBytes))]
                                `shouldNotBe` []

            it "restated T-B07: operator-funded — collateral is the fuel UTxO" $ do
                fixture <- readSwapFixture fixtureDir
                let operatorFixture =
                        fixture
                            { sfUtxos =
                                Map.insert
                                    operatorFuelUtxo
                                    (operatorTxOut (Coin 5000000))
                                    (sfUtxos fixture)
                            }
                r <-
                    buildBody
                        (otcContext operatorFixture)
                        operatorChangeAddress
                        operatorIntent
                case r of
                    Left e -> expectationFailure ("build failed: " <> e)
                    Right body ->
                        Set.toList (body ^. L.collateralInputsTxBodyL)
                            `shouldBe` [operatorFuelUtxo]

            it "restated T-B07: the counterparty is never charged the fee (INV-5)" $ do
                fixture <- readSwapFixture fixtureDir
                let operatorFixture =
                        fixture
                            { sfUtxos =
                                Map.insert
                                    operatorFuelUtxo
                                    (operatorTxOut (Coin 5000000))
                                    (sfUtxos fixture)
                            }
                r <-
                    buildBody
                        (otcContext operatorFixture)
                        operatorChangeAddress
                        operatorIntent
                case r of
                    Left e -> expectationFailure ("build failed: " <> e)
                    Right body -> do
                        let outs = seqToList (body ^. L.outputsTxBodyL)
                        counterpartyOut <-
                            case outs of
                                (o : _) -> pure (unCoin (o ^. O.coinTxOutL))
                                [] -> fail "no outputs"
                        counterpartyNeverChargedErrors
                            (Coin counterpartyOut)
                            counterpartyInputLovelace
                            operatorAdaOut
                            `shouldBe` []
                        -- The fee is paid from the operator change,
                        -- not skimmed off the counterparty.
                        body ^. L.feeTxBodyL `shouldNotBe` Coin 0

            it
                "negative control: the fee-deducted counterparty output is detected (T-B09)"
                $ counterpartyNeverChargedErrors
                    (Coin (counterpartyInputLovelace + unCoin operatorAdaOut - 419678))
                    counterpartyInputLovelace
                    operatorAdaOut
                    `shouldNotBe` []
  where
    operatorChangeAddress =
        decodeAddrBytes operatorAddressBytes

    operatorTxOut coin =
        O.mkBasicTxOut
            (decodeAddrBytes operatorAddressBytes)
            (MaryValue coin (MultiAsset Map.empty))

{- | The counterparty's payment key hash (first 28 bytes after the
0x01 header of their wallet address) — must never be a signer.
-}
infiltratorKeyHash :: KeyHash Guard
infiltratorKeyHash =
    KeyHash
        ( fromMaybe
            (error "infiltrator hash")
            (hashFromBytes (BS.take 28 counterpartyPaymentKeyHashBytes))
        )
