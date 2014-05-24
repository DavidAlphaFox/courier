{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Network.Transport.TCP
-- Copyright   :  (c) Phil Hargett 2013
-- License     :  MIT (see LICENSE file)
-- 
-- Maintainer  :  phil@haphazardhouse.net
-- Stability   :  experimental
-- Portability :  non-portable (uses STM)
--
-- TCP transports deliver messages to other 'Network.Endpoints.Endpoint's using TCP/IP.
--
-- Each TCP transport manages both socket bindings and connections on behalf of
-- 'Endpoint's, dynamically opening / closing new sockets as needed to deliver
-- messages to other 'Endpoint's using TCP transports.
-----------------------------------------------------------------------------

module Network.Transport.TCP (
  newTCPTransport
  ) where

-- local imports

import Network.Transport
import Network.Transport.Internal
import Network.Transport.Sockets

-- external imports

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception

import qualified Data.ByteString as B
import qualified Data.Map as M
import Data.Serialize
import qualified Data.Set as S

import qualified Network.Socket as NS
import qualified Network.Socket.ByteString as NSB

import System.Log.Logger

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

_log :: String
_log = "transport.tcp"

tcpScheme :: Scheme
tcpScheme = "tcp"

lookupTCPAddress :: Address -> IO NS.SockAddr
lookupTCPAddress address = lookupAddress NS.AF_INET NS.Stream address

lookupWildcardTCPAddress :: Address -> IO NS.SockAddr
lookupWildcardTCPAddress address = lookupWildcardAddress NS.AF_INET NS.Stream address

{-|
Create a new 'Transport' suitable for sending messages over TCP/IP.  There can
be multiple instances of these 'Transport's: 'Network.Endpoints.Endpoint' using
different instances will still be able to communicate, provided they use
correct TCP/IP addresses (or hostnames) for communication.
-}
newTCPTransport :: Resolver -> IO Transport
newTCPTransport resolver = do
  messengers <- atomically $ newTVar M.empty
  bindings <- atomically $ newTVar M.empty
  sockets <- newSocketBindings
  inbound <- atomically $ newMailbox
  dispatch <- async $ dispatcher bindings inbound
  let transport = SocketTransport {
        socketMessengers = messengers,
        socketBindings = bindings,
        socketConnection = newTCPConnection,
        socketMessenger = newTCPMessenger bindings resolver,
        socketInbound = inbound,
        socketDispatchers = S.fromList [dispatch],
        socketResolver = resolver
        }
  return Transport {
      scheme = tcpScheme,
      handles = tcpHandles transport,
      bind = tcpBind transport sockets,
      sendTo = socketSendTo transport,
      shutdown = tcpShutdown transport sockets
      }

tcpHandles :: SocketTransport -> Name -> IO Bool
tcpHandles transport name = do 
  resolved <- resolve (socketResolver transport) name
  return $ isJust resolved
  where
    isJust (Just _) = True
    isJust _ = False

tcpBind :: SocketTransport -> SocketBindings -> Mailbox Message -> Name -> IO (Either String Binding)
tcpBind transport sockets inc name = do
  atomically $ modifyTVar (socketBindings transport) $ \ bindings ->
    M.insert name inc bindings
  Just address <- resolve (socketResolver transport) name
  bindAddress sockets address $ do
      sock <- NS.socket NS.AF_INET NS.Stream NS.defaultProtocol
      listener <- do
        infoM _log $ "Binding to address " ++ (show address)
        tcpListen address sock
      return (sock,listener)
  return $ Right Binding {
    bindingName = name,
    unbind = tcpUnbind address
    }
  where
    tcpListen address sock = do
                catchExceptions (do
                        NS.setSocketOption sock NS.NoDelay 1
                        NS.setSocketOption sock NS.ReuseAddr 1
                        sockAddr <- lookupWildcardTCPAddress address
                        NS.bind sock sockAddr
                        NS.listen sock 2048) -- TODO think about a configurable backlog
                    (\e -> do
                    warningM _log $ "Listen error on port " ++ address ++ ": " ++ (show (e :: SomeException))
                    NS.sClose sock)
                async $ tcpAccept address sock
    tcpAccept address sock = do
      infoM _log $ "Listening for connections on " ++ (show address) ++ ": " ++ (show sock)
      (client,clientAddress) <- NS.accept sock
      _ <- async $ tcpDispatch address client clientAddress
      tcpAccept address sock
    tcpDispatch address client socketAddress = do
      infoM _log $ "Accepted connection on " ++ (show address)
      identity <- tcpIdentify client socketAddress
      case identity of
        Nothing -> NS.sClose client
        Just (IdentifyMessage clientAddress) -> do
          infoM _log $ "Identified " ++ (show clientAddress)
          newConn <- newTCPConnection clientAddress
          atomically $ putTMVar (connSocket newConn) client
          msngr <- newMessenger newConn (socketInbound transport)
          found <- atomically $ do
            msngrs <- readTVar $ socketMessengers transport
            return $ M.lookup clientAddress msngrs
          case found of
            Just _ -> do
              infoM _log $ "Already have messenger for " ++ (show clientAddress)
              closeMessenger msngr
            Nothing -> do
              addMessenger transport clientAddress msngr
    tcpIdentify client clientAddress = do
      infoM _log $ "Awaiting identity from " ++ (show clientAddress)
      maybeMsg <- receiveSocketMessage client
      case maybeMsg of
        Nothing -> return Nothing
        Just bytes -> do
          let msg = decode bytes
          case msg of
            Left _ -> return Nothing
            Right message -> return $ Just message
    tcpUnbind address = do
      infoM _log $ "Unbinding from TCP port " ++ (show address)
      unbindAddress sockets address
      infoM _log $ "Unbound from TCP port " ++ (show address)

newTCPConnection :: Address -> IO Connection
newTCPConnection address = do
  sock <- atomically $ newEmptyTMVar
  return Connection {
    connAddress = address,
    connSocket = sock,
    connConnect = do
        socket <- NS.socket NS.AF_INET NS.Stream NS.defaultProtocol
        sockAddr <- lookupTCPAddress address
        NS.connect socket sockAddr
        -- NS.connect socket $ NS.addrAddress $ head ipv4Addrs
        atomically $ putTMVar sock socket
        -- infoM _log $ "Initiated socket connection to " ++ (show $ head ipv4Addrs)
        return socket,
    connSend = tcpSend address,
    connReceive = receiveSocketBytes,
    connClose = do
        infoM _log $ "Closing connection to " ++ address
        open <- atomically $ tryTakeTMVar sock
        case open of
            Just socket -> do
                infoM _log $ "Closing socket " ++ (show socket) ++ " for " ++ address
                NS.sClose socket
                infoM _log $ "Closed socket " ++ (show socket) ++ " for " ++ address
            Nothing -> do
                infoM _log $ "No socket to close for " ++ address
                return ()
        infoM _log $ "Connection to " ++ address ++ " closed"
    }

newTCPMessenger :: Bindings -> Resolver -> Connection -> Mailbox Message -> IO Messenger
newTCPMessenger bindings resolver conn mailbox = do
    msngr <- newMessenger conn mailbox
    identifyAll msngr
    return msngr
    where
        identifyAll msngr = do
            bs <- atomically $ readTVar bindings
            boundAddresses <- mapM (resolve resolver) (M.keys bs)
            let uniqueAddresses = S.toList $ S.fromList boundAddresses
            mapM_ (identify msngr) uniqueAddresses
        identify msngr maybeUniqueAddress= do
            case maybeUniqueAddress of
                Nothing -> return()
                Just uniqueAddress -> deliver msngr $ encode $ IdentifyMessage uniqueAddress

tcpSend :: Address -> NS.Socket -> B.ByteString -> IO ()
tcpSend addr sock bs = do
    NSB.sendAll sock $ encode (B.length bs)
    infoM _log $ "Length sent"
    NSB.sendAll sock bs
    infoM _log $ "Message sent to" ++ (show addr)


tcpShutdown :: SocketTransport -> SocketBindings -> IO ()
tcpShutdown transport sockets = do
  closeBindings sockets
  infoM _log $ "Closing messengers"
  msngrs <- atomically $ readTVar $ socketMessengers transport
  mapM_ closeMessenger $ M.elems msngrs
  infoM _log $ "Closing dispatcher"
  mapM_ cancel $ S.toList $ socketDispatchers transport
  mapM_ wait $ S.toList $ socketDispatchers transport
