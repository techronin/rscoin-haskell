{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Re-export RSCoin.Test.*

module RSCoin.Test
       ( module Exports
       , WorkMode
       , runRealMode, runRealMode_
       , runEmulationMode
       ) where

import           RSCoin.Test.MonadTimed         as Exports
import           RSCoin.Test.Timed              as Exports
import           RSCoin.Test.MonadRpc           as Exports
import           RSCoin.Test.PureRpc            as Exports
import           RSCoin.Test.Misc               as Exports

import           Control.Monad.Catch            (MonadMask)
import           Control.Monad.Trans            (MonadIO)
import           System.Random                  (StdGen)

class (MonadTimed m, MonadRpc m, MonadIO m,
       MonadMask m) => WorkMode m where

instance (MonadTimed m, MonadRpc m, MonadIO m,
       MonadMask m) => WorkMode m

runRealMode :: MsgPackRpc a -> IO a
runRealMode  =  runTimedIO . runMsgPackRpc

runRealMode_ :: MsgPackRpc a -> IO ()
runRealMode_  =  runTimedIO_ . runMsgPackRpc

runEmulationMode :: PureRpc IO () -> Delays -> StdGen -> IO ()
runEmulationMode   =  runPureRpc 
