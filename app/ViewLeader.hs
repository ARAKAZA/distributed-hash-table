{-# LANGUAGE RecordWildCards #-}
module ViewLeader where

import Control.Concurrent
import Control.Monad
import Control.Monad.STM
import Control.Concurrent.STM.TVar
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer.Strict
import qualified STMContainers.Map as M
import qualified ListT
import Control.Exception
import Data.UnixTime
import Network.Socket hiding (recv)
import Network.Socket.ByteString (recv, sendAll)
import qualified Network.Socket.ByteString as L
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.ByteString.Char8 as B
import qualified Data.Serialize as S
import qualified Data.Aeson as JSON
import System.Console.Chalk
import System.Timeout
import System.Exit

import RPC
import RPC.Socket

data ServerCondition = ServerCondition
  { -- ^ Denotes the last valid heartbeat time. Late heartbeats will not update.
    lastHeartbeatTime :: UnixTime
  , isActive          :: Bool
  , serverAddr        :: SockAddr
  }

-- | A type for mutable state.
data MutState = MutState
  { -- ^ Heartbeats are held in a map. When we don't receive a heartbeat
    -- for 30 sec, then we won't accept any heartbeat with the same UUID.
    heartbeats :: M.Map UUIDString ServerCondition
  , epoch      :: TVar Int
  -- ^ A lock will hold the lock name and an identifier that server calls itself.
  -- This is different from the UUIDString values we hold, they are arbitrary.
  -- If a key exists in the map, then there's a lock on that lock name.
  -- To delete a lock, you have to delete the key from the map.
  , locks      :: M.Map String String
  }

initialState :: IO MutState
initialState = MutState <$> M.newIO <*> newTVarIO 0 <*> M.newIO

-- | Runs the command with side effects and returns the response that is to be
-- sent back to the client.
runCommand :: (Int, ViewLeaderCommand) -- ^ A pair of the request ID and a command.
           -> MutState -- ^ A reference to the mutable state.
           -> SockAddr -- ^ Socket address of the client making the request.
           -> IO Response
runCommand (i, cmd) MutState{..} sockAddr =
  case cmd of
    Heartbeat uuid port -> do
      now <- getUnixTime
      returnAndLog $ atomically $ runWriterT $ do
        get <- lift $ M.lookup uuid heartbeats
        case get of
          Just cond@ServerCondition{..} -> do
            let expireTime = lastHeartbeatTime `addUnixDiffTime` secondsToUnixDiffTime 30
            if isActive && (now < expireTime)
              then do -- Normal heartbeat update
                lift $ M.insert (cond {lastHeartbeatTime = now}) uuid heartbeats
                logger $ green $ "Heartbeat received from " ++ port
                return $ Executed i Ok
              else do -- Expired server connection
                lift $ M.insert (cond {isActive = False}) uuid heartbeats
                lift $ modifyTVar' epoch (+1)
                logger $ red $ "Expired heartbeat received from " ++ port
                return $ Executed i Forbidden
          Nothing -> do -- New server connection
            lift $ M.insert (ServerCondition now True sockAddr) uuid heartbeats
            lift $ modifyTVar' epoch (+1)
            logger $ green $ "New heartbeat received from " ++ port
            return $ Executed i Ok
    QueryServers ->
      returnAndLog $ atomically $ runWriterT $ do
        addrs <- lift $ map (show . serverAddr) . filter isActive . map snd
                        <$> ListT.toList (M.stream heartbeats)
        epoch' <- lift $ readTVar epoch
        logger $ green "Active servers request"
        return $ QueryServersResponse i epoch' addrs
    LockGet name cli ->
      returnAndLog $ atomically $ runWriterT $ do
        get <- lift $ M.lookup name locks
        case get of
          Just uuid -> do
            logger $ green $ "Get lock for \"" ++ name ++ "\" from \"" ++ cli ++ "\""
            return $ Executed i Retry
          Nothing -> do
            lift $ M.insert cli name locks
            logger $ red $ "Get lock failed for \"" ++ name ++ "\" from \"" ++ cli ++ "\""
            return $ Executed i Granted
    LockRelease name cli ->
      returnAndLog $ atomically $ runWriterT $ do
        get <- lift $ M.lookup name locks
        case get of
          Just cliInMap ->
            if cliInMap == cli
            then do
              logger $ green $ "Release lock for \"" ++ name ++ "\" from \"" ++ cli ++ "\""
              lift $ M.delete name locks
              return $ Executed i Ok
            else do
              logger $ red $ "Release lock failed for \"" ++ name ++ "\" from \"" ++ cli ++ "\""
              return $ Executed i Forbidden
          Nothing -> do
            logger $ green $ "Release nonexistent lock for \"" ++ name ++ "\" from \"" ++ cli ++ "\""
            return $ Executed i Ok

-- | Receives messages, decodes and runs the content if necessary, and returns
-- the response. Should be run after you accepted a connection.
runConn :: (Socket, SockAddr) -> MutState -> IO ()
runConn (sock, sockAddr) st = do
  timeoutAct (recvWithLen sock) (putStrLn $ red "Timeout when receiving") $
    \cmdMsg -> case S.decode cmdMsg :: Either String (Int, ViewLeaderCommand) of
      Left e ->
        putStrLn $ red "Couldn't parse the message received because " ++ e
      Right (i, cmd) -> do
        response <- runCommand (i, cmd) st sockAddr
        timeoutAct (sendWithLen sock (BL.toStrict (JSON.encode response)))
                   (putStrLn $ red "Timeout when sending")
                   return
  close sock

-- | The main loop that keeps accepting more connections.
-- Should be revised for concurrency.
loop :: Socket -> MutState -> IO ()
loop sock st = do
  conn <- accept sock
  forkIO (runConn conn st)
  loop sock st

main :: IO ()
main = do
    attempt <- findAndListenOpenPort $ map show [39000..39010]
    case attempt of
      Nothing -> die $ bgRed "Couldn't bind ports 39000 to 39010"
      Just (sock, sockAddr) -> do
        st <- initialState
        loop sock st
        close sock
