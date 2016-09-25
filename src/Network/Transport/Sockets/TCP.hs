-----------------------------------------------------------------------------
-- |
-- Module      :  Network.Transport.Sockets.TCP
-- Copyright   :  (c) Phil Hargett 2015
-- License     :  MIT (see LICENSE file)
--
-- Maintainer  :  phil@haphazardhouse.net
-- Stability   :  experimental
-- Portability :  non-portable (requires STM)
--
-- TCP transport.
--
-----------------------------------------------------------------------------
module Network.Transport.Sockets.TCP (
  newTCPTransport4,
  newTCPTransport6,

  tcpSocketResolver4,
  tcpSocketResolver6,

  module Network.Transport
) where

-- local imports

import Network.Endpoints
import Network.Transport
import Network.Transport.Sockets

-- external imports

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad

import qualified Data.ByteString as BS
import qualified Data.Map as M
import Data.Serialize

import qualified Network.Socket as NS
import qualified Network.Socket.ByteString as NSB

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

type SocketConnections = TVar (M.Map NS.SockAddr Connection)

newTCPTransport :: NS.Family -> Resolver -> IO Transport
newTCPTransport family resolver = atomically $ do
  vPeers <- newTVar M.empty
  mailboxes <- newTVar M.empty
  -- 创建Transport
  return Transport {
    bind = tcpBind mailboxes family resolver vPeers,
    dispatch = dispatcher mailboxes,
    connect =  socketConnect mailboxes $ tcpConnect family resolver,
    shutdown = tcpShutdown vPeers
  }

{-|
Create a 'Transport' for exchanging 'Message's between endpoints via TCP over IP
-}
newTCPTransport4 :: Resolver -> IO Transport
newTCPTransport4 = newTCPTransport NS.AF_INET

{-|
Create a 'Transport' for exchanging 'Message's between endpoints via TCP over IPv6
-}
newTCPTransport6 :: Resolver -> IO Transport
newTCPTransport6 = newTCPTransport NS.AF_INET6

{-|
Create a 'Resolve' for resolving 'Name's for use with TCP over IP.
-}
tcpSocketResolver4 :: Name -> IO [NS.SockAddr]
tcpSocketResolver4 = socketResolver4 NS.Stream

{-|
Create a 'Resolve' for resolving 'Name's for use with TCP over IPv6.
-}
tcpSocketResolver6 :: Name -> IO [NS.SockAddr]
tcpSocketResolver6 = socketResolver6 NS.Stream

tcpBind :: Mailboxes -> NS.Family -> Resolver -> SocketConnections -> Endpoint -> Name -> IO Binding
tcpBind mailboxes family resolver vConnections endpoint name = do
  listener <- async $ tcpListen mailboxes family resolver vConnections endpoint name
  -- 生成绑定数据
  -- 服务名称和监听器绑定
  return Binding {
    bindingName = name,
    unbind = cancel listener
  }

tcpListen :: Mailboxes -> NS.Family -> Resolver -> SocketConnections -> Endpoint -> Name -> IO ()
tcpListen mailboxes family resolver vConnections endpoint name = do
  socket <- socketListen family NS.Stream resolver name
  finally (accept mailboxes socket vConnections endpoint)
    (tcpUnbind socket)

accept :: Mailboxes -> NS.Socket -> SocketConnections -> Endpoint -> IO ()
accept mailboxes socket vConnections endpoint = do
  -- 先完成TCP的链接
  (peer,peerAddress) <- NS.accept socket
  -- 创建Connection，包含peer的Name，send，recv和close
  connection <- tcpConnection peer
  -- 创建新的messager
  msngr <- async $ messenger mailboxes endpoint connection
  -- OK,创建新的Connection
  let conn = Connection {
    -- 当connection被删除的时候
    -- 需要在vConnections中删除掉相应的peerAddress
    disconnect = do
      atomically $ modifyTVar vConnections $ M.delete peerAddress
      -- 从任务队列中取消掉相应的messager
      cancel msngr
  }
  -- 是否是一个重新连接的连接
  maybeOldConn <- atomically $ do
    connections <- readTVar vConnections
    let oldConn = M.lookup peerAddress connections
    modifyTVar vConnections $ M.insert peerAddress conn
    return oldConn
  case maybeOldConn of
    -- 如果是OldConn的时候，就删除链接
    Just oldConn -> disconnect oldConn
    Nothing -> return ()
  accept mailboxes socket vConnections endpoint

tcpUnbind :: NS.Socket -> IO ()
tcpUnbind = NS.close

tcpConnect :: NS.Family -> Resolver -> Endpoint -> Name -> IO SocketConnection
tcpConnect family resolver _ name = do
  socket <- NS.socket family NS.Stream NS.defaultProtocol
  address <- resolve1 resolver name
  NS.connect socket address
  tcpConnection socket
-- 根据Peer 构建一个新的Socket的Connection
tcpConnection :: NS.Socket -> IO SocketConnection
tcpConnection socket = do
  vName <- atomically newEmptyTMVar
  return SocketConnection {
    connectionDestination = vName,
    sendSocketMessage = tcpSend socket,
    receiveSocketMessage = tcpReceive socket,
    disconnectSocket = tcpDisconnect socket
  }

tcpSend :: NS.Socket -> Message -> IO ()
tcpSend socket message = do
  let len = BS.length message
  NSB.sendAll socket $ encode len
  NSB.sendAll socket message

tcpReceive :: NS.Socket -> IO Message
tcpReceive socket = readBytesWithLength
  where
    readBytesWithLength = do
      lengthBytes <- readBytes 8 -- TODO must figure out what defines length of an integer in bytes
      case decode lengthBytes of
        Left _ -> throw NoDataRead
        Right len -> readBytes len
    readBytes = NSB.recv socket

tcpDisconnect :: NS.Socket -> IO ()
tcpDisconnect = NS.close

tcpShutdown :: SocketConnections -> IO ()
tcpShutdown vPeers = do
  peers <- atomically $ readTVar vPeers
  -- this is how we disconnect incoming connections
  -- we don't have to disconnect  outbound connectinos, because
  -- they should already be disconnected before here
  forM_ (M.elems peers) disconnect
  return ()
