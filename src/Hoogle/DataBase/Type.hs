
module Hoogle.DataBase.Type(
    DataBase(..), ItemId, createDataBase, loadDataBase,
    searchName, searchType
    ) where

import Data.IORef
import Data.Maybe
import Data.List
import System.IO
import Control.Monad

import Hoogle.DataBase.Alias
import Hoogle.DataBase.Kinds
import Hoogle.DataBase.Instances
import Hoogle.DataBase.Items
import Hoogle.DataBase.Modules
import Hoogle.DataBase.Texts
import Hoogle.DataBase.Types

import Hoogle.TextBase.All
import Hoogle.TypeSig.All

import General.All


hooVersion = 1 :: Int
hooString = "HOOG"


type Pending x = IORef (Either Int x)
type ItemId = Int


data DataBase = DataBase {
                    handle  :: Handle,
                    package :: String,
                    version :: String,
                    
                    -- the static and cached information
                    modules :: Pending Modules, -- Prelude, Data.Map etc.
                    kinds :: Pending Kinds, -- [] 1, Ord 1
                    alias :: Pending Alias, -- type String = [Char]
                    instances :: Pending Instances, -- instance Ord Bool
                    
                    -- the dynamic information
                    nameSearchPos, typeSearchPos :: Int
                }


-- [] is success
-- (_:_) are the error messages
createDataBase :: TextBase -> FilePath -> IO [Response]
createDataBase tb file = do
    hndl <- openBinaryFile file WriteMode
    hPutStr hndl hooString
    hPutInt hndl 0 -- 0 for binary notice
    hPutInt hndl hooVersion -- verson number

    (as,tb) <- return $ partition (isItemAttribute . itemRest) tb
    let attribs = [(a,b) | ItemAttribute a b <- map itemRest as]

    hPutString hndl "package"
    hPutString hndl "1.0"

    tablePos <- hGetPosn hndl
    replicateM_ 6 $ hPutInt hndl 0

    posModule <- hGetPos hndl
    tb2 <- saveModules hndl tb
    tb3 <- saveItems hndl tb2
    
    (pos, err) <-
        mapAndUnzipM (\x -> do y <- hGetPos hndl ; z <- x ; return (y,z))
            [saveKinds hndl tb
            ,saveAlias hndl tb
            ,saveInstances hndl tb
            ,saveTexts hndl tb3
            ,saveTypes hndl tb3
            ]
    
    hSetPosn tablePos
    mapM_ (hPutInt hndl) (posModule:pos)
    hClose hndl
    
    return $ concat err


loadDataBase :: FilePath -> IO (Maybe DataBase)
loadDataBase file = do
    hndl <- openBinaryFile file ReadMode
    str <- hGetStr hndl (length hooString)
    zero <- hGetInt hndl
    ver <- hGetInt hndl
    
    if str /= hooString || zero /= 0 || ver /= hooVersion then return Nothing else do
        
        package <- hGetString hndl
        version <- hGetString hndl
        
        [a,b,c,d,e,f] <- replicateM 6 $ hGetInt hndl
        a2 <- gen a; b2 <- gen b; c2 <- gen c; d2 <- gen d
        
        return $ Just $ DataBase hndl package version a2 b2 c2 d2 e f
    where
        gen :: Int -> IO (IORef (Either Int a))
        gen i = newIORef (Left i)


-- ensure methods
ensureModules :: DataBase -> IO Modules
ensureModules database = do
    x <- readIORef (modules database)
    case x of
        Right y -> return y
        Left n -> do
            let hndl = handle database
            hSetPos hndl n
            res <- loadModules hndl
            writeIORef (modules database) (Right res)
            return res
        



-- forward methods
searchName :: DataBase -> [String] -> IO [Result DataBase]
searchName database query = do
    let hndl = handle database
    res <- mapM (\x -> hSetPos hndl (nameSearchPos database) >> searchTexts hndl x) query
    if length query == 1
        then mapM f $ head res
        else mergeResults database query res
    where
        f = liftM (fixupTextMatch (head query)) . loadResult . setResultDataBase database


mergeResults :: DataBase -> [String] -> [[Result ()]] -> IO [Result DataBase]
mergeResults database query xs = merge (map (sortBy cmp) xs)
    where
        getId = fromJust . itemId . itemResult
        cmp a b = getId a `compare` getId b

        merge xs | null tops = return []
                 | otherwise = do
                 result <- loadResult $ setResultDataBase database $ snd $ head nows
                 let tm = computeTextMatch
                                    (fromJust $ itemName $ itemResult result)
                                    [(q, head $ textMatch $ fromJust $ textResult x) | (q,x) <- nows]
                     result2 = result{textResult = Just tm}
                 ans <- merge rest
                 return (result2:ans)
            where
                nows = [(q,x) | (q,x:_) <- zip query xs, getId x == now]
                rest = [if not (null x) && getId (head x) == now then tail x else x | x <- xs]
                now = minimum $ map getId tops
                tops = [head x | x <- xs, not $ null x]


-- fill in the global methods of TextMatch
-- given a list of TextMatchOne
fixupTextMatch :: String -> Result a -> Result a
fixupTextMatch query result = result{textResult = Just newTextResult}
    where
        name = fromJust $ itemName $ itemResult result
        matches = textMatch $ fromJust $ textResult result
        newTextResult = computeTextMatch name [(query,head matches)]


-- each item in the same set must have the same
-- type diff matching (for faster sorting stage)
searchType :: DataBase -> TypeSig -> IO [[Result DataBase]]
searchType database typesig = do
    let hndl = handle database
    hSetPos hndl (typeSearchPos database)
    res <- searchTypes hndl typesig
    mapM (mapM (loadResult . setResultDataBase database)) res


loadResult :: Result DataBase -> IO (Result DataBase)
loadResult res = loadResultItem res >>= loadResultModule


loadResultItem :: Result DataBase -> IO (Result DataBase)
loadResultItem result@Result{itemResult=x} =
    do
        hSetPos hndl (fromJust $ itemId x)
        res <- liftM (setItemDataBase database) $ loadItem hndl
        return $ result{itemResult=res{itemId = itemId x}}
    where
        database = itemExtra x
        hndl = handle database


loadResultModule :: Result DataBase -> IO (Result DataBase)
loadResultModule result@Result{itemResult=x} =
    do
        mods <- ensureModules database
        return $ result{itemResult = x{itemMod = f mods (itemMod x)}}
    where
        database = itemExtra x
        hndl = handle database
        
        f mods (Just (ModuleId n)) = Just (Module (getModuleFromId mods n))
        f mods x = x


setItemDataBase :: DataBase -> Item a -> Item DataBase
setItemDataBase x (Item a b c d _ f) = Item a b c d x f

setResultDataBase :: DataBase -> Result a -> Result DataBase
setResultDataBase x (Result a b c) = Result a b (setItemDataBase x c)
