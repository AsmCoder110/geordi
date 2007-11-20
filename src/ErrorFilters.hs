module ErrorFilters (cc1plus, as, ld, prog) where

import Control.Monad (liftM2)
import Control.Monad.Fix (fix)
import Text.Regex (matchRegex, mkRegex, subRegex, Regex)
import Data.List (intersperse)
import Data.Char (isAlphaNum)
import Text.ParserCombinators.Parsec
  (string, sepBy, parse, char, try, getInput, (<|>), satisfy, spaces, manyTill, anyChar, noneOf, option, oneOf, count, CharParser)
import Text.ParserCombinators.Parsec.Language (haskell)
import Text.ParserCombinators.Parsec.Token (charLiteral, stringLiteral)
import Control.Applicative ((<*), (<*>))

import Util
import Prelude hiding (catch, (.))

as, ld, cc1plus :: String -> String

as e = maybe e (!!1) $ matchRegex (mkRegex "\\b(Error|Warning): ([^\n]*)") e

ld e = maybe e head $ matchRegex (mkRegex "\\b(undefined reference to [^\n]*)") e

prog :: String -> String -> String
prog output result = maybe (output ++ result) head $ matchRegex (mkRegex ":error: ([^\n]*)") output

-- cc1plus:

(>>>) :: CharParser st String -> CharParser st String -> CharParser st String
(>>>) = liftM2 (++)

strSepBy :: CharParser st String -> String -> CharParser st String
strSepBy x y = concat . intersperse y . sepBy x (string y)

cxxExpr :: CharParser st String
cxxExpr =
    try (show . charLiteral haskell >>> cxxExpr) <|>
    try (show . stringLiteral haskell >>> cxxExpr) <|>
    (oneOf "(<[" >>= \o -> return [o] >>> strSepBy cxxExpr "," >>> string [mirror o] >>> cxxExpr) <|>
    option [] ((:[]) . noneOf ")>],'\"" >>> cxxExpr)
  where mirror '(' = ')'; mirror '[' = ']'; mirror '<' = '>'; mirror c = error $ "no mirror for " ++ [c]
    -- Can get confused when faced with sneaky uses of tokens like '>'. Consequently, neither repl_withs nor hide_default_arguments works flawlessly in every imaginable case.

class Tok a where t :: a -> CharParser st String

instance Tok Char where t c = string [c] <* spaces
instance Tok String where t c = string c <* spaces
instance Tok [String] where t c = foldr1 (<|>) (try . t . c)

anyStringTill :: CharParser st String -> CharParser st String
anyStringTill end = fix $ \scan -> end <|> (((:[]) . anyChar) >>> scan)

ioBasics, clutter_namespaces :: [String]
ioBasics = ["streambuf", "ofstream", "ifstream", "fstream", "filebuf", "ostream", "istream", "ostringstream", "istringstream", "stringstream", "iostream", "ios", "string"]
clutter_namespaces = ["std", "boost", "__debug", "__gnu_norm", "__gnu_debug_def", "__gnu_cxx", "__gnu_debug", "__norm"]

localReplacer :: CharParser st String -> CharParser st String
localReplacer x = anyStringTill $ try $ (:[]) . satisfy (not . isIdChar) >>> x
  where isIdChar = isAlphaNum .||. (== '_')
    -- Todo: Doesn't replace at start of input. (Situation does not occur in geordi's use, though.)

defaulter :: [String] -> Int -> ([String] -> CharParser st a) -> CharParser st String
defaulter names idx def = localReplacer $
  t names >>> t '<' >>> (count idx (cxxExpr <* t ',') >>= \prec -> def prec >> return (concat $ intersperse ", " prec)) >>> string ">"
    -- Hides default template arguments.

replacers :: [CharParser st String]
replacers = (.) localReplacer
  [ t clutter_namespaces >> t "::" >> return []
  , string "basic_" >> t ioBasics <* string "<char>"
  , ('w':) . (string "basic_" >> t ioBasics <* string "<wchar_t>")
  , (\e -> "list<" ++ e ++ ">::iterator") . (t "_List_iterator<" >> cxxExpr <* char '>')
  , (\e -> "list<" ++ e ++ ">::const_iterator") . (t "_List_const_iterator<" >> cxxExpr <* char '>')
  , (++ "::const_iterator") . (t "__normal_iterator<const " >> cxxExpr >> t ',' >> cxxExpr <* char '>')
  , (++ "::iterator") . (t "__normal_iterator<" >> cxxExpr >> t ',' >> cxxExpr <* char '>')
      -- Last two are for vector/string.
  , (++ "::const_iterator") . (t "_Safe_iterator<_Rb_tree_const_iterator<" >> cxxExpr >> t ">," >> cxxExpr <* char '>')
  , (++ "::iterator") . (t "_Safe_iterator<_Rb_tree_iterator<" >> cxxExpr >> t ">," >> cxxExpr <* char '>')
      -- Last two are for (multi)set/(multi)map.
  , t "_Safe_iterator<" >> cxxExpr <* t ',' <* cxxExpr <* char '>'
  -- Regarding deque iterators:   deque<void(*)() >::const_iterator   is written in errors as   _Deque_iterator<void (*)(), void (* const&)(), void (* const*)()>   . Detecting the const in there is too hard (for now).
  ] ++
  [ defaulter ["list", "deque", "vector"] 1 (\[e] -> t "allocator<" >> t e >> t '>')
  , defaulter ["set", "multiset", "basic_stringstream", "basic_string", "basic_ostringstream", "basic_istringstream"] 2 (\[e, _] -> t "allocator<" >> t e >> t '>')
  , defaulter ["map", "multimap"] 3 (\[k, v, _] -> t "allocator<pair<const " >> t k >> t ',' >> t v >> t '>' >> t '>')
  , defaulter ["map", "multimap"] 3 (\[k, v, _] -> t "allocator<pair<" >> t k >> t "const" >> t ',' >> t v >> t '>' >> t '>')
  , defaulter ["set", "multiset"] 1 (\[e] -> t "less<" >> t e >> t '>')
  , defaulter ["priority_queue"] 1 (\[e] -> t "vector<" >> t e >> t '>')
  , defaulter ["map", "multimap", "priority_queue"] 2 (\[k, _] -> t "less<" >> t k >> t '>')
  , defaulter ["queue", "stack"] 1 (\[e] -> t "deque<" >> t e >> t '>')
  , defaulter ((("basic_" ++) . ioBasics) ++ ["ostreambuf_iterator", "istreambuf_iterator"]) 1 (\[e] -> t "char_traits<" >> t e >> t '>')
  , defaulter ["istream_iterator"] 3 (const $ t "long int") -- "long int" is what is printed for ptrdiff_t, though probably not on all platforms.
  , defaulter ["istream_iterator", "ostream_iterator"] 2 (\[_, c] -> t "char_traits<" >> t c >> t '>')
  , defaulter ["istream_iterator", "ostream_iterator"] 1 (const $ t "char")

  , foldr with_subst . (manyTill anyChar $ try $ string " [with ") <*> (sepBy (try $ (,) . (manyTill anyChar $ t " =") <*> cxxExpr) (t ',') <* char ']')
  ]

data RefKind = NoRef | LRef | RRef

instance Show RefKind where
  show NoRef = ""
  show LRef = "&"
  show RRef = "&&"

rrefTo :: RefKind -> RefKind
rrefTo NoRef = RRef
rrefTo LRef = LRef
rrefTo RRef = RRef

stripRef :: String -> (String, RefKind)
stripRef s | Just s' <- stripSuffix "&&" s = (s', RRef)
stripRef s | Just s' <- stripSuffix "&" s = (s', LRef)
stripRef s = (s, NoRef)

subRegex' :: Regex -> String -> String -> String
subRegex' = flip . subRegex

with_subst :: (String, String) -> String -> String
with_subst (k, v) = let (v', vrk) = stripRef v in
    subRegex' (mkRegex $ "\\b" ++ k ++ "\\b") v .
    subRegex' (mkRegex $ "\\b" ++ k ++ "\\s*&") (v' ++ "&") .
    subRegex' (mkRegex $ "\\b" ++ k ++ "\\s*&&") (v' ++ show (rrefTo vrk))

cc1plus e = maybe e' (!!1) $ matchRegex (mkRegex "\\b(error|warning): ([^\n]*)") e'
  where
    h s = either (const s) h $ parse (foldr1 (<|>) (try . replacers) >>> getInput) "" s
    e' = h e
