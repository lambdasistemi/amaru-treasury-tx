{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.ReorganizeWizardSpec
Description : Unit tests for the reorganize-wizard resolver + translator
License     : Apache-2.0

S1 of #187 (the runner-body library half). Drives
'resolveReorganize' + 'reorganizeToIntent' via a mock
'ReorganizeResolverEnv' in 'Identity', covering the resolver
contract, the pure translator field mapping, and the JSON
round-trip property.
-}
module Amaru.Treasury.Tx.ReorganizeWizardSpec (spec) where

import Data.Functor.Identity (Identity (..))
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    )
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))

import Cardano.Node.Client.Validity qualified as Validity

import Amaru.Treasury.IntentJSON
    ( ReorganizeInputs (..)
    , SAction (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    , decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , mkHash28
    , parseNetwork
    )
import Amaru.Treasury.LedgerParse (txInFromText, txInToText)
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.ReorganizeWizard
    ( ReorganizeEnv (..)
    , ReorganizeError (..)
    , ReorganizeResolverEnv (..)
    , ReorganizeResolverInput (..)
    , ReorganizeWizardAnswers (..)
    , reorganizeToIntent
    , resolveReorganize
    )
import Amaru.Treasury.Tx.SwapWizard (WalletSelection (..))

spec :: Spec
spec = describe "ReorganizeWizard" $ do
    describe "resolveReorganize" $ do
        it "resolves the happy path in cheap-first order" $ do
            let result =
                    runIdentity
                        ( resolveReorganize
                            happyResolverEnv
                            sampleInput
                        )
            result
                `shouldBe` Right
                    ReorganizeEnv
                        { reNetwork = "devnet"
                        , reUpperBoundSlot = sampleUpperBound
                        , reMetadata = sampleMetadata
                        , reScopeMetadata = sampleScope
                        , reWalletSelection =
                            WalletSelection
                                { wsTxIn = walletTxRef
                                , wsAddress = walletAddr
                                , wsExtraTxIns = []
                                }
                        , reTreasuryUtxos =
                            treasuryTxRefA :| [treasuryTxRefB]
                        }

        it
            "admits any resolved network (mainnet) and \
            \forwards the name into the resolved environment"
            $ do
                let result =
                        runIdentity
                            ( resolveReorganize
                                happyResolverEnv
                                sampleInput{rriNetwork = "mainnet"}
                            )
                case result of
                    Right env ->
                        reNetwork env `shouldBe` "mainnet"
                    Left e ->
                        expectationFailure
                            ( "expected resolver to admit mainnet, got: "
                                <> show e
                            )

        it "wraps metadata read failures" $
            resolveWith
                happyResolverEnv
                    { sreReadMetadata =
                        \_ -> Identity (Left "missing metadata")
                    }
                `shouldBe` Left
                    (ReorganizeMetadataReadError "missing metadata")

        it "rejects a scope absent from metadata" $
            resolveWith
                happyResolverEnv
                    { sreReadMetadata =
                        \_ ->
                            Identity
                                ( Right
                                    sampleMetadata
                                        { tmTreasuries =
                                            Map.delete
                                                CoreDevelopment
                                                ( tmTreasuries
                                                    sampleMetadata
                                                )
                                        }
                                )
                    }
                `shouldBe` Left
                    ( ReorganizeScopeNotInMetadata
                        CoreDevelopment
                    )

        it "rejects a scope with no owner" $
            resolveWithInput happyResolverEnv sampleInput{rriScope = Contingency}
                `shouldBe` Left
                    (ReorganizeScopeOwnerMissing Contingency)

        it "rejects an empty wallet query as a wallet shortfall" $
            resolveWith
                happyResolverEnv
                    { sreQueryWalletUtxos = \_ -> Identity []
                    }
                `shouldBe` Left ReorganizeWalletShortfall

        it "rejects zero treasury UTxOs" $
            resolveWith
                happyResolverEnv
                    { sreQueryTreasuryUtxos = \_ -> Identity []
                    }
                `shouldBe` Left
                    (ReorganizeInsufficientTreasuryUtxos 0)

        it "rejects one treasury UTxO" $
            resolveWith
                happyResolverEnv
                    { sreQueryTreasuryUtxos =
                        \_ ->
                            Identity
                                [ (treasuryTxRefA, 1_000_000, False)
                                ]
                    }
                `shouldBe` Left
                    (ReorganizeInsufficientTreasuryUtxos 1)

        it "rejects validity-hours zero" $
            resolveWithInput
                happyResolverEnv
                sampleInput{rriValidityHours = Just 0}
                `shouldBe` Left ReorganizeValidityHoursZero

        it "wraps upper-bound horizon errors" $
            resolveWith
                happyResolverEnv
                    { sreComputeUpperBound =
                        \_ -> Identity (Left sampleHorizonError)
                    }
                `shouldBe` Left
                    (ReorganizeValidityOvershoot sampleHorizonError)

        it "rejects malformed treasury row references" $
            resolveWith
                happyResolverEnv
                    { sreQueryTreasuryUtxos =
                        \_ ->
                            Identity
                                [ ("not-a-txin", 1_000_000, False)
                                , (treasuryTxRefB, 1_000_000, False)
                                ]
                    }
                `shouldSatisfy` \case
                    Left
                        ( ReorganizeLedgerFieldParseError
                                "treasuryUtxos[0]"
                                _
                            ) -> True
                    _ -> False

    describe "reorganizeToIntent" $
        it
            "maps the resolved env to SReorganize intent JSON \
            \and round-trips"
            happyTranslator

resolveWith
    :: ReorganizeResolverEnv Identity
    -> Either ReorganizeError ReorganizeEnv
resolveWith env =
    resolveWithInput env sampleInput

resolveWithInput
    :: ReorganizeResolverEnv Identity
    -> ReorganizeResolverInput
    -> Either ReorganizeError ReorganizeEnv
resolveWithInput env input =
    runIdentity (resolveReorganize env input)

happyTranslator :: IO ()
happyTranslator = do
    resolved <-
        case resolveWith happyResolverEnv of
            Right env -> pure env
            Left e ->
                expectationFailure ("resolveReorganize failed: " <> show e)
                    >> error "unreachable"
    intent <-
        case reorganizeToIntent resolved sampleAnswers of
            Right i -> pure i
            Left e ->
                expectationFailure ("reorganizeToIntent failed: " <> show e)
                    >> error "unreachable"
    decodeTreasuryIntent (encodeSomeTreasuryIntent intent)
        `shouldBe` Right intent
    case intent of
        SomeTreasuryIntent SReorganize ti -> do
            tiNetwork ti `shouldBe` "devnet"
            tiSigners ti `shouldBe` [ownerHash]
            tiValidityUpperBoundSlot ti `shouldBe` sampleUpperBound
            wjTxIn (tiWallet ti) `shouldBe` txInToText fundingSeedTxIn
            wjAddress (tiWallet ti) `shouldBe` walletAddr
            wjExtraTxIns (tiWallet ti) `shouldBe` []
            let payload = tiPayload ti
            riWalletUtxo payload `shouldBe` fundingSeedTxIn
            riTreasuryUtxos payload
                `shouldBe` parsedTreasuryTxRefA
                    :| [parsedTreasuryTxRefB]
            riUpperBound payload `shouldBe` SlotNo sampleUpperBound
            riPermissionsRewardAccount payload
                `shouldBe` expectedPermissionsRewardAccount
        _ -> expectationFailure "expected SReorganize intent"

sampleInput :: ReorganizeResolverInput
sampleInput =
    ReorganizeResolverInput
        { rriNetwork = "devnet"
        , rriWalletAddrBech32 = walletAddr
        , rriMetadataPath = "metadata.json"
        , rriScope = CoreDevelopment
        , rriValidityHours = Nothing
        }

sampleAnswers :: ReorganizeWizardAnswers
sampleAnswers =
    ReorganizeWizardAnswers
        { rwaWalletAddr = walletAddr
        , rwaMetadataPath = "metadata.json"
        , rwaScope = CoreDevelopment
        , rwaValidityHours = Nothing
        , rwaDescription = Nothing
        , rwaJustification = Nothing
        , rwaDestinationLabel = Nothing
        , rwaEvent = Nothing
        , rwaLabel = Nothing
        , rwaFundingSeedTxIn = Just fundingSeedTxIn
        }

happyResolverEnv :: ReorganizeResolverEnv Identity
happyResolverEnv =
    ReorganizeResolverEnv
        { sreReadMetadata =
            \_ -> Identity (Right sampleMetadata)
        , sreQueryWalletUtxos =
            \_ -> Identity [(walletTxRef, 5_000_000, False)]
        , sreQueryTreasuryUtxos =
            \_ ->
                Identity
                    [ (treasuryTxRefB, 2_000_000, False)
                    , (treasuryTxRefA, 3_000_000, False)
                    ]
        , sreComputeUpperBound =
            \_ -> Identity (Right sampleUpperBound)
        }

effectMustNotRunResolverEnv :: ReorganizeResolverEnv Identity
effectMustNotRunResolverEnv =
    ReorganizeResolverEnv
        { sreReadMetadata =
            \_ -> error "sreReadMetadata must not run"
        , sreQueryWalletUtxos =
            \_ -> error "sreQueryWalletUtxos must not run"
        , sreQueryTreasuryUtxos =
            \_ -> error "sreQueryTreasuryUtxos must not run"
        , sreComputeUpperBound =
            \_ -> error "sreComputeUpperBound must not run"
        }

sampleMetadata :: TreasuryMetadata
sampleMetadata =
    TreasuryMetadata
        { tmScopeOwners =
            "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
        , tmTreasuries =
            Map.fromList
                [ (CoreDevelopment, sampleScope)
                , (Contingency, contingencyScope)
                ]
        }

sampleScope :: ScopeMetadata
sampleScope =
    ScopeMetadata
        { smOwner = Just ownerHash
        , smBudget = Just 2_575_000
        , smAddress =
            "addr1x90mk0jjjhppr36ethwj8kewpgyrxyc7q6qucl4gqru96dzlhvl999wzz8r4jhway0djuzsgxvf3up5pe3l2sq8ct56qtjz6ah"
        , smTreasury =
            ScriptRef
                { srHash =
                    "5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34"
                , srDeployedAt =
                    "87ee53271fb41021efa13c2dbe2998c18ead07d32a6ab6dda184853ed7e39aae#0"
                }
        , smPermissions =
            ScriptRef
                { srHash =
                    "03ee9cf951e89fb82c47edbff562ee90be17de85b2c24b451c7e8e39"
                , srDeployedAt =
                    "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#0"
                }
        , smRegistry =
            ScriptRef
                { srHash =
                    "1e1ee91b8e2bddc9d583d92fd1ba5ea47b8a3e62c1eacb0ec799b99b"
                , srDeployedAt =
                    "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#0"
                }
        }

contingencyScope :: ScopeMetadata
contingencyScope = sampleScope{smOwner = Nothing}

expectedPermissionsRewardAccount :: AccountAddress
expectedPermissionsRewardAccount =
    let network =
            unsafeRight "network" (parseNetwork "devnet")
        bytes =
            unsafeRight
                "permissions script hash"
                (decodeHexBytes 28 (srHash (smPermissions sampleScope)))
    in  AccountAddress
            network
            (AccountId (ScriptHashObj (ScriptHash (mkHash28 bytes))))

sampleHorizonError :: Validity.HorizonError
sampleHorizonError =
    Validity.HorizonError
        { Validity.heRequestedSlot = SlotNo 10
        , Validity.heHorizonSlot = SlotNo 9
        , Validity.heTipSlot = SlotNo 1
        , Validity.heRequestedHours = 24
        }

walletAddr :: Text
walletAddr =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

ownerHash :: Text
ownerHash =
    "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"

walletTxRef :: Text
walletTxRef = txRef "a" 0

treasuryTxRefA :: Text
treasuryTxRefA = txRef "b" 0

treasuryTxRefB :: Text
treasuryTxRefB = txRef "c" 1

fundingSeedTxIn :: TxIn
fundingSeedTxIn = unsafeRight "funding seed txin" (txInFromText walletTxRef)

parsedTreasuryTxRefA :: TxIn
parsedTreasuryTxRefA =
    unsafeRight "treasury txin A" (txInFromText treasuryTxRefA)

parsedTreasuryTxRefB :: TxIn
parsedTreasuryTxRefB =
    unsafeRight "treasury txin B" (txInFromText treasuryTxRefB)

sampleUpperBound :: Word64
sampleUpperBound = 1_000_100

txRef :: Text -> Integer -> Text
txRef nibble ix =
    T.replicate 64 nibble <> "#" <> T.pack (show ix)

unsafeRight :: String -> Either String a -> a
unsafeRight label = \case
    Right a -> a
    Left e -> error (label <> ": " <> e)
