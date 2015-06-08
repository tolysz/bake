{-# LANGUAGE RecordWildCards, TupleSections, ViewPatterns, RankNTypes, TypeOperators, TypeFamilies, ExistentialQuantification #-}
{-# LANGUAGE GeneralizedNewtypeDeriving, FlexibleInstances, FlexibleContexts #-}

module General.Database(
    Pred, (%==), nullP,
    Upd(..),
    Table, table, Column, column, rowid, norowid,
    sqlInsert, sqlUpdate, sqlSelect, sqlDelete, sqlCreateNotExists,
    ) where

import Data.List.Extra
import Data.String
import Database.SQLite.Simple hiding ((:=))
import Database.SQLite.Simple.FromField
import Database.SQLite.Simple.ToField


type family Uncolumns cs where
    Uncolumns () = ()
    Uncolumns (Column a) = Only a
    Uncolumns (Only (Column a)) = Only a
    Uncolumns (Column a, Column b) = (a, b)
    Uncolumns (Column a, Column b, Column c) = (a, b, c)
    Uncolumns (Column a, Column b, Column c, Column d) = (a, b, c, d)
    Uncolumns (Column a, Column b, Column c, Column d, Column e) = (a, b, c, d, e)
    Uncolumns (Column a, Column b, Column c, Column d, Column e, Column f) = (a, b, c, d, e, f)
    Uncolumns (Column a, Column b, Column c, Column d, Column e, Column f, Column g) = (a, b, c, d, e, f, g)
    Uncolumns (Column a, Column b, Column c, Column d, Column e, Column f, Column g, Column h) = (a, b, c, d, e, f, g, h)

data Table rowid cs = Table {tblName :: String, tblCols :: [Column_]}

data Column c = Column {colTable :: String, colName :: String, colSqlType :: String}

type Column_ = Column ()

column_ :: Column c -> Column_
column_ Column{..} = Column{..}

class Columns cs where columns :: cs -> [Column_]
instance Columns () where columns () = []
instance Columns (Column c1) where columns c1 = [column_ c1]
instance Columns (Only (Column c1)) where columns (Only c1) = [column_ c1]
instance Columns (Column c1, Column c2) where columns (c1, c2) = [column_ c1, column_ c2]
instance Columns (Column c1, Column c2, Column c3) where columns (c1, c2, c3) = [column_ c1, column_ c2, column_ c3]
instance Columns (Column c1, Column c2, Column c3, Column c4) where columns (c1, c2, c3, c4) = [column_ c1, column_ c2, column_ c3, column_ c4]

table :: Columns cs => String -> Column rowid -> cs -> Table rowid (Uncolumns cs)
table name _ cs = Table name $ map column_ $ columns cs

column :: Table rowid cs -> String -> String -> Column c
column tbl row typ = Column (tblName tbl) row typ

rowid :: Table rowid cs -> Column rowid
rowid tbl = Column (tblName tbl) "rowid" ""

norowid :: Column ()
norowid = Column "" "" ""

sqlInsert :: (ToRow cs, FromField rowid) => Connection -> Table rowid cs -> cs -> IO rowid
sqlInsert conn tbl val = do
    let vs = toRow val
    let str = "INSERT INTO " ++ tblName tbl ++ " VALUES (" ++ intercalate "," (replicate (length vs) "?") ++ ")"
    execute conn (fromString str) vs
    [Only row] <- query_ conn (fromString "SELECT last_insert_rowid()")
    return row


sqlUpdate :: Connection -> [Upd] -> [Pred] -> IO ()
sqlUpdate conn upd pred = do
    let (updCs, updVs) = unzip $ map unupdate upd
    let (prdStr, prdCs, prdVs) = unpred pred
    let tbl = nubOrd $ map colTable $ updCs ++ prdCs
    case tbl of
        _ | null upd -> fail "Must update at least one column"
        [t] -> do
            let str = "UPDATE " ++ t ++ " SET " ++ intercalate ", " (map ((++ "=?") . colTable) updCs) ++ " WHERE " ++ prdStr
            execute conn (fromString str) (updVs ++ prdVs)
        _ -> fail "Must update all in the same column"


sqlDelete :: Connection -> Table rowid cs -> [Pred] -> IO ()
sqlDelete conn tbl pred = do
    let (prdStr, prdCs, prdVs) = unpred pred
    case nubOrd $ tblName tbl : map colName prdCs of
        [t] -> do
            let str = "DELETE FROM " ++ t ++ " WHERE " ++ prdStr
            execute conn (fromString str) prdVs
        _ -> fail "Must delete from only one column"


sqlSelect :: (FromRow (Uncolumns cs), Columns cs) => Connection -> cs -> [Pred] -> IO [Uncolumns cs]
sqlSelect conn cols pred = do
    let outCs = columns cols
    let (prdStr, prdCs, prdVs) = unpred pred
    let str = "SELECT " ++ intercalate ", " [colTable ++ "." ++ colName | Column{..} <- outCs] ++ " " ++
              "FROM " ++ intercalate ", " (nubOrd $ map colTable $ outCs ++ prdCs) ++ " WHERE " ++ prdStr
    query conn (fromString str) prdVs


sqlCreateNotExists :: Connection -> Table rowid cs -> IO ()
sqlCreateNotExists conn Table{..} = do
    let fields = intercalate ", " [colName ++ " " ++ colSqlType | Column{..} <- tblCols]
    let str = "CREATE TABLE IF NOT EXISTS " ++ tblName ++ "(" ++ fields ++ ")"
    execute_ conn $ fromString str


data Upd = forall a . ToField a => Column a := a

unupdate :: Upd -> (Column_, SQLData)
unupdate (c := v) = (column_ c, toField v)

data Pred
    = NullP Column_
    | PEq Column_ SQLData
    | AndP [Pred]

nullP :: Column (Maybe c) -> Pred
nullP c = NullP (column_ c)

(%==) :: ToField c => Column c -> c -> Pred
(%==) c v = PEq (column_ c) (toField v)

unpred :: [Pred] -> (String, [Column_], [SQLData])
unpred = f . AndP
    where
        g Column{..} = colTable ++ "." ++ colName

        f (NullP c) = (g c ++ " IS NULL", [c], [])
        f (PEq c v) = (g c ++ " IS ?", [c], [v])
        f (AndP []) = ("NULL IS NULL", [], [])
        f (AndP [x]) = f x
        f (AndP xs) = (intercalate " AND " ["(" ++ s ++ ")" | s <- ss], concat cs, concat vs)
            where (ss,cs,vs) = unzip3 $ map f xs

instance FromField () where
    fromField _ = return ()