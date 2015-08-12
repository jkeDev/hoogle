{-# LANGUAGE ViewPatterns, TupleSections, RecordWildCards, ScopedTypeVariables, DeriveDataTypeable, PatternGuards, GADTs #-}

module Output.Tags(Tags, writeTags, readTags, listTags, filterTags, searchTags) where

import Data.List.Extra
import Data.Tuple.Extra
import Data.Maybe
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Vector.Storable as V
import qualified Data.ByteString.Char8 as BS
import Data.Word

import Input.Item
import Query
import General.Util
import General.Store

-- matches (a,b) if i >= a && i <= b

data PackageNames a where PackageNames :: PackageNames BS.ByteString deriving Typeable
    -- list of packages, sorted by name, lowercase, interspersed with \0
-- FIXME: PackageIds should be sorted by popularity

data PackageIds a where PackageIds :: PackageIds (V.Vector (TargetId, TargetId)) deriving Typeable
    -- for each index in PackageNames, the first is the module item, any in the bounds are in that package

data ModuleNames a where ModuleNames :: ModuleNames BS.ByteString deriving Typeable
    -- list of modules, sorted by popularity, not unique, lowercase, interspersed with \0

data ModuleIds a where ModuleIds :: ModuleIds (V.Vector (TargetId, TargetId)) deriving Typeable
    -- for each index in ModuleNames, the first is the module item, any in the bounds are in that module

data CategoryNames a where CategoryNames :: CategoryNames BS.ByteString deriving Typeable
    -- list of categories, sorted by name, interspersed with \0

data CategoryOffsets a where CategoryOffsets :: CategoryOffsets (V.Vector Word32) deriving Typeable
    -- for each index in CategoryNames, the first is the position I start, use +1 to find one after I end

data CategoryIds a where CategoryIds :: CategoryIds (V.Vector (TargetId, TargetId)) deriving Typeable
    -- a range of items containing a category, first item is a package

data CompletionNames a where CompletionNames :: CompletionNames BS.ByteString deriving Typeable
    -- a list of things to complete to, interspersed with \0


data Tags = Tags
    {packageNames :: BS.ByteString -- sorted
    ,categoryNames :: BS.ByteString -- sorted
    ,packageIds :: V.Vector (TargetId, TargetId)
    ,categoryOffsets :: V.Vector Word32 -- position I start, use +1 to find one after I end
    ,categoryIds :: V.Vector (TargetId, TargetId)
    ,moduleNames :: BS.ByteString -- not sorted
    ,moduleIds :: V.Vector (TargetId, TargetId)
    ,completionNames :: BS.ByteString -- things I want to complete to
    } deriving Typeable

join0 :: [String] -> BS.ByteString
join0 = BS.pack . intercalate "\0"

split0 :: BS.ByteString -> [BS.ByteString]
split0 = BS.split '\0'

writeTags :: StoreWrite -> (String -> Bool) -> (String -> [(String,String)]) -> [(Maybe TargetId, Item)] -> IO ()
writeTags store keep extra xs = do
    let splitPkg = splitIPackage xs
    let packagesRaw = addRange splitPkg
    let packages = sortOn (lower . fst) packagesRaw
    let categories = map (first snd . second reverse) $ Map.toList $ Map.fromListWith (++)
            [(((weightTag ex, both lower ex), joinPair ":" ex),[rng]) | (p,rng) <- packagesRaw, ex <- extra p]

    storeWrite store PackageNames $ join0 $ map fst packages
    storeWrite store CategoryNames $ join0 $ map fst categories
    storeWrite store PackageIds $ V.fromList $ map snd packages
    storeWrite store CategoryOffsets $ V.fromList $ scanl (+) (0 :: Word32) $ map (genericLength . snd) categories
    storeWrite store CategoryIds $ V.fromList $ concatMap snd categories

    let modules = addRange $ concatMap (splitIModule . snd) splitPkg
    storeWrite store ModuleNames $ join0 $ map (lower . fst) modules
    storeWrite store ModuleIds $ V.fromList $ map snd modules

    storeWrite store CompletionNames $ join0 $
        takeWhile ("set:" `isPrefixOf`) (map fst categories) ++
        map ("package:"++) (filter keep $ map fst packages) ++
        map (joinPair ":") (sortOn (weightTag &&& both lower) $ nubOrd [ex | (p,_) <- packages, keep p, ex <- extra p])
    where
        addRange :: [(String, [(Maybe TargetId,a)])] -> [(String, (TargetId, TargetId))]
        addRange xs = [(a, (minimum is, maximum is)) | (a,b) <- xs, let is = mapMaybe fst b, a /= "", is /= []]

        weightTag ("set",x) = fromMaybe 0.9 $ lookup x [("stackage",0.0),("haskell-platform",0.1)]
        weightTag ("package",x) = 1
        weightTag ("category",x) = 2
        weightTag ("license",x) = 3
        weightTag _ = 4


readTags :: StoreRead -> Tags
readTags store = Tags
    (storeRead store PackageNames) (storeRead store CategoryNames) (storeRead store PackageIds)
    (storeRead store CategoryOffsets) (storeRead store CategoryIds) (storeRead store ModuleNames) (storeRead store ModuleIds)
    (storeRead store CompletionNames)


listTags :: Tags -> [String]
listTags Tags{..} = map BS.unpack $ split0 completionNames

lookupTag :: Tags -> (String, String) -> [(TargetId,TargetId)]
lookupTag Tags{..} ("is",'p':xs) | xs `isPrefixOf` "ackage" = map (dupe . fst) $ V.toList packageIds
lookupTag Tags{..} ("is",'m':xs) | xs `isPrefixOf` "odule" = map (dupe . fst) $ V.toList moduleIds
lookupTag Tags{..} ("package",x) = map (packageIds V.!) $ findIndices (== BS.pack x) $ split0 packageNames
lookupTag Tags{..} ("module",lower -> x) = map (moduleIds V.!) $ findIndices f $ split0 moduleNames
    where
        f | Just x <- stripPrefix "." x, Just x <- stripSuffix "." x = (==) (BS.pack x)
          | Just x <- stripPrefix "." x = BS.isPrefixOf $ BS.pack x
          | otherwise = let y = BS.pack x; y2 = BS.pack $ ('.':x)
                        in \v -> y `BS.isPrefixOf` v || y2 `BS.isInfixOf` v
lookupTag Tags{..} x = concat
    [ V.toList $ V.take (fromIntegral $ end - start) $ V.drop (fromIntegral start) categoryIds
    | i <- findIndices (== BS.pack (joinPair ":" x)) $ split0 categoryNames
    , let start = categoryOffsets V.! i, let end = categoryOffsets V.! (i + 1)
    ]

filterTags :: Tags -> [Query] -> (TargetId -> Bool)
filterTags ts qs = let fs = map (filterTags2 ts . snd) $ groupSort $ map (scopeCategory &&& id) $ filter isQueryScope qs in \i -> all ($ i) fs

filterTags2 ts qs = \i -> not (negq i) && (null pos || posq i)
    where (posq,negq) = both inRanges (pos,neg)
          (pos, neg) = both (map snd) $ partition fst $ concatMap f qs
          f (QueryScope sense cat val) = map (sense,) $ lookupTag ts (cat,val)

searchTags :: Tags -> [Query] -> [TargetId]
searchTags ts [] = map fst $ V.toList $ packageIds ts
searchTags ts qs = if null xs then x else filter (`Set.member` foldl1' Set.intersection (map Set.fromList xs)) x
    where x:xs = [map fst $ lookupTag ts (cat,val) | QueryScope True cat val <- qs]
