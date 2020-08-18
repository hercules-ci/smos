{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Smos.ASCIInema.Spec where

import Conduit
import Control.Concurrent (threadDelay)
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString as SB
import Data.Char as Char
import qualified Data.Conduit.Combinators as C
import Data.Conduit.List (sourceList)
import Data.List
import Data.Random.Normal
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as T
import Data.Time
import Data.Yaml
import System.IO
import System.Random
import Text.Printf
import YamlParse.Applicative

data ASCIInemaCommand
  = Wait Word -- Milliseconds
  | SendInput String
  | Type String Int -- Milliseconds
  deriving (Show, Eq)

instance FromJSON ASCIInemaCommand where
  parseJSON = viaYamlSchema

instance YamlSchema ASCIInemaCommand where
  yamlSchema =
    alternatives
      [ objectParser "Wait" $ Wait <$> requiredField "wait" "How long to wait (in milliseconds)",
        objectParser "SendInput" $ SendInput <$> requiredField "send" "The input to send",
        objectParser "Type" $
          Type
            <$> requiredField "type" "The input to send"
            <*> optionalFieldWithDefault "delay" 100 "How long to wait between keystrokes (in milliseconds)"
      ]

type Speed = Double

data Mistakes
  = NoMistakes
  | MistakesWithProbability Double
  deriving (Show, Eq)

inputWriter :: MonadIO m => Speed -> Mistakes -> Handle -> [ASCIInemaCommand] -> ConduitT () void m [(UTCTime, Text)]
inputWriter speed mistakes handle commands =
  inputListProgressConduit commands
    .| inputConduit speed mistakes
    -- .| inputDebugConduit
    .| inputRecorder `fuseUpstream` C.map TE.encodeUtf8 `fuseUpstream` sinkHandle handle

inputRecorder :: MonadIO m => ConduitT i i m [(UTCTime, i)]
inputRecorder = go []
  where
    go acc = do
      mi <- await
      case mi of
        Nothing -> pure acc
        Just i -> do
          now <- liftIO getCurrentTime
          yield i
          go $ (now, i) : acc

inputDebugConduit :: MonadIO m => ConduitT Text Text m ()
inputDebugConduit = C.mapM $ \t -> do
  liftIO $ T.putStrLn $ "Sending input: " <> T.pack (show t)
  pure t

inputListProgressConduit :: MonadIO m => [a] -> ConduitT i a m ()
inputListProgressConduit as = do
  let len = length as
      lenStrLen = length (show len)
      showIntWithLen :: Int -> String
      showIntWithLen = printf ("%" <> show lenStrLen <> "d")
      progressStr i = concat ["Progress: [", showIntWithLen i, "/", showIntWithLen len, "]"]
  forM_ (zip as [1 ..]) $ \(a, i) -> do
    liftIO $ putStrLn $ progressStr i
    yield a

inputConduit :: MonadIO m => Speed -> Mistakes -> ConduitT ASCIInemaCommand Text m ()
inputConduit speed mistakes = awaitForever go
  where
    go :: MonadIO m => ASCIInemaCommand -> ConduitT ASCIInemaCommand Text m ()
    go = \case
      Wait i -> liftIO $ waitMilliSeconds speed i
      SendInput s -> yield $ T.pack s
      Type s i -> typeString s i
    typeString s i =
      forM_ s $ \c -> do
        randomMistake <- liftIO decideToMakeAMistake
        when randomMistake $ makeAMistake c
        waitForChar c
        go $ SendInput [c]
      where
        decideToMakeAMistake :: IO Bool
        decideToMakeAMistake =
          case mistakes of
            NoMistakes -> pure False
            MistakesWithProbability p -> do
              -- Make a mistake with likelihood p
              let accuracy = 1000 :: Int
              randomNum <- randomRIO (0, accuracy)
              pure $ randomNum < round (p * fromIntegral accuracy)
        makeAMistake :: MonadIO m => Char -> ConduitT ASCIInemaCommand Text m ()
        makeAMistake c = do
          let possibleMistakes = validMistakes c
          randomIndex <- liftIO $ randomRIO (0, length possibleMistakes - 1)
          let c' = possibleMistakes !! randomIndex
          waitForChar c'
          go $ SendInput [c']
          waitForChar '\b'
          go $ SendInput ['\b'] -- Backspace
        waitForChar :: MonadIO m => Char -> ConduitT ASCIInemaCommand Text m ()
        waitForChar c = do
          randomDelay <- liftIO $ normalIO' (0, 25) -- Add some random delay to make the typing feel more natural
          go $ Wait $ round (fromIntegral i + randomDelay :: Double)

-- | Add a delay multiplier based on what kind of character it is to make the typing feel more natural.
charSpeed :: Char -> Double
charSpeed ' ' = 1.25
charSpeed '\b' = 3 -- It takes a while to notice a mistake
charSpeed c
  | c `elem` ['a' .. 'z'] = 0.75
  | c `elem` ['A' .. 'Z'] = 1.5 -- Because you have to press 'shift'
  | otherwise = 2 -- Special characters take even longer

waitMilliSeconds :: Double -> Word -> IO ()
waitMilliSeconds speed delay = threadDelay $ round $ fromIntegral (delay * 1000) * speed

validMistakes :: Char -> [Char]
validMistakes c =
  if Char.isUpper c -- You won't accidentally type an upper-case character if the character you intended was lower-case
    then
      concat
        [ ['A' .. 'Z'],
          "[{+(=*)!}]" -- Assuming a keyboard layout where shift gives you punctuation, like qwerty
        ]
    else
      concat
        [ ['a' .. 'z'],
          ['0' .. '9']
        ]