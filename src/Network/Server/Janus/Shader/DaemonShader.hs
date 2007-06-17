-- ------------------------------------------------------------

{- |
   Module     : Network.Server.Janus.Shader.DaemonShader
   Copyright  : Copyright (C) 2006 Christian Uhlig
   License    : MIT

   Maintainer : Christian Uhlig (uhl\@fh-wedel.de)
   Stability  : experimental
   Portability: portable
   Version    : $Id: DaemonShader.hs, v1.1 2007/03/26 00:00:00 janus Exp $

   Janus Daemon Library
   
   A Daemon Shader is a Shader forking a new process and immediately returning control to the system. Usually they have no effect on 
   the invoking Transaction, although this behaviour is no necessity. By defining Daemon Shaders in the server's or a handler's init
   element, daemons may be installed before any request is served. As daemons remain in possession of the Context state, they may
   still affect system operation.
-}

-- ------------------------------------------------------------

{-# OPTIONS -fglasgow-exts -farrows #-}

module Network.Server.Janus.Shader.DaemonShader
    (
    -- daemon shaders
      daemonCreator
    , testDaemon
    , logControlDaemon
    , sessionDaemon
    )
where

import Control.Concurrent
import Text.XML.HXT.Arrow

import Network.Server.Janus.Core as Shader
import Network.Server.Janus.Messaging
import Network.Server.Janus.XmlHelper
import Network.Server.Janus.JanusPaths

{- |
Creates a Daemon Shader executing an arbitrary Arrow based on the Context state if invoked. The Arrow does not need to depend on an input and
does not need to deliver an output.
-}
daemonCreator :: JanusArrow Context () () -> ShaderCreator
daemonCreator daemonArrow =
    mkDynamicCreator $ proc (conf, _) -> do
        ident   <- getVal _shader_config_id                     -<  conf
        let shader = proc in_ta -> do
            createThread "/global/threads" ident daemonArrow    -<  ()
            returnA                                             -<  in_ta
        returnA                                                     -<  shader

{- |
Creates a Daemon forwarding the messages stored in the channel "local" to the channel "global" on the l_debug level every second. 
-}
testDaemon :: ShaderCreator
testDaemon = 
    daemonCreator thedaemon
    where
        thedaemon = proc _ -> do
            "global" <-@ mkSimpleLog "DaemonShader.hs:testDaemon" ("testDaemon invoked...") l_debug     -< ()
            arrIO $ threadDelay                                                                         -< 1000000
            msg <- listA $ getMsg "local" >>> showMsg                                                   -< ()
            "global" <-@ mkSimpleLog "DaemonShader.hs:testDaemon" ("local messages: " ++ (show msg)) l_debug -<< ()
            thedaemon                                                                                   -< ()

{- |
Creates a Daemon blocking on channel \"control\" for arriving messages. When a message arrives it is processed if it is a Control Message. In this
case the \"messagelevel\" state attribute is read and used to reset the message handler of channel "global" with a filter based on the message level.
Afterwards all Control Messages are removed from the \"control\" channel.
This Daemon allows changing the message level the \"global\" message channel forwards to the console. This is utilized by the current Janus Console. 
Of course more simple implementation were possible - this is only to demonstrate the work of Daemons and Control Messages.
-}
logControlDaemon :: ShaderCreator
logControlDaemon = 
    daemonCreator thedaemon
    where
        thedaemon = proc _ -> do
            msg     <- listA $ listenChannel "control"                                                  -<  () 
            msg'    <- listA $ constL msg >>> showMsg                                                   -<< ()
            "global" <-@ mkSimpleLog "DaemonShader.hs:logControlDaemon" ("logControlDaemon invoked...") l_debug -< ()
            level   <- listA $ 
                        constL msg 
                        >>> 
                        getMsgTypeFilter ControlMsg 
                        >>> 
                        getMsgState "messagelevel"                                                      -<< ()
            case msg' of
                []     -> this                                                                  -<  ()
                (x:_)  -> 
                    (proc _ -> do
                        "global" <-@ mkSimpleLog "DaemonShader.hs:logControlDaemon" ("control message detected: " ++ x) l_info -< ()
                        let myhandler   = (filterHandler (getMsgLevelFilter (read $ head level)) >>> consoleHandler)
                        changeHandler "global" (\_ -> myhandler) -<< ()
                        )                                                                       -<< ()
            filterMsg "control" (neg $ getMsgTypeFilter ControlMsg)                                     -<  ()
            thedaemon                                                                                   -<  ()
                    
{- |
Periodically (every 10 seconds) checks the timestamps of all sessions (stored under \/session in the \"global\" scope). If a session state
change is older than 60 seconds, the respective session is removed from the \"global\" scope.
-}
sessionDaemon :: ShaderCreator
sessionDaemon = 
    daemonCreator thedaemon
    where
        thedaemon = 
            proc _ -> do
                "global" <-@ mkSimpleLog "sessionDaemon" ("sessionDaemon invoked...") l_debug           -<  ()
                arrIO $ threadDelay                                                                     -<  10000000 
                (
                    (proc _ -> do
                        sessions <- listA $ listStateTrees "/global/session"                    -<  ()
                        checkSessions sessions                                                  -<< ()
                        )
                    `orElse` 
                    this
                    )                                                                                   -<  ()
                "global" <-@ mkSimpleLog "sessionDaemon" ("sessionDaemon completed...") l_debug         -<  ()
                thedaemon                                                                               -<  ()
        checkSessions []     = this
        checkSessions (x:xs) = 
            proc _ -> do
                current_ts  <- getCurrentTS                                                             -<  ()
                session_ts  <- getSC ("/global/session/" ++ x) >>> getCellTS                            -<  ()
                let diff_ts = current_ts - session_ts
                "global" <-@ mkSimpleLog "sessionDaemon" ("Session " ++ x ++ " inactive for " ++ (show diff_ts) ++ " ms.") l_info -<< ()
                ("global" <-@ mkSimpleLog "sessionDaemon" ("Removing session " ++ x) l_info
                    >>> 
                    delStateTree  ("/global/session/" ++ x) 
                    ) 
                    `whenP` 
                    (\_ -> diff_ts > 60000)                                                             -<< ()
                checkSessions xs                                                                        -<  ()
