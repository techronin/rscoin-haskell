{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE ViewPatterns        #-}

-- | Module that provides description of what user node can do and
-- functions that runs chosen action.

module Actions
       ( processCommand
       , initializeStorage
       ) where


import           Control.Lens           ((^.))
import           Control.Monad          (forM_, unless, void, when)
import           Control.Monad.IO.Class (MonadIO)
import           Control.Monad.Trans    (liftIO)
import           Data.Acid.Advanced     (query')
import           Data.Bifunctor         (bimap, second)
import qualified Data.ByteString.Base64 as B64
import           Data.Function          (on)
import qualified Data.HashSet           as HS
import           Data.List              (genericIndex, groupBy)
import qualified Data.Map               as M
import           Data.Maybe             (fromJust, fromMaybe, isJust, mapMaybe)
import           Data.Monoid            ((<>))
import qualified Data.Set               as S hiding (Set)
import qualified Data.Text              as T
import           Data.Text.Encoding     (encodeUtf8)
import qualified Data.Text.IO           as TIO
import           Formatting             (build, int, sformat, shown, stext, (%))

import           Serokell.Util.Text     (show')

import qualified RSCoin.Core            as C

import           RSCoin.Core.Strategy   (AllocationInfo (..), PartyAddress (..))
import           RSCoin.Timed           (WorkMode, getNodeContext)
import qualified RSCoin.User            as U
import           RSCoin.User.Error      (eWrap)
import           RSCoin.User.Operations (TransactionData (..),
                                         getAmountNoUpdate, importAddress,
                                         submitTransactionRetry,
                                         updateBlockchain)
import qualified UserOptions            as O


initializeStorage
    :: forall (m :: * -> *).
       (WorkMode m)
    => U.RSCoinUserState
    -> O.UserOptions
    -> m ()
initializeStorage st O.UserOptions{..} =
    U.initState st addressesNum $ bankKeyPath isBankMode bankModePath
  where
    bankKeyPath True p  = Just p
    bankKeyPath False _ = Nothing

-- | Processes command line user command
processCommand
    :: (MonadIO m, WorkMode m)
    => U.RSCoinUserState -> O.UserCommand -> O.UserOptions -> m ()
processCommand st O.ListAddresses _ =
    eWrap $
    do res <- updateBlockchain st False
       unless res $ C.logInfo "Successfully updated blockchain."
       genAddr <- (^.C.genesisAddress) <$> getNodeContext
       addresses <- query' st $ U.GetOwnedAddresses genAddr
       (wallets :: [(C.PublicKey, C.TxStrategy, [C.Coin], Bool)]) <-
           mapM (\addr -> do
                      coins <- C.coinsToList <$> getAmountNoUpdate st addr
                      hasSecret <- isJust . snd <$> query' st (U.FindUserAddress genAddr addr)
                      strategy <- query' st $ U.GetAddressStrategy addr
                      return ( C.getAddress addr
                             , fromMaybe C.DefaultStrategy strategy
                             , coins
                             , hasSecret))
                addresses
       liftIO $ do
           TIO.putStrLn "Here's the list of your accounts:"
           TIO.putStrLn
               "# | Public ID                                    | Amount"
       mapM_ formatAddressEntry ([(1 :: Integer) ..] `zip` wallets)
  where
    spaces = "                                                   "
    formatAddressEntry
        :: (WorkMode m)
        => (Integer, (C.PublicKey, C.TxStrategy, [C.Coin], Bool))
        -> m ()
    formatAddressEntry (i, (key, strategy, coins, hasSecret)) = do
        liftIO $ do
            TIO.putStr $ sformat (int%".  "%build%" : ") i key
            when (null coins) $ putStrLn "empty"
            unless (null coins) $ TIO.putStrLn $ show' $ head coins
            unless (length coins < 2) $
                forM_ (tail coins)
                      (TIO.putStrLn . sformat (spaces % build))
            unless hasSecret $ TIO.putStrLn "    (!! This address doesn't have secret key"
        case strategy of
            C.DefaultStrategy -> return ()
            C.MOfNStrategy m allowed -> do
                genAddr <- (^.C.genesisAddress) <$> getNodeContext
                liftIO $ do
                    TIO.putStrLn $ sformat
                         ("    This is a multisig address ("%int%"/"%int%") controlled by keys: ")
                         m (length allowed)
                    forM_ allowed $ \allowedAddr -> do
                        addresses <- query' st $ U.GetOwnedAddresses genAddr
                        TIO.putStrLn $ sformat
                            (if allowedAddr `elem` addresses
                             then "    * "%build%" owned by you"
                             else "    * "%build)
                            allowedAddr
processCommand st (O.FormTransaction inputs outputAddrStr outputCoins cache) _ =
    eWrap $
    do let outputAddr = C.Address <$> C.constructPublicKey outputAddrStr
           inputs' = map (foldr1 (\(a,b) (_,d) -> (a, b ++ d))) $
                     groupBy ((==) `on` snd) $
                     map (\(idx,o,c) -> (idx - 1, [C.Coin (C.Color c) (C.CoinAmount $ toRational o)]))
                     inputs
           outputs' = map (uncurry (flip C.Coin) . bimap (C.CoinAmount . toRational) C.Color)
                          outputCoins
           td = TransactionData
                { tdInputs = inputs'
                , tdOutputAddress = fromJust outputAddr
                , tdOutputCoins = outputs'
                }
       unless (isJust outputAddr) $
           U.commitError $ "Provided key can't be exported: " <> outputAddrStr
       tx <- submitTransactionRetry 2 st cache td
       C.logInfo $
           sformat ("Successfully submitted transaction with hash: " % build) $
               C.hash tx
processCommand st O.UpdateBlockchain _ =
    eWrap $
    do res <- updateBlockchain st True
       C.logInfo $
           if res
               then "Blockchain is updated already."
               else "Successfully updated blockchain."
processCommand st (O.Dump command) _ = eWrap $ dumpCommand st command
processCommand _ (O.SignSeed seedB64 mPath) _ = liftIO $ do
    sk <- maybe (pure $ error "Attain secret key is not defined!") C.readSecretKey mPath
    (seedPk, _) <- case B64.decode $ encodeUtf8 seedB64 of
              Left _ -> fail "Wrong seed supplied (base64 decoding failed)"
              Right s ->
                  maybe (fail "Failed to derive keypair from seed") pure $
                      C.deterministicKeyGen s
    liftIO $ TIO.putStrLn $
       sformat ("Seed Pk: " % build) seedPk
    let (pk, sig) = (C.derivePublicKey sk, C.sign sk seedPk)
    liftIO $ TIO.putStrLn $
       sformat ("AttPk: " % build % ", AttSig: " % build % ", verifyChain: " % build)
           pk sig (C.verifyChain pk [(sig, seedPk)])
processCommand
    st
    (O.CreateMultisigAddress m
                             textUAddrs
                             textTAddrs
                             masterPkText
                             masterSlaveSigText
    )
    _
  = do
    when (null textUAddrs && null textTAddrs) $
        U.commitError "Can't create multisig with empty addrs list"

    userAddrs  <- map C.UserAlloc  <$> parseTextAddresses textUAddrs
    trustAddrs <- map C.TrustAlloc <$> parseTextAddresses textTAddrs
    let partiesAddrs = userAddrs ++ trustAddrs
    when (m > length partiesAddrs) $
        U.commitError "Parameter m should be less than length of list"

    msPublicKey <- snd <$> liftIO C.keyGen
    (userAddress, userSk) <- head <$> query' st U.GetUserAddresses
    let msAddr    = C.Address msPublicKey
    let partyAddr = C.UserParty userAddress
    let msStrat   = C.AllocationStrategy m $ HS.fromList partiesAddrs
    let userSignature   = C.sign userSk (msAddr, msStrat)
    -- @TODO: replace with Either and liftA2
    let !masterPk       = fromMaybe
                             (error "Master pk is not parseable!")
                             (C.constructPublicKey masterPkText)
    let !masterSlaveSig = fromMaybe
                             (error "Master slave signature is not parseable!")
                             (C.constructSignature masterSlaveSigText)

    C.allocateMultisignatureAddress
        msAddr
        partyAddr
        msStrat
        userSignature
        (masterPk, masterSlaveSig)

    liftIO $ TIO.putStrLn $
       sformat ("Your new address will be added in the next block: " % build) msPublicKey
  where
    parseTextAddresses :: WorkMode m => [T.Text] -> m [C.Address]
    parseTextAddresses textAddrs = do
        let partiesAddrs = mapMaybe (fmap C.Address . C.constructPublicKey) textAddrs
        when (length partiesAddrs /= length textAddrs) $ do
            let parsed = T.unlines (map show' partiesAddrs)
            U.commitError $
                sformat ("Some addresses were not parsed, parsed only those: " % stext) parsed
        return partiesAddrs
processCommand
    st
    (O.ConfirmAllocation i
                         mHot
                         masterPkText
                         masterSlaveSigText
    )
    _
  = eWrap $ do
    when (i <= 0) $ U.commitError $
        sformat ("Index i should be greater than 0 but given: " % int) i

    (msAddr, C.AllocationInfo{..}) <- query' st $ U.GetAllocationByIndex (i - 1)
    (slaveSk, partyAddr)           <- case mHot of
        Just (read -> (hotSkPath, partyPkStr)) -> do
            hotSk <- liftIO $ C.readSecretKey hotSkPath
            let party     = C.Address $ fromMaybe
                              (error "Not valid hot partyPk!")
                              (C.constructPublicKey $ T.pack partyPkStr)
            let partyAddr = C.TrustParty { partyAddress = party
                                         , hotTrustKey  = C.derivePublicKey hotSk }
            return (hotSk, partyAddr)
        Nothing -> do
            (userAddress, userSk) <- head <$> query' st U.GetUserAddresses
            return (userSk, C.UserParty userAddress)

    let partySignature  = C.sign slaveSk (msAddr, _allocationStrategy)
    let !masterPk       = fromMaybe
                             (error "Master pk is not parseable!")
                             (C.constructPublicKey masterPkText)
    let !masterSlaveSig = fromMaybe
                             (error "Master slave signature is not parseable!")
                             (C.constructSignature masterSlaveSigText)

    C.allocateMultisignatureAddress
        msAddr
        partyAddr
        _allocationStrategy
        partySignature
        (masterPk, masterSlaveSig)

    liftIO $ TIO.putStrLn "Address allocation successfully confirmed!"
processCommand st O.ListAllocations _ = eWrap $ do
    -- update local cache
    U.retrieveAllocationsList st
    msAddrsList <- query' st U.GetAllocationStrategies
    liftIO $ TIO.putStrLn $ T.pack $ show msAddrsList
    msigAddrsList <- (`zip` [(1::Int)..]) . M.assocs <$> query' st U.GetAllocationStrategies
    when (null msigAddrsList) $
        liftIO $ putStrLn "Allocation address list is empty"
    forM_ msigAddrsList $ \((addr,allocStrat), i) -> do
        let numLength = length $ show i
        let padding = foldr1 (%) (replicate numLength " ")
        let form = int % ". " % build % "\n  " % build % padding
        liftIO $ TIO.putStrLn $ sformat form i addr allocStrat
processCommand st (O.ImportAddress skPathMaybe pkPath heightFrom heightTo) _ = do
    pk <- liftIO $ TIO.putStrLn "Reading pk..." >> C.readPublicKey pkPath
    sk <- liftIO $ flip (maybe (return Nothing)) skPathMaybe $ \skPath ->
        TIO.putStrLn "Reading sk..." >> Just <$> C.readSecretKey skPath
    liftIO $ TIO.putStrLn "Starting blockchain query process"
    importAddress st (sk,pk) heightFrom heightTo
    liftIO $ TIO.putStrLn "Finished, your address successfully added"
processCommand st (O.ExportAddress addrId filepath) _ = do
    genAddr <- (^.C.genesisAddress) <$> getNodeContext
    allAddresses <- query' st $ U.GetOwnedDefaultAddresses genAddr
    let addrN = length allAddresses
    when (addrId `notElem` [1 .. addrN]) $
        U.commitError $
        sformat
            ("You have " % int % " addresses, but address #" % int %
             " was requested that's out of range [1.." %
             int)
            addrN
            addrId
            addrN
    let addr = allAddresses !! (addrId -1)
    strategy <- fromJust <$> query' st (U.GetAddressStrategy addr)
    case strategy of
        C.DefaultStrategy -> do
            C.logInfo
                "The strategy of your address is default, dumping it to the file"
            (addr'@(C.getAddress->pk),sk) <-
                second fromJust <$> query' st (U.FindUserAddress genAddr addr)
            unless (addr' == addr) $
                C.logError $
                "Internal error, address found is not the same " <>
                "as requested one for default strategy"
            liftIO $ C.writeSecretKey filepath sk
            liftIO $ C.writePublicKey (filepath <> ".pub") pk
            C.logInfo $ sformat
                ("Dumped secret key into " % shown % ", public into " %
                 shown % ".pub") filepath filepath
        C.MOfNStrategy m parties ->
            U.commitError $
                sformat ("This address is " % int % "/" % int %
                         " strategy address, export correspondent key instead. " %
                         "Correspondent m/n key are autoexported " %
                         "when you import their party.") m (S.size parties)

dumpCommand
    :: WorkMode m
    => U.RSCoinUserState -> O.DumpCommand -> m ()
dumpCommand _ O.DumpMintettes = void C.getMintettes
dumpCommand _ O.DumpAddresses = void C.getAddresses
dumpCommand _ O.DumpPeriod = void C.getBlockchainHeight
dumpCommand _ (O.DumpHBlocks from to) = void $ C.getBlocksByHeight from to
dumpCommand _ (O.DumpHBlock pId) = void $ C.getBlockByHeight pId
dumpCommand _ (O.DumpLogs mId from to) = void $ C.getLogs mId from to
dumpCommand _ (O.DumpMintetteUtxo mId) = void $ C.getMintetteUtxo mId
dumpCommand _ (O.DumpMintetteBlocks mId pId) =
    void $ C.getMintetteBlocks mId pId
dumpCommand _ (O.DumpMintetteLogs mId pId) = void $ C.getMintetteLogs mId pId
dumpCommand st (O.DumpAddress idx) =
    liftIO . TIO.putStrLn . show' . (`genericIndex` (idx - 1)) =<<
    (\ctx -> query' st (U.GetOwnedAddresses (ctx^.C.genesisAddress))) =<<
    getNodeContext
