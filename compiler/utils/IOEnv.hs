{-# OPTIONS -w #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and fix
-- any warnings in the module. See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#Warnings
-- for details

--
-- (c) The University of Glasgow 2002-2006
--
-- The IO Monad with an environment
--

module IOEnv (
        IOEnv, -- Instance of Monad

        -- Monad utilities
        module MonadUtils,

        -- Errors
        failM, failWithM,

        -- Getting at the environment
        getEnv, setEnv, updEnv,

        runIOEnv, unsafeInterleaveM,
        tryM, tryAllM, tryMostM, fixM,

        -- I/O operations
        IORef, newMutVar, readMutVar, writeMutVar, updMutVar
  ) where
#include "HsVersions.h"

import Panic            ( try, tryUser, tryMost, Exception(..) )

import Data.IORef       ( IORef, newIORef, readIORef, writeIORef, modifyIORef )
import System.IO.Unsafe ( unsafeInterleaveIO )
import System.IO        ( fixIO )
import MonadUtils

----------------------------------------------------------------------
-- Defining the monad type
----------------------------------------------------------------------


newtype IOEnv env a = IOEnv (env -> IO a)
unIOEnv (IOEnv m) = m

instance Monad (IOEnv m) where
    (>>=)  = thenM
    (>>)   = thenM_
    return = returnM
    fail s = failM -- Ignore the string

instance Applicative (IOEnv m) where
    pure = returnM
    IOEnv f <*> IOEnv x = IOEnv (\ env -> f env <*> x env )

instance Functor (IOEnv m) where
    fmap f (IOEnv m) = IOEnv (\ env -> fmap f (m env))

returnM :: a -> IOEnv env a
returnM a = IOEnv (\ env -> return a)

thenM :: IOEnv env a -> (a -> IOEnv env b) -> IOEnv env b
thenM (IOEnv m) f = IOEnv (\ env -> do { r <- m env ;
                                         unIOEnv (f r) env })

thenM_ :: IOEnv env a -> IOEnv env b -> IOEnv env b
thenM_ (IOEnv m) f = IOEnv (\ env -> do { m env ; unIOEnv f env })

failM :: IOEnv env a
failM = IOEnv (\ env -> ioError (userError "IOEnv failure"))

failWithM :: String -> IOEnv env a
failWithM s = IOEnv (\ env -> ioError (userError s))



----------------------------------------------------------------------
-- Fundmantal combinators specific to the monad
----------------------------------------------------------------------


---------------------------
runIOEnv :: env -> IOEnv env a -> IO a
runIOEnv env (IOEnv m) = m env


---------------------------
{-# NOINLINE fixM #-}
  -- Aargh!  Not inlining fixTc alleviates a space leak problem.
  -- Normally fixTc is used with a lazy tuple match: if the optimiser is
  -- shown the definition of fixTc, it occasionally transforms the code
  -- in such a way that the code generator doesn't spot the selector
  -- thunks.  Sigh.

fixM :: (a -> IOEnv env a) -> IOEnv env a
fixM f = IOEnv (\ env -> fixIO (\ r -> unIOEnv (f r) env))


---------------------------
tryM :: IOEnv env r -> IOEnv env (Either Exception r)
-- Reflect UserError exceptions (only) into IOEnv monad
-- Other exceptions are not caught; they are simply propagated as exns
--
-- The idea is that errors in the program being compiled will give rise
-- to UserErrors.  But, say, pattern-match failures in GHC itself should
-- not be caught here, else they'll be reported as errors in the program
-- begin compiled!
tryM (IOEnv thing) = IOEnv (\ env -> tryUser (thing env))

tryAllM :: IOEnv env r -> IOEnv env (Either Exception r)
-- Catch *all* exceptions
-- This is used when running a Template-Haskell splice, when
-- even a pattern-match failure is a programmer error
tryAllM (IOEnv thing) = IOEnv (\ env -> try (thing env))

tryMostM :: IOEnv env r -> IOEnv env (Either Exception r)
tryMostM (IOEnv thing) = IOEnv (\ env -> tryMost (thing env))

---------------------------
unsafeInterleaveM :: IOEnv env a -> IOEnv env a
unsafeInterleaveM (IOEnv m) = IOEnv (\ env -> unsafeInterleaveIO (m env))


----------------------------------------------------------------------
-- Accessing input/output
----------------------------------------------------------------------

instance MonadIO (IOEnv env) where
    liftIO io = IOEnv (\ env -> io)

newMutVar :: a -> IOEnv env (IORef a)
newMutVar val = liftIO (newIORef val)

writeMutVar :: IORef a -> a -> IOEnv env ()
writeMutVar var val = liftIO (writeIORef var val)

readMutVar :: IORef a -> IOEnv env a
readMutVar var = liftIO (readIORef var)

updMutVar :: IORef a -> (a -> a) -> IOEnv env ()
updMutVar var upd = liftIO (modifyIORef var upd)


----------------------------------------------------------------------
-- Accessing the environment
----------------------------------------------------------------------

getEnv :: IOEnv env env
{-# INLINE getEnv #-}
getEnv = IOEnv (\ env -> return env)

-- | Perform a computation with a different environment
setEnv :: env' -> IOEnv env' a -> IOEnv env a
{-# INLINE setEnv #-}
setEnv new_env (IOEnv m) = IOEnv (\ env -> m new_env)

-- | Perform a computation with an altered environment
updEnv :: (env -> env') -> IOEnv env' a -> IOEnv env a
{-# INLINE updEnv #-}
updEnv upd (IOEnv m) = IOEnv (\ env -> m (upd env))


----------------------------------------------------------------------
-- Standard combinators, but specialised for this monad
-- (for efficiency)
----------------------------------------------------------------------

{-# -- SPECIALIZE mapM          :: (a -> IOEnv env b) -> [a] -> IOEnv env [b] #-}
{-# -- SPECIALIZE mapM_         :: (a -> IOEnv env b) -> [a] -> IOEnv env () #-}
{-# -- SPECIALIZE mapSndM       :: (b -> IOEnv env c) -> [(a,b)] -> IOEnv env [(a,c)] #-}
{-# -- SPECIALIZE sequence      :: [IOEnv env a] -> IOEnv env [a] #-}
{-# -- SPECIALIZE sequence_     :: [IOEnv env a] -> IOEnv env () #-}
{-# -- SPECIALIZE foldlM        :: (a -> b -> IOEnv env a)  -> a -> [b] -> IOEnv env a #-}
{-# -- SPECIALIZE foldrM        :: (b -> a -> IOEnv env a)  -> a -> [b] -> IOEnv env a #-}
{-# -- SPECIALIZE mapAndUnzipM  :: (a -> IOEnv env (b,c))   -> [a] -> IOEnv env ([b],[c]) #-}
{-# -- SPECIALIZE mapAndUnzip3M :: (a -> IOEnv env (b,c,d)) -> [a] -> IOEnv env ([b],[c],[d]) #-}
{-# -- SPECIALIZE zipWithM      :: (a -> b -> IOEnv env c) -> [a] -> [b] -> IOEnv env [c] #-}
{-# -- SPECIALIZE zipWithM_     :: (a -> b -> IOEnv env c) -> [a] -> [b] -> IOEnv env () #-}
{-# -- SPECIALIZE anyM          :: (a -> IOEnv env Bool) -> [a] -> IOEnv env Bool #-}
{-# -- SPECIALIZE when          :: Bool -> IOEnv env a -> IOEnv env () #-}
{-# -- SPECIALIZE unless        :: Bool -> IOEnv env a -> IOEnv env () #-}
