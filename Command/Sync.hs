{- git-annex command
 -
 - Copyright 2011 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Command.Sync where

import Common.Annex
import Command
import qualified Annex.Branch
import qualified Git

import qualified Data.ByteString.Lazy.Char8 as L

def :: [Command]
def = [command "sync" paramPaths seek "synchronize local repository with remote"]

-- syncing involves several operations, any of which can independantly fail
seek :: [CommandSeek]
seek = map withNothing [commit, pull, push]

commit :: CommandStart
commit = do
	showStart "commit" ""
	next $ next $ do
		showOutput
		-- Commit will fail when the tree is clean, so ignore failure.
		_ <- inRepo $ Git.runBool "commit" [Param "-a", Param "-m", Param "sync"]
		return True

pull :: CommandStart
pull = do
	remote <- defaultRemote
	showStart "pull" remote
	next $ next $ do
		showOutput
		checkRemote remote
		inRepo $ Git.runBool "pull" [Param remote]

push :: CommandStart
push = do
	remote <- defaultRemote
	showStart "push" remote
	next $ next $ do
		Annex.Branch.update
		showOutput
		inRepo $ Git.runBool "push" [Param remote, matchingbranches]
	where
		-- git push may be configured to not push matching
		-- branches; this should ensure it always does.
		matchingbranches = Param ":"

-- the remote defaults to origin when not configured
defaultRemote :: Annex String
defaultRemote = do
	branch <- currentBranch
	fromRepo $ Git.configGet ("branch." ++ branch ++ ".remote") "origin"

currentBranch :: Annex String
currentBranch = last . split "/" . L.unpack . head . L.lines <$>
	inRepo (Git.pipeRead [Param "symbolic-ref", Param "HEAD"])

checkRemote :: String -> Annex ()
checkRemote remote = do
	remoteurl <- fromRepo $
		Git.configGet ("remote." ++ remote ++ ".url") ""
	when (null remoteurl) $ do
		error $ "No url is configured for the remote: " ++ remote