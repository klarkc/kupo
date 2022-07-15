--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE RecordWildCards #-}

module Kupo.App.Http
    ( -- * Server
      httpServer
    , app

      -- * HealthCheck
    , healthCheck

      -- * Tracer
    , TraceHttpServer (..)
    ) where

import Kupo.Prelude

import Data.List
    ( nub, (\\) )
import Kupo.App.Http.HealthCheck
    ( healthCheck )
import Kupo.Control.MonadDatabase
    ( Database (..) )
import Kupo.Control.MonadLog
    ( HasSeverityAnnotation (..), MonadLog (..), Severity (..), Tracer )
import Kupo.Control.MonadSTM
    ( MonadSTM (..) )
import Kupo.Data.Cardano
    ( DatumHash
    , SlotNo (..)
    , binaryDataToJson
    , datumHashFromText
    , getPointSlotNo
    , hasAssetId
    , hasPolicyId
    , pointToJson
    , slotNoFromText
    )
import Kupo.Data.Configuration
    ( InputManagement )
import Kupo.Data.Database
    ( applyStatusFlag
    , binaryDataFromRow
    , datumHashToRow
    , patternToRow
    , patternToSql
    , pointFromRow
    , resultFromRow
    )
import Kupo.Data.Health
    ( Health )
import Kupo.Data.Http.FilterMatchesBy
    ( FilterMatchesBy (..), filterMatchesBy )
import Kupo.Data.Http.GetCheckpointMode
    ( GetCheckpointMode (..), getCheckpointModeFromQuery )
import Kupo.Data.Http.Response
    ( responseJson, responseJsonEncoding, responseStreamJson )
import Kupo.Data.Http.Status
    ( Status (..), mkStatus )
import Kupo.Data.Http.StatusFlag
    ( hideTransientGhostInputs, statusFlagFromQueryParams )
import Kupo.Data.Pattern
    ( Pattern (..)
    , Result (..)
    , included
    , overlaps
    , patternFromPath
    , patternFromText
    , patternToText
    , resultToJson
    )
import Network.HTTP.Types.Status
    ( status200 )
import Network.Wai
    ( Application
    , Middleware
    , Response
    , pathInfo
    , queryString
    , requestMethod
    , responseLBS
    , responseStatus
    )

import qualified Data.Aeson as Json
import qualified Data.Aeson.Encoding as Json
import qualified Data.Binary.Builder as B
import qualified Kupo.Data.Http.Default as Default
import qualified Kupo.Data.Http.Error as Errors
import qualified Network.HTTP.Types.URI as Http
import qualified Network.Wai.Handler.Warp as Warp

--
-- Server
--

httpServer
    :: Tracer IO TraceHttpServer
    -> InputManagement
    -> (forall a. (Database IO -> IO a) -> IO a)
    -> TVar IO [Pattern]
    -> IO Health
    -> String
    -> Int
    -> IO ()
httpServer tr inputManagement withDatabase patternsVar readHealth host port =
    Warp.runSettings settings
        $ tracerMiddleware tr
        $ app inputManagement withDatabase patternsVar readHealth
  where
    settings = Warp.defaultSettings
        & Warp.setPort port
        & Warp.setHost (fromString host)
        & Warp.setServerName "kupo"
        & Warp.setBeforeMainLoop (logWith tr TraceServerListening{host,port})

--
-- Router
--

app
    :: InputManagement
    -> (forall a. (Database IO -> IO a) -> IO a)
    -> TVar IO [Pattern]
    -> IO Health
    -> Application
app inputManagement withDatabase patternsVar readHealth req send =
    case pathInfo req of
        ("v1" : "health" : args) ->
            routeHealth (requestMethod req, args)

        ("v1" : "checkpoints" : args) ->
            routeCheckpoints (requestMethod req, args)

        ("v1" : "matches" : args) ->
            routeMatches (requestMethod req, args)

        ("v1" : "datums" : args) ->
            routeDatums (requestMethod req, args)

        ("v1" : "patterns" : args) ->
            routePatterns (requestMethod req, args)

        _ ->
            send Errors.notFound
  where
    routeHealth = \case
        ("GET", []) ->
            send . handleGetHealth =<< readHealth
        ("GET", _) ->
            send Errors.notFound
        (_, _) ->
            send Errors.methodNotAllowed

    routeCheckpoints = \case
        ("GET", []) ->
            withDatabase (send .
                handleGetCheckpoints
            )
        ("GET", [arg]) ->
            withDatabase (send <=<
                handleGetCheckpointBySlot (slotNoFromText arg) (queryString req)
            )
        ("GET", _) ->
            send Errors.notFound
        (_, _) ->
            send Errors.methodNotAllowed

    routeMatches = \case
        ("GET", args) ->
            withDatabase (send .
                handleGetMatches inputManagement (patternFromPath args) (queryString req)
            )
        ("DELETE", args) ->
            withDatabase (send <=<
                handleDeleteMatches patternsVar (patternFromPath args)
            )
        (_, _) ->
            send Errors.methodNotAllowed

    routeDatums = \case
        ("GET", [arg]) ->
            withDatabase (send <=<
                handleGetDatum (datumHashFromText arg)
            )
        ("GET", _) ->
            send Errors.notFound
        (_, _) ->
            send Errors.methodNotAllowed

    routePatterns = \case
        ("GET", []) ->
            readTVarIO patternsVar >>= send .
                handleGetPatterns
        ("GET", args) ->
            readTVarIO patternsVar >>= send .
                handleGetMatchingPatterns (patternFromPath args)
        ("PUT", args) ->
            withDatabase (send <=<
                handlePutPattern patternsVar (patternFromPath args)
            )
        ("DELETE", args) ->
            withDatabase (send <=<
                handleDeletePattern patternsVar (patternFromPath args)
            )
        (_, _) ->
            send Errors.methodNotAllowed

--
-- /v1/health
--

handleGetHealth
    :: Health
    -> Response
handleGetHealth =
    responseJson status200 Default.headers

--
-- /v1/checkpoints
--

handleGetCheckpoints
    :: Database IO
    -> Response
handleGetCheckpoints Database{..} = do
    responseStreamJson pointToJson $ \yield done -> do
        points <- runTransaction (listCheckpointsDesc pointFromRow)
        mapM_ yield points
        done

handleGetCheckpointBySlot
    :: Maybe SlotNo
    -> [Http.QueryItem]
    -> Database IO
    -> IO Response
handleGetCheckpointBySlot mSlotNo query Database{..} =
    case (mSlotNo, getCheckpointModeFromQuery query) of
        (Nothing, _) ->
            pure Errors.invalidSlotNo
        (_, Nothing) ->
            pure Errors.invalidStrictMode
        (Just slotNo, Just mode) -> do
            handleGetCheckpointBySlot' slotNo mode
  where
    handleGetCheckpointBySlot' slotNo mode = do
        let successor = succ (unSlotNo slotNo)
        points <- runTransaction (listAncestorsDesc successor 1 pointFromRow)
        pure $ responseJsonEncoding status200 Default.headers $
            case points of
                [point] ->
                    case mode of
                        GetCheckpointStrict
                            | getPointSlotNo point == slotNo ->
                                pointToJson point
                            | otherwise ->
                                Json.null_
                        GetCheckpointClosestAncestor ->
                            pointToJson point
                _ ->
                    Json.null_

--
-- /v1/matches
--

handleGetMatches
    :: InputManagement
    -> Maybe Text
    -> Http.Query
    -> Database IO
    -> Response
handleGetMatches inputManagement patternQuery queryParams Database{..} = do
    case (patternQuery >>= patternFromText, statusFlagFromQueryParams queryParams) of
        (Nothing, _) ->
            Errors.invalidPattern
        (Just{}, Nothing) ->
            Errors.invalidStatusFlag
        (Just p, Just statusFlag) -> do
            let query = statusFlag
                    & hideTransientGhostInputs inputManagement
                    & (`applyStatusFlag` (patternToSql p))
            case filterMatchesBy queryParams of
                Nothing ->
                    Errors.invalidMatchFilter
                Just NoFilter ->
                    responseStreamJson resultToJson $ \yield done -> do
                        runTransaction $ foldInputs query (yield . resultFromRow)
                        done
                Just (FilterByAssetId assetId) ->
                    responseStreamJson resultToJson $ \yield done -> do
                        let yieldIf result = do
                                if hasAssetId (value result) assetId
                                then yield result
                                else pure ()
                        runTransaction $ foldInputs query (yieldIf . resultFromRow)
                        done
                Just (FilterByPolicyId policyId) ->
                    responseStreamJson resultToJson $ \yield done -> do
                        let yieldIf result = do
                                if hasPolicyId (value result) policyId
                                then yield result
                                else pure ()
                        runTransaction $ foldInputs query (yieldIf . resultFromRow)
                        done

handleDeleteMatches
    :: TVar IO [Pattern]
    -> Maybe Text
    -> Database IO
    -> IO Response
handleDeleteMatches patternsVar query Database{..} = do
    patterns <- readTVarIO patternsVar
    case query >>= patternFromText of
        Nothing -> do
            pure Errors.invalidPattern
        Just p | p `overlaps` (patterns \\ [p]) -> do
            pure Errors.stillActivePattern
        Just p -> do
            n <- runImmediateTransaction $ deleteInputsByAddress (patternToSql p)
            pure $ responseLBS status200 Default.headers $
                B.toLazyByteString $ Json.fromEncoding $ Json.pairs $ mconcat
                    [ Json.pair "deleted" (Json.int n)
                    ]

--
-- /v1/datums
--

handleGetDatum
    :: Maybe DatumHash
    -> Database IO
    -> IO Response
handleGetDatum datumArg Database{..} = do
    case datumArg of
        Nothing ->
            pure Errors.malformedDatumHash
        Just datumHash -> do
            datum <- runTransaction $ getBinaryData (datumHashToRow datumHash) binaryDataFromRow
            pure $ responseLBS status200 Default.headers $
                B.toLazyByteString $ Json.fromEncoding $ case datum of
                    Nothing ->
                        Json.null_
                    Just d  ->
                        Json.pairs $ mconcat
                            [ Json.pair "datum" (binaryDataToJson d)
                            ]

--
-- /v1/patterns
--

handleGetPatterns
    :: [Pattern]
    -> Response
handleGetPatterns patterns = do
    responseStreamJson Json.text $ \yield done -> do
        mapM_ (yield . patternToText) patterns
        done

handleGetMatchingPatterns
    :: Maybe Text
    -> [Pattern]
    -> Response
handleGetMatchingPatterns patternQuery patterns = do
    case patternQuery >>= patternFromText of
        Nothing ->
            Errors.invalidPattern
        Just p -> do
            responseStreamJson Json.text $ \yield done -> do
                mapM_ (yield . patternToText) (included p patterns)
                done

handleDeletePattern
    :: TVar IO [Pattern]
    -> Maybe Text
    -> Database IO
    -> IO Response
handleDeletePattern patternsVar query Database{..} = do
    case query >>= patternFromText of
        Nothing ->
            pure Errors.invalidPattern
        Just p -> do
            n <- runImmediateTransaction $ deletePattern (patternToRow p)
            atomically $ modifyTVar' patternsVar (\\ [p])
            pure $ responseLBS status200 Default.headers $
                B.toLazyByteString $ Json.fromEncoding $ Json.pairs $ mconcat
                    [ Json.pair "deleted" (Json.int n)
                    ]

handlePutPattern
    :: TVar IO [Pattern]
    -> Maybe Text
    -> Database IO
    -> IO Response
handlePutPattern patternsVar query Database{..} = do
    case query >>= patternFromText of
        Nothing ->
            pure Errors.invalidPattern
        Just p  -> do
            runImmediateTransaction $ insertPatterns [patternToRow p]
            patterns <- atomically $ do
                modifyTVar' patternsVar (nub . (p :))
                readTVar patternsVar
            pure $ responseLBS status200 Default.headers $
                B.toLazyByteString $ Json.fromEncoding $ Json.list
                    (Json.text . patternToText)
                    patterns

--
-- Tracer
--

tracerMiddleware :: Tracer IO TraceHttpServer -> Middleware
tracerMiddleware tr runApp req send = do
    runApp req $ \res -> do
        let status = mkStatus (responseStatus res)
        logWith tr $ TraceRequest {method, path, status}
        send res
  where
    method = decodeUtf8 (requestMethod req)
    path = pathInfo req

data TraceHttpServer where
    TraceServerListening
        :: { host :: String, port :: Int }
        -> TraceHttpServer
    TraceRequest
        :: { method :: Text, path :: [Text], status :: Status }
        -> TraceHttpServer
    deriving stock (Generic)

instance HasSeverityAnnotation TraceHttpServer where
    getSeverityAnnotation = \case
        TraceServerListening{} -> Notice
        TraceRequest{} -> Info

instance ToJSON TraceHttpServer where
    toEncoding =
        defaultGenericToEncoding
