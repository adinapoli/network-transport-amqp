{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{--|
  A Network Transport Layer for `distributed-process`
  based on AMQP and single-owner queues
--}

module Network.Transport.AMQP (
    createTransport
  , AMQPParameters(..)
  ) where

import Network.Transport.AMQP.Internal.Types

import qualified Network.AMQP as AMQP
import qualified Data.Text as T
import Data.UUID.V4
import Data.List (foldl1')
import Data.UUID (toString, toWords)
import Data.Bits
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.ByteString (ByteString)
import Data.Foldable
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as B
import Data.String.Conv
import Data.Serialize
import Network.Transport
import Network.Transport.Internal (asyncWhenCancelled)
import Control.Concurrent.MVar
import Control.Monad
import Control.Exception
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)

import Lens.Family2

--------------------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------------------

encode' :: AMQPMessage -> BL.ByteString
encode' = encodeLazy

--------------------------------------------------------------------------------
decode' :: AMQP.Message -> Either String AMQPMessage
decode' = decodeLazy . AMQP.msgBody

--------------------------------------------------------------------------------
apiNewEndPoint :: AMQPInternalState
               -> IO (Either (TransportError NewEndPointErrorCode) EndPoint)
apiNewEndPoint is@AMQPInternalState{..} = do
  try . asyncWhenCancelled closeEndPoint $ do
    let AMQPParameters{..} = istate_params
    modifyMVar istate_tstate $ \tst -> case tst of
      TransportClosed -> throwIO $ TransportError NewEndPointFailed "Transport is closed."
      TransportValid (ValidTransportState cnn oldMap) -> do
        newChannel <- AMQP.openChannel transportConnection
        uuid <- toS . toString <$> nextRandom
        (ourEndPoint,_,_) <- AMQP.declareQueue newChannel $ AMQP.newQueue {
                            AMQP.queueName = maybe uuid toS transportEndpoint
                            , AMQP.queuePassive = False
                            , AMQP.queueDurable = False
                            , AMQP.queueExclusive = True
                            }
        -- TODO: Is this a bad idea? Reuse as exchange name the random queue
        -- generated by RabbitMQ
        let ourExchange = ourEndPoint
        (ourLocalEp, es@ValidLocalEndPointState{..}) <- newLocalEndPoint (toAddress ourEndPoint) newChannel

        -- Add this LocalEndPoint to the internal map of the Transport
        let newMap = Map.insert (toAddress ourEndPoint) ourLocalEp oldMap

        AMQP.declareExchange newChannel $ AMQP.newExchange {
              AMQP.exchangeName = ourExchange
            , AMQP.exchangeType = "direct"
            , AMQP.exchangePassive = False
            , AMQP.exchangeDurable = False
            , AMQP.exchangeAutoDelete = True
            }

        AMQP.bindQueue newChannel ourEndPoint ourExchange mempty

        startReceiver is ourLocalEp

        let newEp =  EndPoint {
              receive       = readChan _localChan
            , address       = EndPointAddress $ toS ourEndPoint
            , connect       = apiConnect is ourLocalEp
            , closeEndPoint = apiCloseEndPoint is ourLocalEp
            , newMulticastGroup     = return . Left $ newMulticastGroupError
            , resolveMulticastGroup = return . Left . const resolveMulticastGroupError
            }
        return (TransportValid (ValidTransportState cnn newMap), newEp)
  where
    newMulticastGroupError =
      TransportError NewMulticastGroupUnsupported "Multicast not supported"
    resolveMulticastGroupError =
      TransportError ResolveMulticastGroupUnsupported "Multicast not supported"

--------------------------------------------------------------------------------
startReceiver :: AMQPInternalState -> LocalEndPoint -> IO ()
startReceiver tr@AMQPInternalState{..} lep@LocalEndPoint{..} = do
  withMVar localState $ \lst -> case lst of
    LocalEndPointValid vst@ValidLocalEndPointState{..} -> do
      void $ AMQP.consumeMsgs _localChannel (fromAddress localAddress) AMQP.NoAck $ \(msg,_) -> do
        case decode' msg of
          Left _ -> return ()
          Right v@(MessageInitConnection theirAddr theirId rel) -> do
              print v
              -- TODO: Do I need to persist this RemoteEndPoint with the id given to me?
              (rep, isNew) <- findRemoteEndPoint lep theirAddr
              when isNew $ do
                let ourId = remoteId rep
                publish _localChannel theirAddr (MessageInitConnectionOk localAddress ourId theirId)
              -- TODO: This is a bug?. I need to issue a ConnectionOpened with the
              -- internal counter I am keeping, not the one coming from the remote
              -- endpoint.
              writeChan _localChan $ ConnectionOpened theirId rel theirAddr
          Right (MessageData cId rawMsg) -> do
              writeChan _localChan $ Received cId rawMsg
          Right v@(MessageInitConnectionOk theirAddr theirId ourId) -> do
              -- TODO: This smells
              print v
              writeChan _localChan $ ConnectionOpened theirId ReliableOrdered theirAddr
          Right (MessageCloseConnection theirAddr theirId) -> do
              print "MessageCloseConnection"
              cleanupRemoteConnection tr lep theirAddr
              writeChan _localChan $ ConnectionClosed theirId
          Right (MessageEndPointClose theirAddr theirId) -> do
              unless (localAddress == theirAddr) $ do
                cleanupRemoteConnection tr lep theirAddr
                print "MessageEndPointClose"
                writeChan _localChan $ ConnectionClosed theirId
          rst -> print rst
    _ -> return ()


--------------------------------------------------------------------------------
withValidLocalState_ :: LocalEndPoint
                     -> (ValidLocalEndPointState -> IO ())
                     -> IO ()
withValidLocalState_ LocalEndPoint{..} f = withMVar localState $ \st ->
  case st of
    LocalEndPointClosed -> return ()
    LocalEndPointNoAcceptConections -> return ()
    LocalEndPointValid v -> f v

--------------------------------------------------------------------------------
modifyValidLocalState :: LocalEndPoint
                       -> (ValidLocalEndPointState -> IO (LocalEndPointState, b))
                       -> IO b
modifyValidLocalState LocalEndPoint{..} f = modifyMVar localState $ \st ->
  case st of
    LocalEndPointClosed -> 
      throw $ userError "modifyValidLocalState: LocalEndPointClosed"
    LocalEndPointNoAcceptConections ->
      throw $ userError "modifyValidLocalState: LocalEndPointNoAcceptConnections"
    LocalEndPointValid v -> f v

--------------------------------------------------------------------------------
newLocalEndPoint :: EndPointAddress -> AMQP.Channel -> IO (LocalEndPoint, ValidLocalEndPointState)
newLocalEndPoint ep amqpCh = do
  ch <- newChan
  let newState = emptyState ch
  st <- newMVar (LocalEndPointValid newState)
  return (LocalEndPoint ep st, newState)
  where
    emptyState :: Chan Event -> ValidLocalEndPointState
    emptyState ch = ValidLocalEndPointState ch amqpCh Map.empty

--------------------------------------------------------------------------------
apiCloseEndPoint :: AMQPInternalState
                 -> LocalEndPoint
                 -> IO ()
apiCloseEndPoint AMQPInternalState{..} lep@LocalEndPoint{..} = do
  let evts = [ EndPointClosed , throw $ userError "Endpoint closed"]
  let ourAddress = localAddress

  -- Notify all the remoters this EndPoint is dying.
  modifyMVar_ localState $ \lst -> case lst of
    LocalEndPointValid vst@ValidLocalEndPointState{..} -> do
      print (Map.keys $ vst ^. localConnections)
      forM_ (Map.toList $ vst ^. localConnections) $ \(theirAddress, rep) ->
        publish _localChannel theirAddress (MessageEndPointClose ourAddress (remoteId rep))

      -- Close the given connection
      forM_ evts (writeChan _localChan)
      let queue = fromAddress localAddress
      _ <- AMQP.deleteQueue _localChannel queue
      AMQP.deleteExchange _localChannel queue
      return LocalEndPointClosed
    _ -> return LocalEndPointClosed

--------------------------------------------------------------------------------
cleanupRemoteConnection :: AMQPInternalState
                        -> LocalEndPoint
                        -> EndPointAddress
                        -> IO ()
cleanupRemoteConnection AMQPInternalState{..} lep@LocalEndPoint{..} theirAddress = do
  let ourAddress = localAddress
  modifyValidLocalState lep $ \vst -> case Map.lookup theirAddress (vst ^. localConnections) of
    Nothing -> throwIO $ InvariantViolated (EndPointNotInRemoteMap theirAddress)
    Just rep -> do
      let ourId = remoteId rep
      -- When we first asked to cleanup a remote connection, we do not delete it
      -- immediately; conversely, be set its state to close and if the state was already
      -- closed we delete it. This allows a RemoteEndPoint to be marked in closing state,
      -- but to still be listed so that can receive subsequent notifications, like for
      -- example the ConnectionClosed ones.
      wasAlreadyClosed <- modifyMVar (remoteState rep) $ \rst -> case rst  of
        RemoteEndPointValid  -> return (RemoteEndPointClosed, False)
        RemoteEndPointClosed -> return (RemoteEndPointClosed, True)
      let newStateSetter mp = case wasAlreadyClosed of
                                True -> Map.delete theirAddress mp
                                False -> mp
      return (LocalEndPointValid $ over localConnections newStateSetter vst, ())

--------------------------------------------------------------------------------
toAddress :: T.Text -> EndPointAddress
toAddress = EndPointAddress . toS

--------------------------------------------------------------------------------
fromAddress :: EndPointAddress -> T.Text
fromAddress = toS . endPointAddressToByteString

--------------------------------------------------------------------------------
apiConnect :: AMQPInternalState
           -> LocalEndPoint
           -> EndPointAddress  -- ^ Remote address
           -> Reliability      -- ^ Reliability (ignored)
           -> ConnectHints     -- ^ Hints
           -> IO (Either (TransportError ConnectErrorCode) Connection)
apiConnect tr@AMQPInternalState{..} lep@LocalEndPoint{..} theirAddress reliability _ = do
  let ourAddress = localAddress
  try . asyncWhenCancelled close $ do
    lst <- takeMVar localState
    putMVar localState lst
    case lst of
      LocalEndPointClosed ->
        throwIO $ TransportError ConnectFailed "apiConnect: LocalEndPointClosed"
      LocalEndPointNoAcceptConections ->
        throw $ userError "apiConnect: local endpoint doesn't accept connections."
      LocalEndPointValid ValidLocalEndPointState{..} -> do
        if ourAddress == theirAddress
        then connectToSelf lep
        else do
          (rep, isNew) <- findRemoteEndPoint lep theirAddress
          let cId = remoteId rep
          print $ "apiConnect cId: " ++ show cId
          print $ "apiConnect new: " ++ show isNew
          when isNew $ do
              let msg = MessageInitConnection ourAddress cId reliability
              publish _localChannel theirAddress msg
          return Connection {
                    send = apiSend tr lep theirAddress cId
                  , close = apiClose tr lep theirAddress cId
                 }

--------------------------------------------------------------------------------
-- | Find a remote endpoint. If the remote endpoint does not yet exist we
-- create it. Returns if the endpoint was new.
findRemoteEndPoint :: LocalEndPoint
                   -> EndPointAddress
                   -> IO (RemoteEndPoint, Bool)
findRemoteEndPoint lep@LocalEndPoint{..} theirAddr = 
  modifyMVar localState $ \lst -> case lst of
    LocalEndPointClosed -> 
      throwIO $ TransportError ConnectFailed "findRemoteEndPoint: LocalEndPointClosed"
    LocalEndPointNoAcceptConections ->
      throw $ userError "findRemoteEndpoint: local endpoint doesn't accept connections."
    LocalEndPointValid v ->
      case Map.lookup theirAddr (v ^. localConnections) of
          -- TODO: Check if the RemoteEndPoint is closed.
          Just r -> return (LocalEndPointValid v, (r, False))
          Nothing -> do
            newRem <- newValidRemoteEndpoint lep theirAddr
            let newMap = Map.insert theirAddr newRem
            return (LocalEndPointValid $ over localConnections newMap v, (newRem, True))

--------------------------------------------------------------------------------
newValidRemoteEndpoint :: LocalEndPoint 
                       -> EndPointAddress 
                       -> IO RemoteEndPoint
newValidRemoteEndpoint LocalEndPoint{..} ep = do
  -- TODO: Experimental: do a bitwise operation on the UUID to generate
  -- a random ConnectionId. Is this safe?
  let queueAsWord64 = foldl1' (+) (map fromIntegral $ B.unpack . endPointAddressToByteString $ localAddress)
  (a,b,c,d) <- toWords <$> nextRandom
  let cId = fromIntegral (a .|. b .|. c .|. d) + queueAsWord64
  var <- newMVar RemoteEndPointValid
  return $ RemoteEndPoint ep cId var

--------------------------------------------------------------------------------
-- TODO: Deal with exceptions.
connectToSelf :: LocalEndPoint -> IO Connection
connectToSelf lep@LocalEndPoint{..} = do
    let ourEndPoint = localAddress
    (rep, _) <- findRemoteEndPoint lep ourEndPoint
    let cId = remoteId rep
    withValidLocalState_ lep $ \ValidLocalEndPointState{..} ->
      writeChan _localChan $ ConnectionOpened cId ReliableOrdered ourEndPoint
    return Connection { 
        send  = selfSend cId
      , close = selfClose cId
    }
  where
    selfSend :: ConnectionId
             -> [ByteString]
             -> IO (Either (TransportError SendErrorCode) ())
    selfSend connId msg =
      try . withMVar localState $ \st -> case st of
        LocalEndPointValid ValidLocalEndPointState{..} -> do
            writeChan _localChan (Received connId msg)
        LocalEndPointNoAcceptConections -> do
          throwIO $ TransportError SendClosed "selfSend: Connections no more."
        LocalEndPointClosed ->
          throwIO $ TransportError SendFailed "selfSend: Connection closed"

    selfClose :: ConnectionId -> IO ()
    selfClose connId = do
      modifyMVar_ localState $ \st -> case st of
        LocalEndPointValid ValidLocalEndPointState{..} -> do
          writeChan _localChan (ConnectionClosed connId)
          return LocalEndPointNoAcceptConections
        LocalEndPointNoAcceptConections ->
          throwIO $ TransportError SendFailed "selfClose: No connections accepted"
        LocalEndPointClosed -> 
          throwIO $ TransportError SendClosed "selfClose: Connection closed"

--------------------------------------------------------------------------------
publish :: AMQP.Channel 
        -> EndPointAddress 
        -> AMQPMessage 
        -> IO ()
publish transportChannel address msg = do
    AMQP.publishMsg transportChannel
                    (toS . endPointAddressToByteString $ address)
                    mempty
                    (AMQP.newMsg { AMQP.msgBody = encode' msg
                                 , AMQP.msgDeliveryMode = Just AMQP.NonPersistent
                                 })

--------------------------------------------------------------------------------
-- TODO: Deal with exceptions and error at the broker level.
apiSend :: AMQPInternalState
        -> LocalEndPoint
        -> EndPointAddress
        -> ConnectionId
        -> [ByteString] -> IO (Either (TransportError SendErrorCode) ())
apiSend is lep@LocalEndPoint{..} their connId msgs = do
  try . withMVar (istate_tstate is) $ \tst -> case tst of
    TransportClosed -> 
      throwIO $ TransportError SendFailed "apiSend: TransportClosed"
    TransportValid _ -> withValidLocalState_ lep $ \vst@ValidLocalEndPointState{..} -> 
      case Map.lookup their (vst ^. localConnections) of
        Nothing  -> throwIO $ TransportError SendFailed "apiSend: address not in local connections"
        Just rep -> withMVar (remoteState rep) $ \rst -> case rst of
          RemoteEndPointClosed -> throwIO $ TransportError SendFailed "apiSend: Connection closed"
          RemoteEndPointValid ->  publish _localChannel their (MessageData connId msgs)

--------------------------------------------------------------------------------
-- | Change the status of this `Endpoint` to be closed
apiClose :: AMQPInternalState
         -> LocalEndPoint
         -> EndPointAddress
         -> ConnectionId
         -> IO ()
apiClose tr@AMQPInternalState{..} lep@LocalEndPoint{..} ep connId = do
  let ourAddress = localAddress
  cleanupRemoteConnection tr lep ep
  withValidLocalState_ lep $ \ValidLocalEndPointState{..} ->
    publish _localChannel ep (MessageCloseConnection ourAddress connId)

--------------------------------------------------------------------------------
createTransport :: AMQPParameters -> IO Transport
createTransport params@AMQPParameters{..} = do
  let validTState = ValidTransportState transportConnection Map.empty
  tState <- newMVar (TransportValid validTState)
  let iState = AMQPInternalState params tState
  return Transport {
    newEndPoint = apiNewEndPoint iState
  , closeTransport = apiCloseTransport iState
  }

--------------------------------------------------------------------------------
apiCloseTransport :: AMQPInternalState -> IO ()
apiCloseTransport is =
  modifyMVar_ (istate_tstate is) $ \tst -> case tst of
    TransportClosed -> return TransportClosed
    TransportValid (ValidTransportState cnn mp) -> do
      print "Before closing all"
      traverse_ (apiCloseEndPoint is) mp
      print "After closing all endpoints"
      AMQP.closeConnection cnn
      return TransportClosed
