{-# LANGUAGE CPP #-}
{-# LANGUAGE NoOverloadedStrings #-}
module Skylighting.Format.HTML (
      formatHtmlInline
    , formatHtmlBlock
    , formatHtmlStyled
    , styleToCss
    ) where

import Data.List (intersperse, sort)
import qualified Data.Map as Map
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Skylighting.Types
import Text.Blaze.Html
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Data.String (fromString)
#if !MIN_VERSION_base(4,11,0)
import Data.Semigroup
#endif

-- | Format tokens using HTML spans inside @code@ tags. For example,
-- A @KeywordTok@ is rendered as a span with class @kw@.
-- Short class names correspond to 'TokenType's as follows:
-- 'KeywordTok'        = @kw@,
-- 'DataTypeTok'       = @dt@,
-- 'DecValTok'         = @dv@,
-- 'BaseNTok'          = @bn@,
-- 'FloatTok'          = @fl@,
-- 'CharTok'           = @ch@,
-- 'StringTok'         = @st@,
-- 'CommentTok'        = @co@,
-- 'OtherTok'          = @ot@,
-- 'AlertTok'          = @al@,
-- 'FunctionTok'       = @fu@,
-- 'RegionMarkerTok'   = @re@,
-- 'ErrorTok'          = @er@,
-- 'ConstantTok'       = @cn@,
-- 'SpecialCharTok'    = @sc@,
-- 'VerbatimStringTok' = @vs@,
-- 'SpecialStringTok'  = @ss@,
-- 'ImportTok'         = @im@,
-- 'DocumentationTok'  = @do@,
-- 'AnnotationTok'     = @an@,
-- 'CommentVarTok'     = @cv@,
-- 'VariableTok'       = @va@,
-- 'ControlFlowTok'    = @cf@,
-- 'OperatorTok'       = @op@,
-- 'BuiltInTok'        = @bu@,
-- 'ExtensionTok'      = @ex@,
-- 'PreprocessorTok'   = @pp@,
-- 'AttributeTok'      = @at@,
-- 'InformationTok'    = @in@,
-- 'WarningTok'        = @wa@.
-- A 'NormalTok' is not marked up at all.
formatHtmlInline :: FormatOptions -> [SourceLine] -> Html
formatHtmlInline opts = formatHtmlMaybeStyled opts Nothing

-- | Format tokens with the given style pre-applied to get
-- HTML inline style tags. See the documentation for
-- 'formatHtmlInline' for information about how tokens are
-- encoded.
formatHtmlStyled :: FormatOptions -> Style -> [SourceLine] -> Html
formatHtmlStyled opts style = formatHtmlMaybeStyled opts (Just style)

formatHtmlMaybeStyled :: FormatOptions -> Maybe Style -> [SourceLine] -> Html
formatHtmlMaybeStyled opts styled = wrapCode opts (isJust styled)
                                  . mconcat . intersperse (toHtml "\n")
                                  . map (mapM_ (tokenToHtml opts styled))

-- | Format tokens as an HTML @pre@ block. Each line is wrapped in an a
-- element with the class ‘source-line’. If line numbering
-- is selected, the surrounding pre is given the class ‘numberSource’,
-- and the resulting html will display line numbers thanks to the included
-- CSS.  See the documentation for 'formatHtmlInline' for information about how
-- tokens are encoded.
formatHtmlBlock :: FormatOptions -> [SourceLine] -> Html
formatHtmlBlock opts ls =
  H.div ! A.class_ (toValue "sourceCode") $
  H.pre ! A.class_ (toValue $ Text.unwords classes)
        $ wrapCode opts False
        $ mconcat . intersperse (toHtml "\n")
        $ zipWith (sourceLineToHtml opts) [startNum..] ls
  where  classes = Text.pack "sourceCode" :
                   [Text.pack "numberSource" | numberLines opts] ++
                   [x | x <- containerClasses opts
                      , x /= Text.pack "sourceCode"]
         startNum = LineNo $ startNumber opts

wrapCode :: FormatOptions -> Bool -> Html -> Html
wrapCode opts ws h = H.code ! A.class_ (toValue $ Text.unwords
                                                     $ Text.pack "sourceCode"
                                                     : codeClasses opts)
                         !? (styled, A.style (toValue stylings))
                         $ h
  where  counterOverride = "counter-reset: source-line " <> show startZero <> ";"
         wsPre = "white-space: pre;"
         startZero = startNumber opts - 1
         styled = startZero /= 0 || ws
         stylings = (if startZero /= 0 then counterOverride else "") ++
                    (if ws then wsPre else "")

-- | Each line of source is wrapped in an (inline-block) anchor that makes
-- subsequent per-line processing (e.g. adding line numbers) possible.
sourceLineToHtml :: FormatOptions -> LineNo -> SourceLine -> Html
sourceLineToHtml opts lno cont =
  H.span ! A.id lineNum
         $ do
           H.a ! A.href lineRef
               ! (if numberLines opts
                     then mempty
                     else customAttribute (fromString "aria-hidden")
                           (fromString "true")) -- see jgm/pandoc#6352
               ! (if numberLines opts
                     then mempty
                     else customAttribute (fromString "tabindex")
                           (fromString "-1"))
               $ mempty
           mapM_ (tokenToHtml opts Nothing) cont
  where  lineNum = toValue prefixedLineNo
         lineRef = toValue ('#':prefixedLineNo)
         prefixedLineNo = Text.unpack (lineIdPrefix opts) <> show (lineNo lno)

tokenToHtml :: FormatOptions -> Maybe Style -> Token -> Html
tokenToHtml _ _ (NormalTok, txt)  = toHtml txt
tokenToHtml opts Nothing (toktype, txt) =
  if titleAttributes opts
     then sp ! A.title (toValue $ show toktype)
     else sp
   where
     sp = H.span ! A.class_ (toValue $ short toktype) $ toHtml txt
tokenToHtml opts (Just style) (toktype, txt) =
  if titleAttributes opts
     then sp ! A.title (toValue $ show toktype)
     else sp
   where
     cl = A.class_ (toValue $ short toktype)
     sp = H.span ! cl ! st $ toHtml txt
     st = A.style (toValue $ toCssSpecs tokstyle)
         where tokstyle = (Map.!) (tokenStyles style) toktype

short :: TokenType -> String
short KeywordTok        = "kw"
short DataTypeTok       = "dt"
short DecValTok         = "dv"
short BaseNTok          = "bn"
short FloatTok          = "fl"
short CharTok           = "ch"
short StringTok         = "st"
short CommentTok        = "co"
short OtherTok          = "ot"
short AlertTok          = "al"
short FunctionTok       = "fu"
short RegionMarkerTok   = "re"
short ErrorTok          = "er"
short ConstantTok       = "cn"
short SpecialCharTok    = "sc"
short VerbatimStringTok = "vs"
short SpecialStringTok  = "ss"
short ImportTok         = "im"
short DocumentationTok  = "do"
short AnnotationTok     = "an"
short CommentVarTok     = "cv"
short VariableTok       = "va"
short ControlFlowTok    = "cf"
short OperatorTok       = "op"
short BuiltInTok        = "bu"
short ExtensionTok      = "ex"
short PreprocessorTok   = "pp"
short AttributeTok      = "at"
short InformationTok    = "in"
short WarningTok        = "wa"
short NormalTok         = ""

-- | Returns CSS for styling highlighted code according to the given style.
styleToCss :: Style -> String
styleToCss f = unlines $
  divspec ++ numberspec ++ colorspec ++ linkspec ++
    sort (map toCss (Map.toList (tokenStyles f)))
   where colorspec = pure . unwords $ [
            "div.sourceCode\n  {"
          , maybe "" (\c -> "color: "            ++ fromColor c ++ ";") (defaultColor f)
          , maybe "" (\c -> "background-color: " ++ fromColor c ++ ";") (backgroundColor f)
          , "}"
          ]
         numberspec = [
            "pre.numberSource code"
          , "  { counter-reset: source-line 0; }"
          , "pre.numberSource code > span"
          , "  { position: relative; left: -4em; counter-increment: source-line; }"
          , "pre.numberSource code > span > a:first-child::before"
          , "  { content: counter(source-line);"
          , "    position: relative; left: -1em; text-align: right; vertical-align: baseline;"
          , "    border: none; display: inline-block;"
          , "    -webkit-touch-callout: none; -webkit-user-select: none;"
          , "    -khtml-user-select: none; -moz-user-select: none;"
          , "    -ms-user-select: none; user-select: none;"
          , "    padding: 0 4px; width: 4em;"
          , maybe "" (\c -> "    background-color: " ++ fromColor c ++ ";\n")
              (lineNumberBackgroundColor f) ++
            maybe "" (\c -> "    color: " ++ fromColor c ++ ";\n")
              (lineNumberColor f) ++
            "  }"
          , "pre.numberSource { margin-left: 3em; " ++
              maybe "" (\c -> "border-left: 1px solid " ++ fromColor c ++ "; ") (lineNumberColor f) ++
              " padding-left: 4px; }"
          ]
         divspec = [
            "pre > code.sourceCode { white-space: pre; position: relative; }" -- position relative needed for relative contents
          , "pre > code.sourceCode > span { display: inline-block; line-height: 1.25; }"
          , "pre > code.sourceCode > span:empty { height: 1.2em; }" -- correct empty line height
          , ".sourceCode { overflow: visible; }" -- needed for line numbers
          , "code.sourceCode > span { color: inherit; text-decoration: inherit; }"
          , "div.sourceCode { margin: 1em 0; }" -- Collapse neighbours correctly
          , "pre.sourceCode { margin: 0; }" -- Collapse neighbours correctly
          , "@media screen {"
          , "div.sourceCode { overflow: auto; }" -- do not overflow on screen
          , "}"
          , "@media print {"
          , "pre > code.sourceCode { white-space: pre-wrap; }"
          , "pre > code.sourceCode > span { text-indent: -5em; padding-left: 5em; }"
          , "}"
          ]
         linkspec = [ "@media screen {"
          , "pre > code.sourceCode > span > a:first-child::before { text-decoration: underline; }"
          , "}"
          ]

toCss :: (TokenType, TokenStyle) -> String
toCss (t, tf) = "code span" ++ (if null (short t) then "" else ('.' : short t)) ++ " { "
                ++ toCssSpecs tf ++ "} /* " ++ showTokenType t ++ " */"
    where
      showTokenType t' = case reverse (show t') of
                           'k':'o':'T':xs -> reverse xs
                           _              -> ""

toCssSpecs :: TokenStyle -> String
toCssSpecs tf = colorspec ++ backgroundspec ++ weightspec ++ stylespec ++ decorationspec
    where colorspec = maybe "" (\col -> "color: " ++ fromColor col ++ "; ") $ tokenColor tf
          backgroundspec = maybe "" (\col -> "background-color: " ++ fromColor col ++ "; ") $ tokenBackground tf
          weightspec = if tokenBold tf then "font-weight: bold; " else ""
          stylespec  = if tokenItalic tf then "font-style: italic; " else ""
          decorationspec = if tokenUnderline tf then "text-decoration: underline; " else ""
