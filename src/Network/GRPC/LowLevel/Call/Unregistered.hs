{-# LANGUAGE RecordWildCards #-}

module Network.GRPC.LowLevel.Call.Unregistered where

import           Control.Monad
import           Foreign.Marshal.Alloc                          (free)
import           Foreign.Ptr                                    (Ptr)
#ifdef DEBUG
import           Foreign.Storable             (peek)
#endif
import           Network.GRPC.LowLevel.Call                     (Host (..),
                                                                 MethodName (..))
import           Network.GRPC.LowLevel.CompletionQueue.Internal
import           Network.GRPC.LowLevel.GRPC                     (MetadataMap,
                                                                 grpcDebug)
import qualified Network.GRPC.Unsafe                            as C
import qualified Network.GRPC.Unsafe.Op                         as C
import           System.Clock                                   (TimeSpec)

-- | Represents one unregistered GRPC call on the server.  Contains pointers to
-- all the C state needed to respond to an unregistered call.
data ServerCall = ServerCall
  { unsafeSC            :: C.Call
  , callCQ              :: CompletionQueue
  , requestMetadataRecv :: MetadataMap
  , parentPtr           :: Maybe (Ptr C.Call)
  , callDeadline        :: TimeSpec
  , callMethod          :: MethodName
  , callHost            :: Host
  }

serverCallCancel :: ServerCall -> C.StatusCode -> String -> IO ()
serverCallCancel sc code reason =
  C.grpcCallCancelWithStatus (unsafeSC sc) code reason C.reserved

debugServerCall :: ServerCall -> IO ()
#ifdef DEBUG
debugServerCall ServerCall{..} = do
  let C.Call ptr = unsafeSC
      dbug = grpcDebug . ("debugServerCall(U): " ++)

  dbug $ "server call: " ++ show ptr
  dbug $ "metadata: "    ++ show requestMetadataRecv

  forM_ parentPtr $ \parentPtr' -> do
    dbug $ "parent ptr: " ++ show parentPtr'
    C.Call parent <- peek parentPtr'
    dbug $ "parent: "     ++ show parent

  dbug $ "deadline: " ++ show callDeadline
  dbug $ "method: "   ++ show callMethod
  dbug $ "host: "     ++ show callHost
#else
{-# INLINE debugServerCall #-}
debugServerCall = const $ return ()
#endif

destroyServerCall :: ServerCall -> IO ()
destroyServerCall call@ServerCall{..} = do
  grpcDebug "destroyServerCall(U): entered."
  debugServerCall call
  grpcDebug $ "Destroying server-side call object: " ++ show unsafeSC
  C.grpcCallDestroy unsafeSC
  grpcDebug $ "freeing parentPtr: " ++ show parentPtr
  forM_ parentPtr free
