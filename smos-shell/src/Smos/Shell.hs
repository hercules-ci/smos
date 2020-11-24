module Smos.Shell
  ( smosShell,
    smosShellWith,
  )
where

import Control.Monad.IO.Class
import Control.Monad.Reader
import Data.IORef
import qualified Options.Applicative as OptParse
import qualified Smos.Query as Query
import qualified Smos.Query.OptParse as Query
import qualified Smos.Report.OptParse as Report
import System.Console.Haskeline as Haskeline
import System.Console.Haskeline.Command.KillRing as Haskeline
import System.Console.Haskeline.History as Haskeline
import System.Console.Haskeline.InputT as Haskeline
import System.Console.Haskeline.Term as Haskeline
import System.Exit
import System.IO

smosShell :: IO ()
smosShell = smosShellWith Query.defaultReportConfig stdin stdout stderr

smosShellWith :: Query.SmosReportConfig -> Handle -> Handle -> Handle -> IO ()
smosShellWith rc inputH outputH errorH = customRunInputT $ loop Nothing
  where
    -- TODO try to use the special TTY handles instead so history works too.
    customRunInputT :: InputT IO a -> IO a
    customRunInputT inputT = do
      historyRef <- newIORef Haskeline.emptyHistory
      withBehavior (useFileHandle inputH) $ \rt -> do
        let runTerm =
              rt
                { putStrOut = \s -> do
                    hPutStr outputH s
                    hFlush outputH
                }
        runReaderT
          ( runReaderT
              ( Haskeline.runKillRing
                  ( runReaderT
                      ( runReaderT (unInputT inputT) runTerm
                      )
                      historyRef
                  )
              )
              Haskeline.defaultPrefs
          )
          Haskeline.defaultSettings
    progName :: String
    progName = "query"
    loop :: Maybe ExitCode -> InputT IO ()
    loop mex = do
      let prompt = case mex of
            Just (ExitFailure _) -> "✖ smos > "
            Just ExitSuccess -> "✔ smos > "
            Nothing -> "smos > "
      minput <- getInputLine prompt
      case words <$> minput of
        Nothing -> pure ()
        Just ["exit"] -> pure ()
        Just ["quit"] -> pure ()
        Just [] -> loop Nothing
        Just ("query" : input) -> do
          case OptParse.execParserPure OptParse.defaultPrefs Query.argParser input of
            OptParse.Failure failure -> do
              let (renderedError, exitCode) = OptParse.renderFailure failure progName
              case exitCode of
                ExitSuccess -> outputStrLn renderedError
                ExitFailure _ -> liftIO $ hPutStrLn errorH renderedError
              loop (Just exitCode)
            OptParse.CompletionInvoked completion -> do
              msg <- liftIO $ OptParse.execCompletion completion progName
              outputStrLn msg -- TODO not sure what to do with this yet.
              loop Nothing
            OptParse.Success (Query.Arguments cmd flags) -> do
              liftIO $ do
                instructions <-
                  liftIO $
                    Query.combineToInstructions
                      ( Query.SmosQueryConfig
                          { Query.smosQueryConfigReportConfig = rc,
                            Query.smosQueryConfigInputHandle = inputH,
                            Query.smosQueryConfigOutputHandle = outputH,
                            Query.smosQueryConfigErrorHandle = errorH
                          }
                      )
                      cmd
                      (Report.flagWithRestFlags flags)
                      Query.emptyEnvironment
                      Nothing
                Query.smosQueryWithInstructions instructions
              loop (Just ExitSuccess)
        Just (cmd : _) -> do
          outputStrLn $ "Command not recognised: " <> cmd
          loop Nothing