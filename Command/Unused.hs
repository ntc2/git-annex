{- git-annex command
 -
 - Copyright 2010 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Unused where

import Control.Monad (filterM, unless, forM_)
import Control.Monad.State (liftIO)
import qualified Data.Set as S
import Data.Maybe
import System.FilePath
import System.Directory

import Command
import Types
import Content
import Messages
import Locations
import Utility
import LocationLog
import qualified Annex
import qualified GitRepo as Git
import qualified Backend
import qualified Remote

command :: [Command]
command = [repoCommand "unused" paramNothing seek
	"look for unused file content"]

seek :: [CommandSeek]
seek = [withNothing start]

{- Finds unused content in the annex. -} 
start :: CommandStartNothing
start = notBareRepo $ do
	showStart "unused" ""
	return $ Just perform

perform :: CommandPerform
perform = do
	from <- Annex.getState Annex.fromremote
	case from of
		Just name -> do
			r <- Remote.byName name
			checkRemoteUnused r
		_ -> checkUnused
	return $ Just $ return True

checkUnused :: Annex ()
checkUnused = do
	(unused, staletmp) <- unusedKeys
	let unusedlist = number 0 unused
	let staletmplist = number (length unused) staletmp
	let list = unusedlist ++ staletmplist
	writeUnusedFile list
	unless (null unused) $ showLongNote $ unusedMsg unusedlist
	unless (null staletmp) $ showLongNote $ staleTmpMsg staletmplist
	unless (null list) $ showLongNote $ "\n"

checkRemoteUnused :: Remote.Remote Annex -> Annex ()
checkRemoteUnused r = do
	g <- Annex.gitRepo
	showNote $ "checking for unused data on " ++ Remote.name r ++ "..."
	referenced <- getKeysReferenced
	logged <- liftIO $ loggedKeys g
	remotehas <- filterM isthere logged
	let remoteunused = remotehas `exclude` referenced
	let list = number 0 remoteunused
	writeUnusedFile list
	unless (null remoteunused) $ do
		showLongNote $ remoteUnusedMsg r list
		showLongNote $ "\n"
	where
		isthere k = do
			g <- Annex.gitRepo
			us <- liftIO $ keyLocations g k
			return $ uuid `elem` us
		uuid = Remote.uuid r

writeUnusedFile :: [(Int, Key)] -> Annex ()
writeUnusedFile l = do
	g <- Annex.gitRepo
	liftIO $ safeWriteFile (gitAnnexUnusedLog g) $
		unlines $ map (\(n, k) -> show n ++ " " ++ show k) l

table :: [(Int, Key)] -> [String]
table l = ["  NUMBER  KEY"] ++ map cols l
	where
		cols (n,k) = "  " ++ pad 6 (show n) ++ "  " ++ show k
		pad n s = s ++ replicate (n - length s) ' '

number :: Int -> [a] -> [(Int, a)]
number _ [] = []
number n (x:xs) = (n+1, x):(number (n+1) xs)

staleTmpMsg :: [(Int, Key)] -> String
staleTmpMsg t = unlines $ 
	["Some partially transferred data exists in temporary files:"]
	++ table t ++ [dropMsg Nothing]
		
unusedMsg :: [(Int, Key)] -> String
unusedMsg u = unusedMsg' u
	["Some annexed data is no longer used by any files in the repository:"]
	[dropMsg Nothing]

remoteUnusedMsg :: Remote.Remote Annex -> [(Int, Key)] -> String
remoteUnusedMsg r u = unusedMsg' u
	["Some annexed data on " ++ name ++ 
	 " is not used by any files in this repository."]
	[dropMsg $ Just r,
	 "Please be cautious -- are you sure that the remote repository",
	 "does not use this data?"]
	where
		name = Remote.name r 

unusedMsg' :: [(Int, Key)] -> [String] -> [String] -> String
unusedMsg' u header trailer = unlines $
	header ++
	table u ++
	["(To see where data was previously used, try: git log --stat -S'KEY')"] ++
	trailer

dropMsg :: Maybe (Remote.Remote Annex) -> String
dropMsg Nothing = dropMsg' ""
dropMsg (Just r) = dropMsg' $ " --from " ++ Remote.name r
dropMsg' :: String -> String
dropMsg' s = "(To remove unwanted data: git-annex dropunused" ++ s ++ " NUMBER)"

{- Finds keys whose content is present, but that do not seem to be used
 - by any files in the git repo, or that are only present as tmp files. -}
unusedKeys :: Annex ([Key], [Key])
unusedKeys = do
	g <- Annex.gitRepo
	
	fast <- Annex.getState Annex.fast
	if fast
		then do
			showNote "fast mode enabled; only finding temporary files"
			tmps <- tmpKeys
			return ([], tmps)
		else do
			showNote "checking for unused data..."
			present <- getKeysPresent
			referenced <- getKeysReferenced
			tmps <- tmpKeys
	
			let unused = present `exclude` referenced
			let staletmp = tmps `exclude` present
			let duptmp = tmps `exclude` staletmp

			-- Tmp files that are dups of content already present
			-- can simply be removed.
			liftIO $ forM_ duptmp $ \t -> removeFile $
				gitAnnexTmpLocation g t

			return (unused, staletmp)

{- Finds items in the first, smaller list, that are not
 - present in the second, larger list.
 - 
 - Constructing a single set, of the list that tends to be
 - smaller, appears more efficient in both memory and CPU
 - than constructing and taking the S.difference of two sets. -}
exclude :: Ord a => [a] -> [a] -> [a]
exclude [] _ = [] -- optimisation
exclude smaller larger = S.toList $ remove larger $ S.fromList smaller
	where
		remove a b = foldl (flip S.delete) b a

{- List of keys referenced by symlinks in the git repo. -}
getKeysReferenced :: Annex [Key]
getKeysReferenced = do
	g <- Annex.gitRepo
	files <- liftIO $ Git.inRepo g [Git.workTree g]
	keypairs <- mapM Backend.lookupFile files
	return $ map fst $ catMaybes keypairs

{- List of keys that have temp files in the git repo. -}
tmpKeys :: Annex [Key]
tmpKeys = do
	g <- Annex.gitRepo
	let tmp = gitAnnexTmpDir g
	exists <- liftIO $ doesDirectoryExist tmp
	if (not exists)
		then return []
		else do
			contents <- liftIO $ getDirectoryContents tmp
			files <- liftIO $ filterM doesFileExist $
				map (tmp </>) contents
			return $ catMaybes $ map (fileKey . takeFileName) files