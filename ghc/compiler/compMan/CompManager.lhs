%
% (c) The University of Glasgow, 2000
%
\section[CompManager]{The Compilation Manager}

\begin{code}
module CompManager ( cmInit, cmLoadModule, 
                     cmGetExpr, cmRunExpr,
                     CmState, emptyCmState  -- abstract
                   )
where

#include "HsVersions.h"

import List		( nub )
import Maybe		( catMaybes, maybeToList, fromMaybe )
import Maybes		( maybeToBool )
import Outputable
import UniqFM		( emptyUFM, lookupUFM, addToUFM, delListFromUFM )
import Digraph		( SCC(..), stronglyConnComp, flattenSCC, flattenSCCs )
import Panic		( panic )

import CmLink 		( PersistentLinkerState, emptyPLS, Linkable(..), 
			  link, LinkResult(..), 
			  filterModuleLinkables, modname_of_linkable,
			  is_package_linkable, findModuleLinkable )
import Interpreter	( HValue )
import CmSummarise	( summarise, ModSummary(..), 
			  name_of_summary, {-, is_source_import-} )
import Module		( ModuleName, moduleName, packageOfModule, 
			  isModuleInThisPackage, PackageName, moduleEnvElts,
			  moduleNameUserString )
import CmStaticInfo	( Package(..), PackageConfigInfo, GhciMode )
import DriverPipeline 	( compile, preprocess, doLink, CompResult(..) )
import HscTypes		( HomeSymbolTable, HomeIfaceTable, 
			  PersistentCompilerState, ModDetails(..) )
import Name		( lookupNameEnv )
import PrelNames	( mainName )
import HscMain		( initPersistentCompilerState )
import Finder		( findModule, emptyHomeDirCache )
import DriverUtil	( BarfKind(..) )
import Exception	( throwDyn )
import IO		( hPutStrLn, stderr )
\end{code}



\begin{code}
cmInit :: PackageConfigInfo -> GhciMode -> IO CmState
cmInit raw_package_info gmode
   = emptyCmState raw_package_info gmode

cmGetExpr :: CmState
          -> ModuleName
          -> String
          -> IO (CmState, Either [SDoc] HValue)
cmGetExpr cmstate modhdl expr
   = return (panic "cmGetExpr:unimp")

cmRunExpr :: HValue -> IO ()
cmRunExpr hval
   = return (panic "cmRunExpr:unimp")


-- Persistent state just for CM, excluding link & compile subsystems
data PersistentCMState
   = PersistentCMState {
        hst   :: HomeSymbolTable,    -- home symbol table
        hit   :: HomeIfaceTable,     -- home interface table
        ui    :: UnlinkedImage,      -- the unlinked images
        mg    :: ModuleGraph,        -- the module graph
        pci   :: PackageConfigInfo,  -- NEVER CHANGES
        gmode :: GhciMode            -- NEVER CHANGES
     }

emptyPCMS :: PackageConfigInfo -> GhciMode -> PersistentCMState
emptyPCMS pci gmode
  = PersistentCMState { hst = emptyHST, hit = emptyHIT,
                        ui  = emptyUI,  mg  = emptyMG, 
                        pci = pci, gmode = gmode }

emptyHIT :: HomeIfaceTable
emptyHIT = emptyUFM
emptyHST :: HomeSymbolTable
emptyHST = emptyUFM



-- Persistent state for the entire system
data CmState
   = CmState {
        pcms   :: PersistentCMState,       -- CM's persistent state
        pcs    :: PersistentCompilerState, -- compile's persistent state
        pls    :: PersistentLinkerState    -- link's persistent state
     }

emptyCmState :: PackageConfigInfo -> GhciMode -> IO CmState
emptyCmState pci gmode
    = do let pcms = emptyPCMS pci gmode
         pcs     <- initPersistentCompilerState
         pls     <- emptyPLS
         return (CmState { pcms   = pcms,
                           pcs    = pcs,
                           pls    = pls })

-- CM internal types
type UnlinkedImage = [Linkable]	-- the unlinked images (should be a set, really)
emptyUI :: UnlinkedImage
emptyUI = []

type ModuleGraph = [ModSummary]  -- the module graph, topologically sorted
emptyMG :: ModuleGraph
emptyMG = []

\end{code}

The real business of the compilation manager: given a system state and
a module name, try and bring the module up to date, probably changing
the system state at the same time.

\begin{code}
cmLoadModule :: CmState 
             -> ModuleName
             -> IO (CmState, Maybe ModuleName)

cmLoadModule cmstate1 rootname
   = do -- version 1's are the original, before downsweep
        let pcms1     = pcms   cmstate1
        let pls1      = pls    cmstate1
        let pcs1      = pcs    cmstate1
        let mg1       = mg     pcms1
        let hst1      = hst    pcms1
        let hit1      = hit    pcms1
        let ui1       = ui     pcms1
   
        let pcii      = pci   pcms1 -- this never changes
        let ghci_mode = gmode pcms1 -- ToDo: fix!

        -- Do the downsweep to reestablish the module graph
        -- then generate version 2's by removing from HIT,HST,UI any
        -- modules in the old MG which are not in the new one.

        -- Throw away the old home dir cache
        emptyHomeDirCache

        putStr "cmLoadModule: downsweep begins\n"
        mg2unsorted <- downsweep [rootname]

        let modnames1   = map name_of_summary mg1
        let modnames2   = map name_of_summary mg2unsorted
        let mods_to_zap = filter (`notElem` modnames2) modnames1

        let (hst2, hit2, ui2)
               = removeFromTopLevelEnvs mods_to_zap (hst1, hit1, ui1)
        -- should be cycle free; ignores 'import source's
        let mg2 = topological_sort False mg2unsorted
        -- ... whereas this takes them into account.  Only used for
        -- backing out partially complete cycles following a failed
        -- upsweep.
        let mg2_with_srcimps = topological_sort True mg2unsorted
      
        putStrLn "after tsort:\n"
        putStrLn (showSDoc (vcat (map ppr mg2)))

        -- Because we don't take into account source imports when doing
        -- the topological sort, there shouldn't be any cycles in mg2.
        -- If there is, we complain and give up -- the user needs to
        -- break the cycle using a boot file.

        -- Now do the upsweep, calling compile for each module in
        -- turn.  Final result is version 3 of everything.

        let threaded2 = CmThreaded pcs1 hst2 hit2

        (upsweep_complete_success, threaded3, modsDone, newLis)
           <- upsweep_mods ui2 threaded2 mg2

        let ui3 = add_to_ui ui2 newLis
        let (CmThreaded pcs3 hst3 hit3) = threaded3

        -- At this point, modsDone and newLis should have the same
        -- length, so there is one new (or old) linkable for each 
        -- mod which was processed (passed to compile).

        -- Try and do linking in some form, depending on whether the
        -- upsweep was completely or only partially successful.

        if upsweep_complete_success

         then 
           -- Easy; just relink it all.
           do putStrLn "UPSWEEP COMPLETELY SUCCESSFUL"
              linkresult 
                 <- link doLink ghci_mode (any exports_main (moduleEnvElts hst3)) 
                         newLis pls1
              case linkresult of
                 LinkErrs _ _
                    -> panic "cmLoadModule: link failed (1)"
                 LinkOK pls3 
                    -> do let pcms3 = PersistentCMState { hst=hst3, hit=hit3, 
                                                          ui=ui3, mg=modsDone, 
                                                          pci=pcii, gmode=ghci_mode }
                          let cmstate3 
                                 = CmState { pcms=pcms3, pcs=pcs3, pls=pls3 }
                          return (cmstate3, Just rootname)

         else 
           -- Tricky.  We need to back out the effects of compiling any
           -- half-done cycles, both so as to clean up the top level envs
           -- and to avoid telling the interactive linker to link them.
           do putStrLn "UPSWEEP PARTIALLY SUCCESSFUL"

              let modsDone_names
                     = map name_of_summary modsDone
              let mods_to_zap_names 
                     = findPartiallyCompletedCycles modsDone_names mg2_with_srcimps
              let (hst4, hit4, ui4) 
                     = removeFromTopLevelEnvs mods_to_zap_names (hst3,hit3,ui3)
              let mods_to_keep
                     = filter ((`notElem` mods_to_zap_names).name_of_summary) modsDone
              let mods_to_keep_names 
                     = map name_of_summary mods_to_keep
              -- we could get the relevant linkables by filtering newLis, but
              -- it seems easier to drag them out of the updated, cleaned-up UI
              let linkables_to_link 
                     = map (findModuleLinkable ui4) mods_to_keep_names

              linkresult <- link doLink ghci_mode False linkables_to_link pls1
              case linkresult of
                 LinkErrs _ _
                    -> panic "cmLoadModule: link failed (2)"
                 LinkOK pls4
                    -> do let pcms4 = PersistentCMState { hst=hst4, hit=hit4, 
                                                          ui=ui4, mg=mods_to_keep,
                                                          pci=pcii, gmode=ghci_mode }
                          let cmstate4 
                                 = CmState { pcms=pcms4, pcs=pcs3, pls=pls4 }
                          return (cmstate4, 
                                  -- choose rather arbitrarily who to return
                                  if null mods_to_keep then Nothing 
                                     else Just (last mods_to_keep_names))


-- Return (names of) all those in modsDone who are part of a cycle
-- as defined by theGraph.
findPartiallyCompletedCycles :: [ModuleName] -> [SCC ModSummary] -> [ModuleName]
findPartiallyCompletedCycles modsDone theGraph
   = chew theGraph
     where
        chew [] = []
        chew ((AcyclicSCC v):rest) = chew rest    -- acyclic?  not interesting.
        chew ((CyclicSCC vs):rest)
           = let names_in_this_cycle = nub (map name_of_summary vs)
                 mods_in_this_cycle  
                    = nub ([done | done <- modsDone, 
                                   done `elem` names_in_this_cycle])
                 chewed_rest = chew rest
             in 
             if   not (null mods_in_this_cycle) 
                  && length mods_in_this_cycle < length names_in_this_cycle
             then mods_in_this_cycle ++ chewed_rest
             else chewed_rest


exports_main :: ModDetails -> Bool
exports_main md
   = maybeToBool (lookupNameEnv (md_types md) mainName)


-- Add the given (LM-form) Linkables to the UI, overwriting previous
-- versions if they exist.
add_to_ui :: UnlinkedImage -> [Linkable] -> UnlinkedImage
add_to_ui ui lis
   = foldr add1 ui lis
     where
        add1 :: Linkable -> UnlinkedImage -> UnlinkedImage
        add1 li ui
           = li : filter (\li2 -> not (for_same_module li li2)) ui

        for_same_module :: Linkable -> Linkable -> Bool
        for_same_module li1 li2 
           = not (is_package_linkable li1)
             && not (is_package_linkable li2)
             && modname_of_linkable li1 == modname_of_linkable li2
                                  

data CmThreaded  -- stuff threaded through individual module compilations
   = CmThreaded PersistentCompilerState HomeSymbolTable HomeIfaceTable


-- Compile multiple modules, stopping as soon as an error appears.
-- There better had not be any cyclic groups here -- we check for them.
upsweep_mods :: UnlinkedImage         -- old linkables
             -> CmThreaded            -- PCS & HST & HIT
             -> [SCC ModSummary]      -- mods to do (the worklist)
                                      -- ...... RETURNING ......
             -> IO (Bool{-complete success?-},
                    CmThreaded,
                    [ModSummary],     -- mods which succeeded
                    [Linkable])       -- new linkables

upsweep_mods oldUI threaded []
   = return (True, threaded, [], [])

upsweep_mods oldUI threaded ((CyclicSCC ms):_)
   = do hPutStrLn stderr ("ghc: module imports form a cycle for modules:\n\t" ++
                          unwords (map (moduleNameUserString.name_of_summary) ms))
        return (False, threaded, [], [])

upsweep_mods oldUI threaded ((AcyclicSCC mod):mods)
   = do (threaded1, maybe_linkable) <- upsweep_mod oldUI threaded mod
        case maybe_linkable of
           Just linkable 
              -> -- No errors; do the rest
                 do (restOK, threaded2, modOKs, linkables) 
                       <- upsweep_mods oldUI threaded1 mods
                    return (restOK, threaded2, mod:modOKs, linkable:linkables)
           Nothing -- we got a compilation error; give up now
              -> return (False, threaded1, [], [])


-- Compile a single module.  Always produce a Linkable for it if 
-- successful.  If no compilation happened, return the old Linkable.
upsweep_mod :: UnlinkedImage 
            -> CmThreaded
            -> ModSummary
            -> IO (CmThreaded, Maybe Linkable)

upsweep_mod oldUI threaded1 summary1
   = do let mod_name = name_of_summary summary1
        let (CmThreaded pcs1 hst1 hit1) = threaded1
        let old_iface = lookupUFM hit1 (name_of_summary summary1)
        compresult <- compile summary1 old_iface hst1 hit1 pcs1

        case compresult of

           -- Compilation "succeeded", but didn't return a new iface or
           -- linkable, meaning that compilation wasn't needed, and the
           -- new details were manufactured from the old iface.
           CompOK details Nothing pcs2
              -> let hst2         = addToUFM hst1 mod_name details
                     hit2         = hit1
                     threaded2    = CmThreaded pcs2 hst2 hit2
                     old_linkable = findModuleLinkable oldUI mod_name
                 in  return (threaded2, Just old_linkable)

           -- Compilation really did happen, and succeeded.  A new
           -- details, iface and linkable are returned.
           CompOK details (Just (new_iface, new_linkable)) pcs2
              -> let hst2      = addToUFM hst1 mod_name details
                     hit2      = addToUFM hit1 mod_name new_iface
                     threaded2 = CmThreaded pcs2 hst2 hit2
                 in  return (threaded2, Just new_linkable)

           -- Compilation failed.  compile may still have updated
           -- the PCS, tho.
           CompErrs pcs2
              -> let threaded2 = CmThreaded pcs2 hst1 hit1
                 in  return (threaded2, Nothing)


removeFromTopLevelEnvs :: [ModuleName]
                       -> (HomeSymbolTable, HomeIfaceTable, UnlinkedImage)
                       -> (HomeSymbolTable, HomeIfaceTable, UnlinkedImage)
removeFromTopLevelEnvs zap_these (hst, hit, ui)
   = (delListFromUFM hst zap_these,
      delListFromUFM hit zap_these,
      filterModuleLinkables (`notElem` zap_these) ui
     )


topological_sort :: Bool -> [ModSummary] -> [SCC ModSummary]
topological_sort include_source_imports summaries
   = let 
         toEdge :: ModSummary -> (ModSummary,ModuleName,[ModuleName])
         toEdge summ
             = (summ, name_of_summary summ, 
                      (if include_source_imports 
                       then ms_srcimps summ else []) ++ ms_imps summ)
        
         mash_edge :: (ModSummary,ModuleName,[ModuleName]) -> (ModSummary,Int,[Int])
         mash_edge (summ, m, m_imports)
            = case lookup m key_map of
                 Nothing -> panic "reverse_topological_sort"
                 Just mk -> (summ, mk, 
                                -- ignore imports not from the home package
                                catMaybes (map (flip lookup key_map) m_imports))

         edges     = map toEdge summaries
         key_map   = zip [nm | (s,nm,imps) <- edges] [1 ..] :: [(ModuleName,Int)]
         scc_input = map mash_edge edges
         sccs      = stronglyConnComp scc_input
     in
         sccs


-- Chase downwards from the specified root set, returning summaries
-- for all home modules encountered.  Only follow source-import
-- links.
downsweep :: [ModuleName] -> IO [ModSummary]
downsweep rootNm
   = do rootSummaries <- mapM getSummary rootNm
        loop (filter (isModuleInThisPackage.ms_mod) rootSummaries)
     where
        getSummary :: ModuleName -> IO ModSummary
        getSummary nm
           | trace ("getSummary: "++ showSDoc (ppr nm)) True
           = do found <- findModule nm
		case found of
		   Just (mod, location) -> summarise preprocess mod location
		   Nothing -> throwDyn (OtherError 
                                   ("no signs of life for module `" 
                                     ++ showSDoc (ppr nm) ++ "'"))
                                 
        -- loop invariant: homeSummaries doesn't contain package modules
        loop :: [ModSummary] -> IO [ModSummary]
        loop homeSummaries
           = do let allImps :: [ModuleName]
                    allImps = (nub . concatMap ms_imps) homeSummaries
                let allHome   -- all modules currently in homeSummaries
                       = map (moduleName.ms_mod) homeSummaries
                let neededImps
                       = filter (`notElem` allHome) allImps
                neededSummaries
                       <- mapM getSummary neededImps
                let newHomeSummaries
                       = filter (isModuleInThisPackage.ms_mod) neededSummaries
                if null newHomeSummaries
                 then return homeSummaries
                 else loop (newHomeSummaries ++ homeSummaries)
\end{code}
