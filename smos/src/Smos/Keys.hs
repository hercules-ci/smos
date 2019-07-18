{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Smos.Keys
  ( KeyPress(..)
  , Modifier(..)
  , Key(..)
  , MatcherConfig(..)
  , renderKeyPress
  , renderKey
  , renderModifier
  , renderMatcherConfig
  , P
  , keyP
  , modifierP
  , keyPressP
  , matcherConfigP
  ) where

import Import

import Data.Aeson as JSON
import Data.Either
import Data.Functor
import qualified Data.Text as T
import Data.Void

import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer

import Graphics.Vty.Input.Events as Vty

instance Validity Key where
  validate k =
    mconcat
      [ genericValidate k
      , case k of
          KFun i -> declare "The function key index is positive" $ i >= 0
          _ -> valid
      ]

instance ToJSON Key where
  toJSON kp = toJSON $ renderKey kp

instance FromJSON Key where
  parseJSON =
    withText "Key" $ \t ->
      case parse (keyP <* eof) "json text" t of
        Left err -> fail $ parseErrorPretty err
        Right r -> pure r

instance Validity Modifier where
  validate = trivialValidation

instance ToJSON Modifier where
  toJSON kp = toJSON $ renderModifier kp

instance FromJSON Modifier where
  parseJSON =
    withText "Modifier" $ \t ->
      case parse (modifierP <* eof) "json text" t of
        Left err -> fail $ parseErrorPretty err
        Right r -> pure r

data KeyPress =
  KeyPress
    { keyPressKey :: !Key
    , keyPressMods :: ![Modifier]
    }
  deriving (Show, Eq, Ord, Generic)

instance Validity KeyPress where
  validate kp@(KeyPress _ mods) =
    mconcat [genericValidate kp, declare "Each of the mods appears at most once" $ nub mods == mods]

instance ToJSON KeyPress where
  toJSON kp = toJSON $ renderKeyPress kp

instance FromJSON KeyPress where
  parseJSON =
    withText "KeyPress" $ \t ->
      case parse (keyPressP <* eof) "json text" t of
        Left err -> fail $ parseErrorPretty err
        Right r -> pure r

type P = Parsec Void Text

renderKey :: Key -> Text
renderKey (KChar '\t') = "<tab>"
renderKey (KChar ' ') = "<space>"
renderKey (KFun i) = "F" <> T.pack (show i)
renderKey (KChar c) = T.singleton c
renderKey k = T.pack $ go $ show k
    -- Because these constructors all start with 'K'
  where
    go [] = []
    go ('K':s) = s
    go s = s

keyP :: P Key
keyP =
  choice'
    [ string' "<tab>" $> KChar '\t'
    , string' "<space>" $> KChar ' '
    , string' "UpRight" $> KUpRight
    , string' "UpLeft" $> KUpLeft
    , string' "Up" $> KUp
    , string' "Right" $> KRight
    , string' "PrtScr" $> KPrtScr
    , string' "Pause" $> KPause
    , string' "PageUp" $> KPageUp
    , string' "PageDown" $> KPageDown
    , string' "Menu" $> KMenu
    , string' "Left" $> KLeft
    , string' "Ins" $> KIns
    , string' "Home" $> KHome
    , string' "Esc" $> KEsc
    , string' "Enter" $> KEnter
    , string' "End" $> KEnd
    , string' "DownRight" $> KDownRight
    , string' "DownLeft" $> KDownLeft
    , string' "Down" $> KDown
    , string' "Del" $> KDel
    , string' "Center" $> KCenter
    , string' "Begin" $> KBegin
    , string' "BackTab" $> KBackTab
    , string' "BS" $> KBS
    , do void $ string' "F"
         i <- decimal
         pure $ KFun i
    , KChar <$> satisfy (const True)
    ]

renderModifier :: Modifier -> Text
renderModifier MShift = "S"
renderModifier MCtrl = "C"
renderModifier MMeta = "M"
renderModifier MAlt = "A"

modifierP :: P Modifier
modifierP =
  choice [string' "S" $> MShift, string' "C" $> MCtrl, string' "M" $> MMeta, string' "A" $> MAlt]

renderKeyPress :: KeyPress -> Text
renderKeyPress (KeyPress key mods) =
  case mods of
    [] -> renderKey key
    _ -> T.intercalate "-" $ map renderModifier mods ++ [renderKey key]

keyPressP :: P KeyPress
keyPressP = do
  mods <-
    many $
    try $ do
      m <- modifierP
      void $ string' "-"
      pure m
  key <- keyP
  pure $ KeyPress key mods

-- a <char>
-- a <any>
-- ab M-c <any>
data MatcherConfig
  = MatchConfKeyPress !KeyPress
  | MatchConfAnyChar
  | MatchConfCatchAll -- Rename to 'Any'
  | MatchConfCombination !KeyPress !MatcherConfig
  deriving (Show, Eq, Generic)

instance Validity MatcherConfig

instance ToJSON MatcherConfig where
  toJSON kp = toJSON $ renderMatcherConfig kp

instance FromJSON MatcherConfig where
  parseJSON =
    withText "MatcherConfig" $ \t ->
      case parse (matcherConfigP <* eof) "json text" t of
        Left err -> fail $ parseErrorPretty err
        Right r -> pure r

renderMatcherConfig :: MatcherConfig -> Text
renderMatcherConfig mc =
  case mc of
    MatchConfAnyChar -> "<char>"
    MatchConfCatchAll -> "<any>"
    MatchConfKeyPress kp -> renderKeyPress kp
    MatchConfCombination kp rest ->
      let mkp' =
            case rest of
              MatchConfCombination kp' _ ->Just  kp'
              MatchConfKeyPress kp' ->Just kp'
              _ -> Nothing
      in
          T.concat
            [ renderKeyPress kp
            , case mkp' of
                Nothing -> " "
                Just kp' -> case keyPressMods kp' of
                 [] -> ""
                 _ -> " "
            , renderMatcherConfig rest
            ]

matcherConfigP :: P MatcherConfig
matcherConfigP = choice' [charP, anyP, multipleMatchersP]

charP :: P MatcherConfig
charP = string' "<char>" $> MatchConfAnyChar

anyP :: P MatcherConfig
anyP = string' "<any>" $> MatchConfCatchAll

multipleMatchersP :: P MatcherConfig
multipleMatchersP = go
  where
    go = do
      list <-
        sepBy1
          ((Left <$> (try charP <|> try anyP)) <|> (Right <$> keyPressP))
          (void $ optional $ string' " ")
      case reverse list of
        [] -> pure MatchConfCatchAll
        (l:rest) ->
          if any isLeft rest
            then fail "<char> or <any> not allowed in any position other than the last"
            else do
              let rest' = rights rest
              let l' =
                    case l of
                      Left r -> r
                      Right kp -> MatchConfKeyPress kp
              pure $ foldl (flip MatchConfCombination) l' rest'

choice' :: [P a] -> P a
choice' [] = empty
choice' [a] = a
choice' (a:as) = try a <|> choice' as
