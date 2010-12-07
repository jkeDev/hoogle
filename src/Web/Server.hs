{-# LANGUAGE RecordWildCards #-}

module Web.Server(server) where

import General.Base
import General.Web
import CmdLine.All
import Web.Response
import Control.Concurrent
import Control.Exception
import Network
import Network.HTTP
import Network.URI
import Network.Socket
import Data.Time
import General.System


server :: CmdLine -> IO ()
server q@Server{..} = withSocketsDo $ do
    stop <- httpServer port (talk q)
    putStrLn $ "Started Hoogle Server on port " ++ show port
    b <- hIsClosed stdin
    (if b then forever $ threadDelay maxBound else getChar >> return ()) `finally` stop


-- | Given a port and a handler, return an action to shutdown the server
httpServer :: Int -> (Request String -> IO (Response String)) -> IO (IO ())
httpServer port handler = do
    s <- listenOn $ PortNumber $ fromIntegral port
    forkIO $ forever $ do
        (sock,host) <- Network.Socket.accept s
        bracket
            (socketConnection "" sock)
            close
            (\strm -> do
                start <- getCurrentTime
                res <- receiveHTTP strm
                case res of
                    Left x -> do
                        putStrLn $ "Bad request: " ++ show x
                        respondHTTP strm $ Response (4,0,0) "Bad Request" [] ("400 Bad Request: " ++ show x)
                    Right x -> do
                        respondHTTP strm =<< handler x
                        end <- getCurrentTime
                        let t = floor $ diffUTCTime end start * 1000
                        putStrLn $ "Served in " ++ show t ++ "ms: " ++ unescapeURL (show $ rqURI x)
            )
    return $ sClose s


-- FIXME: This should be in terms of Lazy ByteString's, for higher performance
--        serving of local files
talk :: CmdLine -> Request String -> IO (Response String)
talk Server{..} Request{rqURI=URI{uriPath=path,uriQuery=query}}
    | path `elem` ["/","/hoogle"] = do
        args <- cmdLineWeb $ parseHttpQueryArgs $ drop 1 query
        r <- response "/res" args{databases=databases}
        return $ if local_ then fmap rewriteFileLinks r else r
    | takeDirectory path == "/res" = do
        h <- openBinaryFile (resources </> takeFileName path) ReadMode
        src <- hGetContents h
        return $ Response (2,0,0) "OK"
            [Header HdrContentType $ contentExt $ takeExtension path
            ,Header HdrCacheControl "max-age=604800" {- 1 week -}] src
    | local_ && "/file/" `isPrefixOf` path = do
        src <- readFile $ drop 6 path
        return $ Response (2,0,0) "OK" [] src
    | otherwise
        = return $ Response (4,0,4) "Not Found" [] $ "404 Not Found: " ++ show path


rewriteFileLinks :: String -> String
rewriteFileLinks x
    | "href='file://" `isPrefixOf` x = "href='/file/" ++ rewriteFileLinks (drop (13+1) x)
    | null x = x
    | otherwise = head x : rewriteFileLinks (tail x)


contentExt ".png" = "image/png"
contentExt ".css" = "text/css"
contentExt ".js" = "text/javascript"
contentExt _ = "text/plain"
