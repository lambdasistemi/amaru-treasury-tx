{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Main
Description : Swap-tx parity probe (live mainnet build)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

A one-shot harness that reproduces the swap CBOR pasted
by the user. Connects to a local mainnet @cardano-node@,
queries the live UTxOs referenced in the original tx,
runs the full
'Amaru.Treasury.Tx.SwapBuild.runSwapBuild' driver,
re-evaluates every redeemer against the final tx, then
writes the resulting CBOR (hex) to stdout for a
byte-level diff against
@/code/swap-experiment/user-final.hex@.

All inputs (TxIns, addresses, key hashes, chunk sizes,
sundae fee, USDM unit, rationale copy) are pinned to the
user's original swap. The probe is intentionally not a
generic CLI; it exists to validate parity, and its
hard-coded values fold into the real CLI driver in
@app\/amaru-treasury-tx\/Main.hs@.
-}
module Main (main) where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Word (Word8)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (stderr)
import System.IO qualified as IO

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.AuxData (swapRationaleMetadatum)
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.ChainContext (liveContext)
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderDatumParams (..)
    , SwapOrderOut (..)
    , swapOrderDatum
    )
import Amaru.Treasury.Tx.SwapBuild
    ( ScriptResult (..)
    , SwapBuildInputs (..)
    , SwapBuildResult (..)
    , runSwapBuild
    )

-- ----------------------------------------------------
-- Pinned constants (user's swap from this morning)
-- ----------------------------------------------------

mainnetMagic :: NetworkMagic
mainnetMagic = NetworkMagic 764_824_073

defaultSocket :: FilePath
defaultSocket = "/code/cardano-mainnet/ipc/node.socket"

unhex :: ByteString -> ByteString
unhex h =
    case B16.decode h of
        Right bs -> bs
        Left e -> error ("unhex: " ++ e ++ " on " ++ show h)

hash28 :: (HashAlgorithm h) => ByteString -> Hash h a
hash28 bs =
    fromMaybe
        (error "hash28: not 28 bytes")
        (hashFromBytes bs)

hash32 :: (HashAlgorithm h) => ByteString -> Hash h a
hash32 bs =
    fromMaybe
        (error "hash32: not 32 bytes")
        (hashFromBytes bs)

txInFromHex :: ByteString -> Word8 -> TxIn
txInFromHex hHex ix =
    TxIn
        (TxId (unsafeMakeSafeHash (hash32 (unhex hHex))))
        (mkTxIxPartial (toInteger ix))

walletInput
    , treasuryInput
    , scopesRefIn
    , permissionsRefIn
    , treasuryRefIn
    , registryRefIn
        :: TxIn
walletInput =
    txInFromHex
        "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0"
        0
treasuryInput =
    txInFromHex
        "64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0"
        0
scopesRefIn =
    txInFromHex
        "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54"
        0
permissionsRefIn =
    txInFromHex
        "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c"
        0
treasuryRefIn =
    txInFromHex
        "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095"
        2
registryRefIn =
    txInFromHex
        "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c"
        2

walletAddr :: Addr
walletAddr =
    Addr
        Mainnet
        ( KeyHashObj
            ( KeyHash
                ( hash28
                    ( unhex
                        "dea7197ac235d73e7f7b1a249bace6a833722415d88e91dec5d2626d"
                    )
                )
            )
        )
        ( StakeRefBase
            ( KeyHashObj
                ( KeyHash
                    ( hash28
                        ( unhex
                            "bc1597ad71c55d2d009a9274b3831ded155118dd769f5376decc1369"
                        )
                    )
                )
            )
        )

treasuryScriptHashRaw :: ByteString
treasuryScriptHashRaw =
    unhex "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

treasuryAddr, swapOrderAddr :: Addr
treasuryAddr =
    Addr
        Mainnet
        (ScriptHashObj (ScriptHash (hash28 treasuryScriptHashRaw)))
        ( StakeRefBase
            (ScriptHashObj (ScriptHash (hash28 treasuryScriptHashRaw)))
        )
swapOrderAddr =
    Addr
        Mainnet
        ( ScriptHashObj
            ( ScriptHash
                ( hash28
                    ( unhex
                        "fa6a58bbe2d0ff05534431c8e2f0ef2cbdc1602a8456e4b13c8f3077"
                    )
                )
            )
        )
        ( StakeRefBase
            (ScriptHashObj (ScriptHash (hash28 treasuryScriptHashRaw)))
        )

permissionsAcct :: AccountAddress
permissionsAcct =
    AccountAddress
        Mainnet
        ( AccountId
            ( ScriptHashObj
                ( ScriptHash
                    ( hash28
                        ( unhex
                            "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"
                        )
                    )
                )
            )
        )

signerMiddleware, signerNetworkCompliance :: KeyHash Guard
signerMiddleware =
    KeyHash
        ( hash28
            (unhex "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1")
        )
signerNetworkCompliance =
    KeyHash
        ( hash28
            (unhex "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e")
        )

datumParams :: SwapOrderDatumParams
datumParams =
    SwapOrderDatumParams
        { sodPoolId =
            unhex "64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef"
        , sodCoreOwner =
            unhex "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
        , sodOpsOwner =
            unhex "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
        , sodNetworkComplianceOwner =
            unhex "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
        , sodMiddlewareOwner =
            unhex "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
        , sodSundaeProtocolFeeLovelace = 1_280_000
        , sodTreasuryScriptHash = treasuryScriptHashRaw
        , sodUsdmPolicy =
            unhex "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
        , sodUsdmToken = unhex "0014df105553444d"
        }

registryPolicyId :: ByteString
registryPolicyId =
    unhex "38c627d45835744a2d6c727124f2b5852e5564aeab3f608e0e84ea6d"

extraPerChunk :: Coin
extraPerChunk = Coin 3_280_000

chunkSize, amountLovelace :: Integer
chunkSize = 12_500_000_000
amountLovelace = 408_163_265_306

ttlUpperBound :: SlotNo
ttlUpperBound = SlotNo 186_364_542

mkChunks :: [SwapOrderOut]
mkChunks =
    let full = amountLovelace `div` chunkSize
        rem' = amountLovelace `mod` chunkSize
        fullChunk =
            SwapOrderOut
                (Coin chunkSize)
                ( swapOrderDatum
                    datumParams
                    chunkSize
                    (chunkSize * 245 `div` 1_000)
                )
        remChunk =
            SwapOrderOut
                (Coin rem')
                ( swapOrderDatum
                    datumParams
                    rem'
                    (rem' * 245 `div` 1_000 + 1)
                )
        fulls = replicate (fromInteger full) fullChunk
    in  if rem' > 0 then fulls ++ [remChunk] else fulls

intent :: SwapIntent
intent =
    SwapIntent
        { siWalletUtxo = walletInput
        , siSwapOrderAddress = swapOrderAddr
        , siSwapOrders = mkChunks
        , siSwapOrderExtraLovelace = extraPerChunk
        , siTreasuryUtxos = [treasuryInput]
        , siTreasuryAddress = treasuryAddr
        , siTreasuryLeftoverLovelace = Coin 1_041_836_734_694
        , siTreasuryLeftoverAsset = Nothing
        , siRedeemerAmountLovelace = Coin amountLovelace
        , siPermissionsRewardAccount = permissionsAcct
        , siScopesDeployedAt = scopesRefIn
        , siPermissionsDeployedAt = permissionsRefIn
        , siTreasuryDeployedAt = treasuryRefIn
        , siRegistryDeployedAt = registryRefIn
        , siSigners =
            [ signerNetworkCompliance
            , signerMiddleware
            ]
        , siUpperBound = ttlUpperBound
        }

main :: IO ()
main = do
    socket <-
        fromMaybe defaultSocket
            <$> lookupEnv "CARDANO_NODE_SOCKET_PATH"
    IO.hPutStrLn stderr $ "swap-probe: connecting to " <> socket
    withLocalNodeBackend mainnetMagic socket $ \backend -> do
        IO.hPutStrLn stderr "swap-probe: capturing chain context"
        ctx <-
            liveContext
                backend
                ( Set.fromList
                    [ walletInput
                    , treasuryInput
                    , scopesRefIn
                    , permissionsRefIn
                    , treasuryRefIn
                    , registryRefIn
                    ]
                )
        IO.hPutStrLn stderr "swap-probe: building tx"
        let inputs =
                SwapBuildInputs
                    { sbiIntent = intent
                    , sbiRationale =
                        swapRationaleMetadatum
                            "Swapping ADA for $100k at a rate of $0.245 per ADA"
                            "Network Compliance's treasury"
                            "Required to pay Antithesis as vendor"
                            registryPolicyId
                    , sbiWalletTxIn = walletInput
                    , sbiWalletAddr = walletAddr
                    , sbiCollateralPercent = 150
                    }
        SwapBuildResult{..} <- runSwapBuild ctx inputs
        let cborStrict = BSL.toStrict sbrCborBytes
            hexed = B16.encode cborStrict
            Coin feeLov = sbrFeeLovelace
            Coin tcLov = sbrTotalCollateralLovelace
        IO.hPutStrLn stderr $
            "swap-probe: emitted "
                <> show (BS.length cborStrict)
                <> " bytes  fee="
                <> show feeLov
                <> "  total_collateral="
                <> show tcLov
        let failures =
                [ (purpose, e)
                | ScriptResult purpose (Left e) <-
                    sbrScriptResults
                ]
        IO.hPutStrLn stderr $
            "swap-probe: re-evaluated "
                <> show (length sbrScriptResults)
                <> " redeemers, "
                <> show (length failures)
                <> " failed"
        mapM_
            ( \(p, e) ->
                IO.hPutStrLn stderr $
                    "  FAIL: " <> show p <> " — " <> e
            )
            failures
        BS.putStr hexed
        putStr "\n"
        if null failures
            then IO.hPutStrLn stderr "swap-probe: VALIDATION OK"
            else do
                IO.hPutStrLn
                    stderr
                    "swap-probe: VALIDATION FAILED"
                exitFailure
        case failures of
            [] -> pure ()
            _ -> throwIO (userError "swap-probe: script failure")
