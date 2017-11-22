{-# LANGUAGE OverloadedStrings #-}

import Control.Monad
import qualified Data.ByteString.Lazy as BL
import Data.Char (toLower)
import qualified Data.Map as Map
import Data.Monoid
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Version (showVersion)
import Paths_skylighting (version)
import Skylighting
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO (hPutStrLn, stderr)
import Text.Blaze.Html.Renderer.String
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import Text.Printf (printf)
import Text.Show.Pretty (ppShow)

data Flag = Sty String
          | Theme String
          | Format String
          | Help
          | Fragment
          | List
          | NumberLines
          | Syn String
          | TitleAttributes
          | Definition String
          | Trace
          | Version
          deriving (Eq, Show)

data HighlightFormat = FormatHtml
                     | FormatLaTeX
                     | FormatNative
                     deriving (Eq, Show)

options :: [OptDescr Flag]
options =
  [Option ['S']
          ["style"]
          (ReqArg Sty "STYLE")
          "specify style"
  ,Option ['t']
          ["theme"]
          (ReqArg Theme "PATH")
          "KDE theme file to be used as style"
  ,Option ['f']
          ["format"]
          (ReqArg Format "FORMAT")
          "output format (html|latex|native)"
  ,Option ['r']
          ["fragment"]
          (NoArg Fragment)
          "fragment, without document header"
  ,Option ['h']
          ["help"]
          (NoArg Help)
          "show usage message"
  ,Option ['l']
          ["list"]
          (NoArg List)
          "list available language syntaxes"
  ,Option ['n']
          ["number-lines"]
          (NoArg NumberLines)
          "number lines"
  ,Option ['s']
          ["syntax"]
          (ReqArg Syn "SYNTAX")
          "specify language syntax to use"
  ,Option ['a']
          ["title-attributes"]
          (NoArg TitleAttributes)
          "include structure in title attributes"
  ,Option ['d']
          ["definition"]
          (ReqArg Definition "PATH")
          "load xml syntax definition file (may be repeated)"
  ,Option ['T']
          ["trace"]
          (NoArg Trace)
          "trace tokenizer for debugging"
  ,Option ['v']
          ["version"]
          (NoArg Version)
          "print version"]

syntaxOf :: SyntaxMap -> [FilePath] -> [Flag] -> IO Syntax
syntaxOf smap fps [] = case concatMap (syntaxesByFilename smap) fps of
                             (s:_) -> return s
                             _     -> err "No syntax specified: use --syntax."
syntaxOf smap _ (Syn lang : _) = do
  case lookupSyntax (Text.pack lang) smap of
         Just s  -> return s
         Nothing -> err ("Could not find syntax definition for " ++ lang)
syntaxOf smap fps (_:xs) = syntaxOf smap fps xs

styleOf :: [Flag] -> IO Style
styleOf [] = return kate
styleOf (Theme fp : _) = do
  raw <- BL.readFile fp
  case parseTheme raw of
       Left e    -> err e
       Right sty -> return sty
styleOf (Sty s : _) = case map toLower s of
                            "pygments"   -> return pygments
                            "espresso"   -> return espresso
                            "kate"       -> return kate
                            "tango"      -> return tango
                            "haddock"    -> return haddock
                            "monochrome" -> return monochrome
                            "breeze-dark" -> return breezeDark
                            _            -> err $ "Unknown style: " ++ s
styleOf (_ : xs) = styleOf xs

formatOf :: [Flag] -> IO HighlightFormat
formatOf [] = return FormatHtml  -- default
formatOf (Format s : _) = case map toLower s of
                            "html"   -> return FormatHtml
                            "latex"  -> return FormatLaTeX
                            "native" -> return FormatNative
                            _        -> err $ "Unknown format: " ++ s
formatOf (_ : xs) = formatOf xs

extractDefinitions :: [Flag] -> IO [Syntax]
extractDefinitions [] = return []
extractDefinitions (Definition fp : xs) = do
  res <- parseSyntaxDefinition fp
  case res of
       Left e -> err e
       Right s -> do
         putStrLn $ "Loaded syntax definition for " ++ Text.unpack (sName s)
         (s:) <$> extractDefinitions xs
extractDefinitions (_:xs) = extractDefinitions xs

err :: String -> IO a
err msg = do
  hPutStrLn stderr msg
  exitWith (ExitFailure 1)

main :: IO ()
main = do
  (opts, fnames, errs) <- getArgs >>= return . getOpt Permute options
  prg <- getProgName
  let usageHeader = prg ++ " [options] [files...]"

  when (not (null errs)) $
     err (concat errs ++ usageInfo usageHeader options)

  when (Help `elem` opts) $ do
     hPutStrLn stderr (usageInfo usageHeader options)
     exitWith ExitSuccess

  when (Version `elem` opts) $ do
     putStrLn (prg ++ " " ++ showVersion version)
     exitWith ExitSuccess

  syntaxMap' <- foldr addSyntaxDefinition defaultSyntaxMap <$>
                    extractDefinitions opts

  case missingIncludes (Map.elems syntaxMap') of
       [] -> return ()
       xs -> err $ "Missing syntax definitions:\n" ++
              unlines (map
                  (\(syn,dep) -> (Text.unpack syn ++ " requires " ++
                    Text.unpack dep ++ " through IncludeRules.")) xs)

  when (List `elem` opts) $ do
     let printSyntaxNames s = putStrLn (printf "%s (%s)"
                                       (Text.unpack (Text.toLower (sShortname s)))
                                       (Text.unpack (sName s)))
     mapM_ printSyntaxNames $ Map.elems syntaxMap'
     exitWith ExitSuccess

  code <- if null fnames
             then Text.getContents
             else mconcat <$> mapM Text.readFile fnames

  let highlightOpts = defaultFormatOpts{ titleAttributes = TitleAttributes `elem` opts
                                       , numberLines = NumberLines `elem` opts
                                       , lineAnchors = NumberLines `elem` opts
                                       }
  let fragment = Fragment `elem` opts
  let fname = case fnames of
                    []    -> ""
                    (x:_) -> x
  let trace = Trace `elem` opts

  syntax <- syntaxOf syntaxMap' fnames opts
  style <- styleOf opts
  format <- formatOf opts

  let config = TokenizerConfig { traceOutput = trace
                               , syntaxMap = syntaxMap' }

  sourceLines <- case tokenize config syntax code of
                      Left e   -> err e
                      Right ls -> return ls

  case format of
       FormatHtml   -> hlHtml fragment fname highlightOpts style sourceLines
       FormatLaTeX  -> hlLaTeX fragment fname highlightOpts style sourceLines
       FormatNative -> putStrLn $ ppShow sourceLines

hlHtml :: Bool               -- ^ Fragment
      -> FilePath            -- ^ Filename
      -> FormatOptions
      -> Style
      -> [SourceLine]
      -> IO ()
hlHtml frag fname opts sty sourceLines =
 if frag
    then putStrLn $ renderHtml fragment
    else putStrLn $ renderHtml $ do
           H.docType
           H.html $ do
             H.head $ do
               pageTitle
               metadata
               css
             H.body $ H.toHtml fragment
  where fragment = formatHtmlBlock opts sourceLines
        css = H.style H.! A.type_ "text/css" $ H.toHtml $ styleToCss sty
        pageTitle = H.title $ H.toHtml fname
        metadata = do
          H.meta H.! A.charset "utf-8"
          H.meta H.! A.name "generator" H.! A.content "highlight-kate"

hlLaTeX :: Bool               -- ^ Fragment
        -> FilePath            -- ^ Filename
        -> FormatOptions
        -> Style
        -> [SourceLine]
        -> IO ()
hlLaTeX frag fname opts sty sourceLines =
 if frag
    then Text.putStrLn fragment
    else Text.putStrLn $
            "\\documentclass{article}\n\\usepackage[margin=1in]{geometry}\n" <>
             macros <> pageTitle <>
             "\n\\begin{document}\n\\maketitle\n" <> fragment <> "\n\\end{document}"
  where fragment = formatLaTeXBlock opts sourceLines
        macros = styleToLaTeX sty
        pageTitle = "\\title{" <> Text.pack fname <> "}\n"

