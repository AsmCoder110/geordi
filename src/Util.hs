module Util where

import qualified System.Posix.IO
import qualified GHC.Read
import qualified Data.Monoid
import qualified Prelude
import qualified Data.Sequence as Seq
import qualified Text.ParserCombinators.Parsec as PS
import qualified Text.ParserCombinators.Parsec.Error as PSE

import Data.Maybe (listToMaybe, mapMaybe)
import Data.Monoid (Monoid(..))
import Data.List (sortBy, minimumBy, isPrefixOf, tails, all)
import Data.Char (isSpace, isAlphaNum, toLower, toUpper)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Sequence (Seq, ViewL(..), (<|))
import Data.Function (on)
import Control.Exception (catch, bracket, evaluate)
import Control.Monad (liftM2)
import Control.Monad.Fix (fix)
import Control.Monad.State (MonadState, modify, StateT(..))
import Control.Monad.Instances ()
import Control.Parallel.Strategies (NFData, rnf)
import Control.Arrow (first, second)
import System.Posix.Types (Fd(..))
import System.Posix.Time (epochTime)
import System.IO (Handle, hClose)
import Sys (sleep)

import Prelude hiding (catch, (.), (!!))

full_evaluate :: NFData a => a -> IO a
full_evaluate x = do () <- evaluate (rnf x); return x
  -- evaluate only evaluates up to WHNF.

readFileNow :: FilePath -> IO String
readFileNow f = readFile f >>= full_evaluate
  -- Useful when, for example, one needs to read from a file before performing a chroot after which the file is no longer accessible.

(.) :: Functor f => (a -> b) -> f a -> f b
(.) = fmap

noThrow :: IO () -> IO ()
noThrow x = x `catch` const (return ())

class IOResource a where dealloc :: a -> IO ()

withResource :: IOResource a => IO a -> (a -> IO b) -> IO b
withResource x = bracket x $ noThrow . dealloc

instance IOResource Handle where dealloc = hClose
instance IOResource Fd where dealloc = System.Posix.IO.closeFd

instance (IOResource x, IOResource y) => IOResource (x, y) where
  dealloc (x, y) = noThrow (dealloc x) >> dealloc y

kibi, mebi :: Integral a => a
kibi = 1024
mebi = kibi * kibi

readTypedFile :: Read a => FilePath -> IO a
readTypedFile f = either (const $ fail $ "parsing \"" ++ f ++ "\"") return =<< GHC.Read.readEither . readFile f

stripPrefix :: Eq a => [a] -> [a] -> Maybe [a]
stripPrefix [] ys = Just ys
stripPrefix (x:xs) (y:ys) | x == y = stripPrefix xs ys
stripPrefix _ _ = Nothing
  -- ExtDep: GHC 6.8.2 has this in Data.List.

stripSuffix :: String -> String -> Maybe String
stripSuffix x y = reverse . stripPrefix (reverse x) (reverse y)

takeBack :: Int -> [a] -> [a]
takeBack n = reverse . take n . reverse

wordsWithWhite :: String -> [String]
wordsWithWhite "" = []
wordsWithWhite s = (a ++ w) : wordsWithWhite s''
  where (a,s') = break isSpace s; (w,s'') = span isSpace s'

findMaybe :: (a -> Maybe b) -> [a] -> Maybe b
findMaybe f l = listToMaybe $ mapMaybe f l

maybeM :: Monad m => Maybe a -> (a -> m ()) -> m ()
maybeM m a = maybe (return ()) a m

msapp :: (Data.Monoid.Monoid a, MonadState a m) => a -> m ()
msapp = modify . flip Data.Monoid.mappend

(.||.), (.&&.) :: (a -> Bool) -> (a -> Bool) -> (a -> Bool)
f .||. g = \x -> f x || g x
f .&&. g = \x -> f x && g x
  -- In applicative notation, these could be written: f .||. g = [[ f || g ]].

sortByProperty :: Ord b => (a -> b) -> [a] -> [a]
sortByProperty f = sortBy $ \x y -> compare (f x) (f y)

strip :: String -> String
strip = dropWhile isSpace . reverse . dropWhile isSpace . reverse

orElse :: Maybe a -> a -> a
orElse (Just x) _ = x
orElse Nothing x = x

putNewLn :: IO ()
putNewLn = putStrLn ""

(<<) :: Monad m => m a -> m b -> m a
x << y = x >>= \z -> y >> return z

(>+>) :: (Monad m, Monoid n) => m n -> m n -> m n
(>+>) = liftM2 mappend

caselessStringEq :: String -> String -> Bool
caselessStringEq a b = (toLower . a) == (toLower . b)

elemBy :: (a -> a -> Bool) -> a -> [a] -> Bool
elemBy f x = or . (f x .)

none :: (a -> Bool) -> [a] -> Bool
none p = all (not . p)

class Queue q e | q -> e where
  qpush :: e -> q -> q
  qpop :: q -> Maybe (e, q)

instance Queue (Seq e) e where
  qpush = (<|)
  qpop q = case (Seq.viewl q) of
    Seq.EmptyL -> Nothing
    e :< q' -> Just (e, q')

qPopWhile :: Queue q e => (e -> Bool) -> q -> q
qPopWhile p q | Just (e, q') <- qpop q, p e = qPopWhile p q'
qPopWhile _ q = q

rate_limiter :: Int -> Int -> IO (IO ())
rate_limiter bound window = do
  r <- newIORef Seq.empty
  return $ fix $ \loop -> do
    now <- epochTime
    hist <- discard_until (now - fromIntegral window) . readIORef r
    if Seq.length hist < bound
      then writeIORef r (qpush now hist)
      else writeIORef r hist >> sleep 1 >> loop
 where discard_until t = qPopWhile (< t)
  -- Given |rl <- rate_limiter b w|, |rl| actions will sleep as required to make sure no more than b actions pass during any w second time window.

parsep :: Char
parsep = '\x2029' -- U+2029 PARAGRAPH SEPARATOR

describe_new_output :: Maybe String -> String -> String
describe_new_output Nothing new = new
describe_new_output (Just prev) new =
  if prev /= new || length new <= 20 then new
  else if "error:" `isPrefixOf` new then "Same error."
  else if "warning:" `isPrefixOf` new then "Same warning."
  else "No change in output."

maybeLast :: [a] -> Maybe a
maybeLast [] = Nothing
maybeLast [x] = Just x
maybeLast (_:t) = maybeLast t

replaceInfixM :: Eq a => [a] -> [a] -> [a] -> Maybe [a]
replaceInfixM what with l = (\(pre, post) -> pre ++ with ++ post) . stripInfix what l

replaceInfix :: Eq a => [a] -> [a] -> [a] -> [a]
replaceInfix what with l = maybe l id (replaceInfixM what with l)

replaceAllInfix :: Eq a => [a] -> [a] -> [a] -> [a]
replaceAllInfix what with l | Just r <- stripPrefix what l = with ++ replaceAllInfix what with r
replaceAllInfix what with (h:t) = h : replaceAllInfix what with t
replaceAllInfix _ _ [] = []

stripInfix :: Eq a => [a] -> [a] -> Maybe ([a], [a])
stripInfix p s | Just r <- stripPrefix p s = Just ([], r)
stripInfix p (h:t) = first (h:) . stripInfix p t
stripInfix _ _  = Nothing

readState :: Monad y => StateT x y x
readState = StateT $ \x -> return (x, x)

mapState' :: Monad y => (x -> x) -> StateT x y ()
mapState' f = StateT $ \s -> return ((), f s)

many1Till' :: PS.GenParser tok st a -> PS.GenParser tok st end -> PS.GenParser tok st ([a], end)
many1Till' p end = p >>= \v -> first (v:) . scan
  where scan = (PS.<|>) ((\r -> ([], r)) . end) (do { x <- p; (xs, e) <- scan; return (x:xs, e) })

isUnexpMsg :: PSE.Message -> Bool
isUnexpMsg (PSE.SysUnExpect _) = True
isUnexpMsg (PSE.UnExpect _) = True
isUnexpMsg _ = False

showParseError :: Bool -> PSE.ParseError -> String
showParseError unexpecteds_only e =
  "column " ++ show (PS.sourceColumn $ PS.errorPos e) ++ ": " ++
  (concatMap (++ ". ") $ filter (not . all isSpace) $ lines $ PSE.showErrorMessages "or" "unknown parse error" "expected:" "unexpected" "end of command" $ (if unexpecteds_only then filter isUnexpMsg else id) $ PSE.errorMessages e)

either_part :: [Either a b] -> ([a], [b])
either_part [] = ([], [])
either_part (h : t) = either (first . (:)) (second . (:)) h (either_part t)

(!!) :: [a] -> Int -> a
l !! i | i < 0 = (Prelude.!!) (reverse l) (-i - 1)
l !! i = (Prelude.!!) l i

data NElist a = NElist a [a] -- non-empty list

instance Convert (NElist a) [a] where convert (NElist x l) = x : l

instance Functor NElist where fmap f (NElist x l) = NElist (f x) (f . l)

unne :: NElist a -> [a]
unne (NElist x l) = x : l

sepBy1' :: PS.CharParser st a -> PS.CharParser st b -> PS.CharParser st (NElist a)
sepBy1' x y = (\(h:t) -> NElist h t) . PS.sepBy1 x y

class Convert a b where convert :: a -> b

instance (Convert x x', Convert y y') => Convert (Either x y) (Either x' y') where
  convert = either (Left . convert) (Right . convert)

erase_indexed :: [Int] -> [a] -> [a]
erase_indexed i l = f 0 l
 where
  f _ [] = []
  f n (_:t) | n `elem` i || (n - length l) `elem` i = f (n + 1) t
  f n (h:t) = h : f (n + 1) t

count :: (a -> Bool) -> [a] -> Int
count p = length . filter p

type Cost = Float
data Op a = SkipOp a | InsertOp a | EraseOp a | ReplaceOp a a
data OpsWithCost a = OpsWithCost [Op a] Cost

instance Monoid (OpsWithCost a) where
  mempty = OpsWithCost [] 0
  mappend (OpsWithCost l c) (OpsWithCost l' c') = OpsWithCost (l ++ l') (c + c')

ops_cost :: OpsWithCost a -> Cost
ops_cost (OpsWithCost _ c) = c

opsWithCost :: (Op a -> Cost) -> [Op a] -> OpsWithCost a
opsWithCost co ops = OpsWithCost ops (sum $ map co ops)

addOp :: (Op a -> Cost) -> Op a -> OpsWithCost a -> OpsWithCost a
addOp co op (OpsWithCost ops c) = OpsWithCost (op : ops) (c + co op)

is_insertOp :: Op a -> Bool
is_insertOp (InsertOp _) = True
is_insertOp _ = False

approx_match :: Eq a => (Op a -> Cost) -> [a] -> [a] -> [(OpsWithCost a, Int, Int)]
approx_match co pattern text =
  sortBy (\(x,_,_) (y,_,_) -> compare (ops_cost x) (ops_cost y)) $
    zipWith (\owc@(OpsWithCost o _) z -> (owc, z, count (not . is_insertOp) o)) r [0..]
 where
  r = foldl f (replicate (length text + 1) mempty) (tail $ reverse $ tails pattern)
    -- r!!n contains the cheapest cost and corresponding replace-length of replacing the pattern at position n in the text.
    -- the nth intermediate list in r's fold stores at position p the cheapest cost and corresponding replace-length of matching the the last n elements of the pattern at position p in the text.
  f v pattern_tail = foldl g [opsWithCost co (map InsertOp pattern_tail)] [length text, length text - 1 .. 1]
   where
    c = head pattern_tail
    g w m = minimumBy (compare `on` ops_cost) candidates : w
     where
      d = text !! (m - 1)
      candidates =
        [ addOp co (if c == d then SkipOp c else ReplaceOp c d) (v!!m)
        , addOp co (InsertOp c) (v!!(m - 1))
        , addOp co (EraseOp d) (head w)
        ]

levenshtein :: String -> String -> Float
levenshtein s t = d !! length s !! length t
  where
    d = [[ distance m n | n <- [0 .. length t]] | m <- [0 .. length s]]
    distance :: Int -> Int -> Float
    distance i 0 = fromIntegral i
    distance 0 j = fromIntegral j
    distance i j = minimum [d!!(i-1)!!j+1, d!!i!!(j-1)+1, d!!(i-1)!!(j-1) + (if s!!(i-1)==t!!(j-1) then -0.4 else 1)]

prefixError :: String -> Either String a -> Either String a
prefixError _ (Right x) = Right x
prefixError s (Left s') = Left (s ++ s')

length_ge :: Int -> [a] -> Bool
length_ge 0 _ = True
length_ge (n+1) (_:t) = length_ge n t
length_ge _ _ = False
  -- length_ge is lazy in its list argument, which   length l >= n   is not.

isIdChar :: Char -> Bool
isIdChar = isAlphaNum .||. (== '_')

commas_and :: [String] -> String
commas_and [] = ""
commas_and [x] = x
commas_and [x, y] = x ++ ", and " ++ y
commas_and (x : y) = x ++ ", " ++ commas_and y

capitalize :: String -> String
capitalize (h:t) = toUpper h : t
capitalize [] = []

take_atleast :: Int -> (a -> Int) -> [a] -> [a]
take_atleast _ _ [] = []
take_atleast n _ _ | n <= 0 = []
take_atleast n m (h:t) = h : take_atleast (n - m h) m t
