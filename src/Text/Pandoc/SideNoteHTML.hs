{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
   Module      : Text.Pandoc.SideNoteHTML
   Description : Convert pandoc footnotes to sidenotes
   Copyright   : (c) Tony Zorman  2023
   License     : MIT
   Maintainer  : Tony Zorman <soliditsallgood@mailbox.org>
   Stability   : experimental
   Portability : non-portable
-}
module Text.Pandoc.SideNoteHTML (usingSideNotesHTML) where

import           Control.Monad (foldM)
import           Control.Monad.State (State, get, modify', runState)
import           Data.Text (Text)
import qualified Data.Text as T
import           Text.Pandoc (runPure, writeHtml5String)
import           Text.Pandoc.Definition (Block(..), Inline(..), Pandoc(..))
import           Text.Pandoc.Options (WriterOptions)
import           Text.Pandoc.Shared (tshow)
import           Text.Pandoc.Walk (walkM)

-- type NoteType :: Type
data NoteType = Sidenote
              | Marginnote
  deriving stock (Show, Eq)

-- type SidenoteState :: Type
data SidenoteState = SNS { _writer :: !WriterOptions, counter :: !Int }

-- type Sidenote :: Type -> Type
type Sidenote = State SidenoteState

data SidenoteOptions = SNO { tagType :: Text, tagRole :: Text }

defaultSidenoteOptions :: SidenoteOptions
defaultSidenoteOptions = SNO { tagType = "aside", tagRole = "note" }

-- | Like 'Text.Pandoc.SideNote.usingSideNotes', but immediately
-- pre-render the sidenotes.  This has the advantage that sidenotes may
-- be wrapped in a @<div>@ (instead of a 'Span'), which allows arbitrary
-- blocks to be nested in them.  The disadvantage is that one now has to
-- specify the 'WriterOptions' for the current document, meaning this is
-- meant to be used as a module and is unlikely to be useful as a
-- standalone application.
--
-- ==== __Example__
--
-- Using this function with <https://jaspervdj.be/hakyll/ hakyll> could
-- look something like the following, defining an equivalent to the
-- default @pandocCompiler@.
--
-- > myPandocCompiler :: Compiler (Item String)
-- > myPandocCompiler =
-- >   pandocCompilerWithTransformM
-- >     defaultHakyllReaderOptions
-- >     defaultHakyllWriterOptions
-- >     (usingSideNotesHTML defaultHakyllWriterOptions)
--
usingSideNotesHTMLWith :: SidenoteOptions -> WriterOptions -> Pandoc -> Pandoc
usingSideNotesHTMLWith opts writer (Pandoc meta blocks) =
  -- Drop a superfluous paragraph at the start of the document.
  Pandoc meta . someStart . walkBlocks (SNS writer 0) $ blocks
  where
    someStart :: [Block] -> [Block]
    someStart = \case
      (Para [Str ""]:bs) -> bs
      bs -> bs

    walkBlocks :: SidenoteState -> [Block] -> [Block]
    walkBlocks sns = \case
      [] -> []
      (b:bs) -> b' <> walkBlocks s' bs
        where
          (b', s') = walkM (mkSidenote opts) [b] `runState` sns

usingSideNotesHTML :: WriterOptions -> Pandoc -> Pandoc
usingSideNotesHTML = usingSideNotesHTMLWith defaultSidenoteOptions

-- Sidenotes can probably appear in more places; this should be
-- filled-in at some point.
mkSidenote :: SidenoteOptions -> [Block] -> Sidenote [Block]
mkSidenote opts = foldM (\acc b -> (acc <>) <$> single b) []
  where
    -- Try to find and render a sidenote in a single block.
    single :: Block -> Sidenote [Block]
    single = \case
      -- Simulate a paragraph by inserting a dummy block; this is needed
      -- in case two consecutive paragraphs have sidenotes, or a paragraph
      -- doesn't have one at all.
      Para inlines -> (Para [Str ""]:) <$> renderSidenote opts [] inlines
      Plain inlines -> renderSidenote opts [] inlines
      OrderedList attrs bs -> (:[]) . OrderedList attrs
        <$> traverse (mkSidenote opts) bs
      BulletList bs -> (:[]) . BulletList <$> traverse (mkSidenote opts) bs
      block -> pure [block]

renderSidenote :: SidenoteOptions -> [Inline] -> [Inline] -> Sidenote [Block]
renderSidenote opts !inlines = \case
  []         -> pure [plain inlines]
  Note bs:xs -> do
    block <- go bs
    mappend   -- Start gluing before, see [Note Comment].
      [plain (RawInline "html" commentStart:inlines), block]
      <$> renderSidenote
        opts
        [RawInline "html" commentEnd] -- End gluing after
        xs
  b:xs       -> renderSidenote opts (b:inlines) xs
  where
    go :: [Block] -> Sidenote Block
    go blocks = do
      SNS w i <- get <* modify' (\sns -> sns { counter = 1 + counter sns })
      let (typ, noteText) = getNoteType (render w blocks)
      pure . RawBlock "html"
        $ mconcat
          [ commentEnd     -- End gluing before
          , label typ i <> input i <> note opts typ noteText
          , commentStart   -- Start gluing after
          ]

    -- The '{-}' symbol differentiates between margin note and side note.
    getNoteType :: Text -> (NoteType, Text)
    getNoteType t
      | "{-} " `T.isPrefixOf` t = (Marginnote, T.drop 4 t)
      | otherwise = (Sidenote, t)

    render :: WriterOptions -> [Block] -> Text
    render w bs = case runPure (writeHtml5String w (Pandoc mempty bs)) of
      Left err
        -> error $ "Text.Pandoc.SideNoteHTML.writePandocWith: " ++ show err
      Right txt -> T.drop 1 (T.dropWhile (/= '\n') txt)

    commentEnd :: T.Text
    commentEnd = "-->"

    commentStart :: T.Text
    commentStart = "<!--"

    plain :: [Inline] -> Block
    plain = Plain . reverse

label :: NoteType -> Int -> Text
label nt i = "<label for=\"sn-"
  <> tshow i
  <> "\" class=\"margin-toggle"
  <> sidenoteNumber
  <> "\">"
  <> altSymbol
  <> "</label>"
  where
    sidenoteNumber :: Text = case nt of
      Sidenote   -> " sidenote-number"
      Marginnote -> ""

    altSymbol :: Text = case nt of
      Sidenote   -> ""
      Marginnote -> "&#8853;"

input :: Int -> Text
input i = "<input type=\"checkbox\" id=\"sn-"
  <> tshow i
  <> "\" class=\"margin-toggle\"/>"

note :: SidenoteOptions -> NoteType -> Text -> Text
note opts nt body = "<"
  <> tagType opts
  <> " class=\""
  <> T.toLower (tshow nt)
  <> "\" role=\""
  <> tagRole opts
  <> "\">"
  <> body
  <> "</"
  <> tagType opts
  <> ">"

{- [Note Comment]

This is obviously horrible, but we have to do this in order for the
blocks (which are now not inline elements anymore!) immediately before
and after the sidenote to be "glued" to the sidenote itself. In this
way, the number indicating the sidenote does not have an extra space
associated to it on either side, which otherwise would be the case.

-}
