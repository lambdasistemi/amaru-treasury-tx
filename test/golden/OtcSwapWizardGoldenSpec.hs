{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : OtcSwapWizardGoldenSpec
Description : T-D08 golden — fixed env + answers produce a fixed intent
License     : Apache-2.0

Issue #499, slice D. The wizard's pure translation is deterministic:
a fixed resolved environment plus fixed typed answers encode to the
same intent.json bytes, pinned against
@test\/fixtures\/otc-swap-wizard\/intent.json@.

Set @UPDATE_GOLDENS=1@ to regenerate the fixture from the checked-in
values. Without that explicit flag a missing or changed file fails.

The pinned bytes exhibit both wire-staging facts the module documents:

* @counterpartyTxIn@ is __singular__ (slice B2 will widen it);
* the scope block's @treasuryLeftoverOtherAssets@ carries __all__
  pre-existing assets, USDM included, because slice C's translation
  routes exactly this map onto the treasury continuing output
  (INV-3).

Negative controls: a mutated stated price is refused by name
(RJ-006) before any bytes exist, and a mutated leg changes the
encoded bytes.
-}
module OtcSwapWizardGoldenSpec (spec) where

import Amaru.Treasury.LedgerParse (txInFromText)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Constants
    ( usdmAssetHex
    , usdmPolicyHex
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.OtcSwapWizard
    ( OtcSwapAnswers (..)
    , OtcSwapCounterpartySelection (..)
    , OtcSwapEnv (..)
    , OtcSwapError (..)
    , OtcSwapTreasurySelection (..)
    , otcSwapToTreasuryIntent
    )
import Amaru.Treasury.Tx.SwapWizard
    ( RationaleAnswers (..)
    , RegistryView (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    , networkConstants
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/otc-swap-wizard"

spec :: Spec
spec = describe "otc-swap-wizard golden (T-D08)" $ do
    it
        "fixed env + answers encode to the pinned intent bytes"
        $ do
            let intent =
                    either
                        (error . T.unpack . T.pack . show)
                        id
                        (otcSwapToTreasuryIntent goldenEnv goldenAnswers)
                bytes =
                    BSL.toStrict
                        ( encodeSomeTreasuryIntent
                            (SomeTreasuryIntent SOtcSwap intent)
                        )
            expectedExists <-
                doesFileExist (fixtureDir <> "/intent.json")
            update <- lookupEnv "UPDATE_GOLDENS"
            case update of
                Just "1" ->
                    BS.writeFile
                        (fixtureDir <> "/intent.json")
                        bytes
                _ ->
                    unless expectedExists $
                        error
                            "missing intent.json; run UPDATE_GOLDENS=1"
            expected <-
                BS.readFile (fixtureDir <> "/intent.json")
            B16.encode bytes `shouldBe` B16.encode expected

    it
        "control: encoding twice is byte-identical (INV-10 restated)"
        $ do
            let intent =
                    either
                        (error "golden translation")
                        id
                        (otcSwapToTreasuryIntent goldenEnv goldenAnswers)
                encode =
                    BSL.toStrict
                        ( encodeSomeTreasuryIntent
                            (SomeTreasuryIntent SOtcSwap intent)
                        )
            encode `shouldBe` encode

    it
        "control: a mutated stated price is refused, not encoded (RJ-006)"
        $ otcSwapToTreasuryIntent
            goldenEnv
            goldenAnswers
                { osaStatedPriceUsdPerAda = "9.99"
                }
            `shouldBe` Left
                (OtcStatedPriceDisagrees "9.99" "0.210000")

    it
        "control: a mutated leg changes the encoded bytes"
        $ do
            let mkIntent answers =
                    either
                        (error "golden translation")
                        id
                        (otcSwapToTreasuryIntent goldenEnv answers)
                encode =
                    BSL.toStrict
                        . encodeSomeTreasuryIntent
                        . SomeTreasuryIntent SOtcSwap
                        . mkIntent
            encode goldenAnswers
                `shouldSatisfy` (/=)
                    ( encode
                        goldenAnswers
                            { osaIncomingQuantity = 15_000_000
                            , osaStatedPriceUsdPerAda = "0.316"
                            }
                    )

-- ----------------------------------------------------
-- The frozen environment and answers
-- ----------------------------------------------------

goldenEnv :: OtcSwapEnv
goldenEnv =
    OtcSwapEnv
        { oeNetwork = "mainnet"
        , oeUpperBoundSlot = 42_000_000
        , oeNetworkConstants =
            either
                (error "mainnet constants")
                id
                (networkConstants "mainnet")
        , oeRegistry = goldenRegistry
        , oeScopeView = goldenScopeView
        , oeWalletSelection =
            WalletSelection
                { wsTxIn = wsTxInText
                , wsAddress = walletAddr
                , wsExtraTxIns = []
                }
        , oeTreasurySelection = goldenTreasurySelection
        , oeCounterpartySelection =
            OtcSwapCounterpartySelection
                { ocsHeadTxIn =
                    either
                        (error "golden txin")
                        id
                        (txInFromText counterpartyTxInText)
                , ocsCount = 1
                , ocsCombinedHolding = 10_000_000
                }
        }

goldenAnswers :: OtcSwapAnswers
goldenAnswers =
    OtcSwapAnswers
        { osaScope = NetworkCompliance
        , osaCounterpartyAddress = counterpartyAddr
        , osaCounterpartyTxIns = []
        , osaAdaOutLovelace = 47_619_047
        , osaIncomingPolicy = usdmPolicyHex
        , osaIncomingAsset = usdmAssetHex
        , osaIncomingQuantity = 10_000_000
        , osaStatedPriceUsdPerAda = "0.21"
        , osaValidityHours = Just 48
        , osaRationale =
            RationaleAnswers
                { raDescription =
                    "Acquire 10 USDM for the network compliance treasury"
                , raJustification =
                    "OTC window at 0.21 USD per ADA; better than the open venue"
                , raDestinationLabel =
                    "Network Compliance treasury"
                , raEvent = Nothing
                , raLabel = Nothing
                }
        , osaExtraSigners = ["ops_and_use_cases"]
        }

goldenRegistry :: RegistryView
goldenRegistry =
    RegistryView
        { rvScopesDeployedAt =
            "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
        , rvPermissionsDeployedAt =
            "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#0"
        , rvTreasuryDeployedAt =
            "87ee53271fb41021efa13c2dbe2998c18ead07d32a6ab6dda184853ed7e39aae#0"
        , rvRegistryDeployedAt =
            "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#0"
        , rvRegistryPolicyId =
            "1e1ee91b8e2bddc9d583d92fd1ba5ea47b8a3e62c1eacb0ec799b99b"
        , rvOwners = goldenOwners
        , rvTreasuryByScope =
            Map.singleton NetworkCompliance goldenTreasuryRefs
        }

goldenOwners :: ScopeOwners
goldenOwners =
    ScopeOwners
        { soCore = T.replicate 56 "1"
        , soOps = T.replicate 56 "2"
        , soNetworkCompliance = T.replicate 56 "3"
        , soMiddleware = T.replicate 56 "4"
        }

goldenTreasuryRefs :: TreasuryRefs
goldenTreasuryRefs =
    TreasuryRefs
        { trAddress = treasuryAddr
        , trScriptHash =
            "5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34"
        , trPermissionsRewardAccount =
            "03ee9cf951e89fb82c47edbff562ee90be17de85b2c24b451c7e8e39"
        }

goldenScopeView :: ScopeView
goldenScopeView =
    ScopeView
        { svScope = NetworkCompliance
        , svRefs = goldenTreasuryRefs
        , svDefaultSigners = [T.replicate 56 "3"]
        }

goldenTreasurySelection :: OtcSwapTreasurySelection
goldenTreasurySelection =
    OtcSwapTreasurySelection
        { otsInputs =
            [ "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc#0"
            ]
        , otsLeftoverLovelace = 2_500_000
        , otsLeftoverUsdm = 100
        , otsLeftoverOtherAssets =
            Map.singleton
                usdmPolicyHex
                (Map.singleton usdmAssetHex 100)
        }

walletAddr, counterpartyAddr, treasuryAddr :: Text
walletAddr =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
counterpartyAddr =
    "addr1qy8ac7qqy0vtulyl7wntmsxc6wex80gvcyjy33qffrhm7sh927ysx5sftuw0dlft05dz3c7revpf7jx0xnlcjz3g69mq4afdhv"
treasuryAddr =
    "addr1x8ndhlcfy30t38z0tql64fpg8ply93r37xrgvdagfpsz5nhxm0lsjfz7hzwy7kpl42jzswr7gtz8ruvxscm6sjrq9f8qruq0ae"

{- | Frozen refs: valid @<txid hex>#<ix>@ strings built from
repeated hex digits — readable and deterministic.
-}
wsTxInText, counterpartyTxInText :: Text
wsTxInText = T.replicate 64 "f" <> "#1"
counterpartyTxInText = T.replicate 64 "b" <> "#1"
