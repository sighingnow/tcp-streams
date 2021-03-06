{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

------------------------------------------------------------------------------
import           Control.Concurrent             (forkIO, newEmptyMVar, putMVar,
                                                 takeMVar)
import qualified Control.Exception              as E
import qualified Network.Socket                 as N
import           System.Timeout                 (timeout)
import           Test.Framework
import           Test.Framework.Providers.HUnit
import           Test.HUnit                     hiding (Test)
import qualified Data.ByteString                as B
import           System.Directory               (removeFile)
------------------------------------------------------------------------------
import qualified Data.OpenSSLSetting            as SSL
import qualified System.IO.Streams              as Stream
import qualified System.IO.Streams.TCP          as Raw
import qualified System.IO.Streams.OpenSSL      as SSL
------------------------------------------------------------------------------

main :: IO ()
main = defaultMain tests
  where
    tests = [ testGroup "TCP" rawTests
            , testGroup "OpenSSL" sslTests
            ]

------------------------------------------------------------------------------

rawTests :: [Test]
rawTests = [ testRawSocket ]

testRawSocket :: Test
testRawSocket = testCase "network/socket" $
    N.withSocketsDo $ do
    x <- timeout (10 * 10^(6::Int)) go
    assertEqual "ok" (Just ()) x

  where
    go = do
        portMVar   <- newEmptyMVar
        resultMVar <- newEmptyMVar
        forkIO $ client portMVar resultMVar
        server portMVar
        l <- takeMVar resultMVar
        assertEqual "testSocket" l ["ok"]

    client mvar resultMVar = do
        _ <- takeMVar mvar
        (is, os, sock) <- Raw.connect "127.0.0.1" 8888
        Stream.fromList ["", "ok"] >>= Stream.connectTo os
        N.shutdown sock N.ShutdownSend
        Stream.toList is >>= putMVar resultMVar
        N.close sock

    server mvar = do
        sock <- Raw.bindAndListen 8888 1024
        putMVar mvar ()
        (is, os, csock, _) <- Raw.accept sock
        os' <- Stream.atEndOfOutput (N.close csock) os
        os' `Stream.connectTo` is

------------------------------------------------------------------------------

sslTests :: [Test]
sslTests = [ testSSLSocket, testHTTPS' ]

testSSLSocket :: Test
testSSLSocket = testCase "network/socket" $
    N.withSocketsDo $ do
    x <- timeout (10 * 10^(6::Int)) go
    assertEqual "ok" (Just ()) x

  where
    go = do
        portMVar   <- newEmptyMVar
        resultMVar <- newEmptyMVar
        forkIO $ client portMVar resultMVar
        server portMVar
        l <- takeMVar resultMVar
        assertEqual "testSocket" l (Just "ok")

    client mvar resultMVar = do
        _ <- takeMVar mvar
        cp <- SSL.makeClientSSLContext (SSL.CustomCAStore "./test/cert/ca.pem")
        (is, os, ctx) <- SSL.connect cp (Just "Winter") "127.0.0.1" 8890
        Stream.fromList ["", "ok"] >>= Stream.connectTo os
        Stream.read is >>= putMVar resultMVar  -- There's no shutdown in tls, so we won't get a 'Nothing'
        SSL.close ctx

    server mvar = do
        sp <- SSL.makeServerSSLContext "./test/cert/server.crt" [] "./test/cert/server.key"
        sock <- Raw.bindAndListen 8890 1024
        putMVar mvar ()
        (is, os, ssl, _) <- SSL.accept sp sock
        os' <- Stream.atEndOfOutput (SSL.close ssl) os
        os' `Stream.connectTo` is

testHTTPS' :: Test
testHTTPS' = testCase "network/https" $
    N.withSocketsDo $ do
    x <- timeout (10 * 10^(6::Int)) go
    assertEqual "ok" (Just 1024) x
  where
    go = do
        cp <- SSL.makeClientSSLContext SSL.SystemCAStore
        (is, os, ctx) <- SSL.connect cp (Just "*.google.com") "www.google.com" 443
        Stream.write (Just "GET / HTTP/1.1\r\n") os
        Stream.write (Just "Host: www.google.com\r\n") os
        Stream.write (Just "\r\n") os
        bs <- Stream.readExactly 1024 is
        SSL.close ctx
        return (B.length bs)
