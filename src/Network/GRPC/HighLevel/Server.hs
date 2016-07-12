{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecordWildCards   #-}

module Network.GRPC.HighLevel.Server where

import           Control.Concurrent.Async
import           Control.Monad
import           Data.ByteString                           (ByteString)
import qualified Data.ByteString.Lazy                      as BL
import           Data.Protobuf.Wire.Class
import           Network.GRPC.LowLevel
import qualified Network.GRPC.LowLevel.Call.Unregistered   as U
import           Network.GRPC.LowLevel.GRPC
import qualified Network.GRPC.LowLevel.Server.Unregistered as U

type ServerHandler' a b =
  forall c .
  ServerCall c
  -> a
  -> MetadataMap
  -> IO (b, MetadataMap, StatusCode, StatusDetails)

convertServerHandler :: (Message a, Message b)
                     => ServerHandler' a b
                     -> ServerHandler
convertServerHandler f c bs m = case fromByteString bs of
  Left{}  -> error "TODO: find a way to keep this from killing the server."
  Right x -> do (y, tm, sc, sd) <- f c x m
                return (toBS y, tm, sc, sd)

type ServerReaderHandler' a b =
  ServerCall ()
  -> StreamRecv a
  -> Streaming (Maybe b, MetadataMap, StatusCode, StatusDetails)

convertServerReaderHandler :: (Message a, Message b)
                           => ServerReaderHandler' a b
                           -> ServerReaderHandler
convertServerReaderHandler f c recv =
  serialize <$> f c (convertRecv recv)
  where
    serialize (mmsg, m, sc, sd) = (toBS <$> mmsg, m, sc, sd)

type ServerWriterHandler' a b =
  ServerCall a
  -> StreamSend b
  -> Streaming (MetadataMap, StatusCode, StatusDetails)

convertServerWriterHandler :: (Message a, Message b) =>
                              ServerWriterHandler' a b
                              -> ServerWriterHandler
convertServerWriterHandler f c send =
  f (convert <$> c) (convertSend send)
  where
    convert bs = case fromByteString bs of
      Left x  -> error $ "deserialization error: " ++ show x -- TODO FIXME
      Right x -> x

type ServerRWHandler' a b =
  ServerCall ()
  -> StreamRecv a
  -> StreamSend b
  -> Streaming (MetadataMap, StatusCode, StatusDetails)

convertServerRWHandler :: (Message a, Message b)
                       => ServerRWHandler' a b
                       -> ServerRWHandler
convertServerRWHandler f c recv send =
  f c (convertRecv recv) (convertSend send)

convertRecv :: Message a => StreamRecv ByteString -> StreamRecv a
convertRecv =
  fmap $ \e -> do
    msg <- e
    case msg of
      Nothing -> return Nothing
      Just bs -> case fromByteString bs of
                   Left x  -> Left (GRPCIODecodeError x)
                   Right x -> return (Just x)

convertSend :: Message a => StreamSend ByteString -> StreamSend a
convertSend s = s . toBS

toBS :: Message a => a -> ByteString
toBS = BL.toStrict . toLazyByteString

data Handler a where
  UnaryHandler
    :: (Message c, Message d)
    => MethodName
    -> ServerHandler' c d
    -> Handler 'Normal

  ClientStreamHandler
    :: (Message c, Message d)
    => MethodName
    -> ServerReaderHandler' c d
    -> Handler 'ClientStreaming

  ServerStreamHandler
    :: (Message c, Message d)
    => MethodName
    -> ServerWriterHandler' c d
    -> Handler 'ServerStreaming

  BiDiStreamHandler
    :: (Message c, Message d)
    => MethodName
    -> ServerRWHandler' c d
    -> Handler 'BiDiStreaming

handlerMethodName :: Handler a -> MethodName
handlerMethodName (UnaryHandler m _) = m
handlerMethodName (ClientStreamHandler m _) = m
handlerMethodName (ServerStreamHandler m _) = m
handlerMethodName (BiDiStreamHandler m _) = m

-- TODO: find some idiomatic way to do logging that doesn't force the user
-- into anything they  don't want.
logShow :: Show a => a -> IO ()
logShow = print

logAskReport :: Show a => a -> IO ()
logAskReport x =
  logShow $ show x ++ " This probably indicates a bug in gRPC-haskell. Please report this error."

-- | Handles errors that result from trying to handle a call on the server.
-- For each error, takes a different action depending on the severity in the
-- context of handling a server call. This also tries to give an indication of
-- whether the error is our fault or user error.
handleCallError :: Either GRPCIOError a -> IO ()
handleCallError (Right _) = return ()
handleCallError (Left GRPCIOTimeout) =
  --Probably a benign timeout (such as a client disappearing), noop for now.
  return ()
handleCallError (Left GRPCIOShutdown) =
  --Server shutting down. Benign.
  return ()
handleCallError (Left x) = logAskReport x

loopWError :: IO (Either GRPCIOError a) -> IO ()
loopWError f = forever $ f >>= handleCallError

--TODO: options for setting initial/trailing metadata
handleLoop :: Server -> (Handler a, RegisteredMethod a) -> IO ()
handleLoop s (UnaryHandler _ f, rm) =
  loopWError $ do
    grpcDebug' "handleLoop about to block on serverHandleNormalCall"
    serverHandleNormalCall s rm mempty $ convertServerHandler f
handleLoop s (ClientStreamHandler _ f, rm) =
  loopWError $ serverReader s rm mempty $ convertServerReaderHandler f
handleLoop s (ServerStreamHandler _ f, rm) =
  loopWError $ serverWriter s rm mempty $ convertServerWriterHandler f
handleLoop s (BiDiStreamHandler _ f, rm) =
  loopWError $ serverRW s rm mempty $ convertServerRWHandler f

data ServerOptions = ServerOptions
                     {optNormalHandlers       :: [Handler 'Normal],
                      optClientStreamHandlers :: [Handler 'ClientStreaming],
                      optServerStreamHandlers :: [Handler 'ServerStreaming],
                      optBiDiStreamHandlers   :: [Handler 'BiDiStreaming],
                      optServerPort           :: Port,
                      optUseCompression       :: Bool,
                      optUserAgentPrefix      :: String,
                      optUserAgentSuffix      :: String}

defaultOptions :: ServerOptions
defaultOptions =
  ServerOptions {optNormalHandlers = [],
                 optClientStreamHandlers = [],
                 optServerStreamHandlers = [],
                 optBiDiStreamHandlers = [],
                 optServerPort = 50051,
                 optUseCompression = False,
                 optUserAgentPrefix = "grpc-haskell/0.0.0",
                 optUserAgentSuffix = ""}

serverLoop :: ServerOptions -> IO ()
serverLoop opts =
  withGRPC $ \grpc ->
    withServer grpc (mkConfig opts) $ \server -> do
      let rmsN = zip (optNormalHandlers opts) $ normalMethods server
      let rmsCS = zip (optClientStreamHandlers opts) $ cstreamingMethods server
      let rmsSS = zip (optServerStreamHandlers opts) $ sstreamingMethods server
      let rmsB = zip (optBiDiStreamHandlers opts) $ bidiStreamingMethods server
      --TODO: Perhaps assert that no methods disappeared after registration.
      let loop :: forall a. (Handler a, RegisteredMethod a) -> IO ()
          loop = handleLoop server
      asyncsN <- mapM async $ map loop rmsN
      asyncsCS <- mapM async $ map loop rmsCS
      asyncsSS <- mapM async $ map loop rmsSS
      asyncsB <- mapM async $ map loop rmsB
      asyncUnk <- async $ loopWError $ unknownHandler server
      waitAnyCancel $ asyncUnk : asyncsN ++ asyncsCS ++ asyncsSS ++ asyncsB
      return ()
  where
    mkConfig ServerOptions{..} =
      ServerConfig
        {  host = "localhost"
         , port = optServerPort
         , methodsToRegisterNormal = map handlerMethodName optNormalHandlers
         , methodsToRegisterClientStreaming =
             map handlerMethodName optClientStreamHandlers
         , methodsToRegisterServerStreaming =
             map handlerMethodName optServerStreamHandlers
         , methodsToRegisterBiDiStreaming =
             map handlerMethodName optBiDiStreamHandlers
         , serverArgs =
             ([CompressionAlgArg GrpcCompressDeflate | optUseCompression]
              ++
              [UserAgentPrefix optUserAgentPrefix
               , UserAgentSuffix optUserAgentSuffix])
        }
    unknownHandler s =
      --TODO: is this working?
      U.serverHandleNormalCall s mempty $ \call _ -> do
        logShow $ "Requested unknown endpoint: " ++ show (U.callMethod call)
        return ("", mempty, StatusNotFound,
                StatusDetails "Unknown method")
