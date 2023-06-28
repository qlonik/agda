{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE PatternGuards   #-}
{-# LANGUAGE ViewPatterns    #-}

module Compiler.Tests where

import Data.Bits (finiteBitSize)
import Data.List (isPrefixOf)
import Data.Monoid
import qualified Data.Text as T
import Data.Text.Encoding
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO.Temp
import qualified System.Process as P
import System.Process.Text as PT
import Test.Tasty
import Test.Tasty.Silver
import Test.Tasty.Silver.Advanced (readFileMaybe)
import Test.Tasty.Silver.Filter
import Utils

import Control.Monad (forM)
import Data.Maybe
import Text.Read

import Agda.Utils.List
import Agda.Utils.List1 (nonEmpty, toList)

import Agda.Utils.Impossible (__IMPOSSIBLE__)
import Agda.Utils.List1 (NonEmpty, String1, wordsBy)
import Agda.Utils.Monad
import Control.Monad (liftM3)
import Data.Bool (bool)
import Data.Function ((&))
import Data.Functor (($>), (<&>))
import qualified Text.Read as T
import Text.Regex.TDFA (Regex, blankCompOpt, blankExecOpt, caseSensitive,
                       getAllTextSubmatches, makeRegexOpts, match, matchM,
                       newSyntax)

type GHCArgs = [String]

data ExecResult
  = CompileFailed
    { result :: ProgramResult
    }
  | CompileSucceeded
    { result :: ProgramResult
    }
  | ExecutedProg
    { result :: ProgramResult
    }
  deriving (Eq, Read, Show)

data JSModuleFormat = CJS | ESM deriving (Eq, Read, Show)

data CodeOptimization = NonOptimized | Optimized | MinifiedOptimized deriving
  ( Eq
  , Read
  , Show
  )

data Strict = Strict | StrictData | Lazy deriving (Eq, Read, Show)

data Compiler
  = MAlonzo Strict
  | JS JSModuleFormat CodeOptimization
  deriving (Eq, Read, Show)

data CompilerOptions
  = CompilerOptions
    { extraAgdaArgs :: AgdaArgs
    }
  deriving (Read, Show)

data TestOptions
  = TestOptions
    { forCompilers   :: [(Compiler, CompilerOptions)]
    , runtimeOptions :: [String]
    , executeProg    :: Bool
    }
  deriving (Read, Show)

data Semver
  = Semver
    { major      :: Integer
    , minor      :: Integer
    , patch      :: Integer
    , prerelease :: Maybe String1
    , build      :: Maybe String1
    }

instance Show Semver where
  show (Semver{major, minor, patch, prerelease, build}) =
    (show major) ++ "." ++ (show minor) ++ "." ++ (show patch)
    ++ (maybe "" (\v -> "-" ++ show v) prerelease)
    ++ (maybe "" (\v -> "+" ++ show v) build)

allCompilers :: [Compiler]
allCompilers =
  map MAlonzo [Lazy, StrictData, Strict] ++
  (JS <$> [CJS, ESM] <*> [NonOptimized, Optimized, MinifiedOptimized])

defaultOptions :: TestOptions
defaultOptions = TestOptions
  { forCompilers   = [ (c, co) | c <- allCompilers ]
  , runtimeOptions = []
  , executeProg    = True
  }
  where co = CompilerOptions []

disabledTests :: [RegexFilter]
disabledTests =
  [ -----------------------------------------------------------------------------
    -- These test are disabled on all backends.
    -- See issue 1528
    disable "Compiler/.*/simple/Sharing"
    -- Fix to 2524 is too unsafe
  , disable "Compiler/.*/simple/Issue2524"
    -- Issue #2640 (forcing translation for runtime erasure) is still open
  , disable "Compiler/.*/simple/Erasure-Issue2640"
    -----------------------------------------------------------------------------
    -- The test case for #2918 stopped working when inlining of
    -- recursive pattern-matching lambdas was disabled.
  , disable "Compiler/MAlonzo_.*/simple/Issue2918$"
    -----------------------------------------------------------------------------
    -- The following test cases use primitives that are not implemented in the
    -- JS backend.
  , disable "Compiler/JS_.*/simple/Issue4999"   -- primNatToChar
    -----------------------------------------------------------------------------
    -- The following test cases are GHC backend specific and thus disabled on JS.
  , disable "Compiler/JS_.*/simple/Issue2821"
  , disable "Compiler/JS_.*/simple/Issue2879-.*"
  , disable "Compiler/JS_.*/simple/Issue2909-.*"
  , disable "Compiler/JS_.*/simple/Issue2914"
  , disable "Compiler/JS_.*/simple/Issue2918$"
  , disable "Compiler/JS_.*/simple/Issue3732"
  , disable "Compiler/JS_.*/simple/VecReverseIrr"
  , disable "Compiler/JS_.*/simple/VecReverseErased"  -- RangeError: Maximum call stack size exceeded
    -----------------------------------------------------------------------------
  ]
  where disable = RFInclude

-- | Filtering out compiler tests using the Agda standard library.

stdlibTestFilter :: [RegexFilter]
stdlibTestFilter =
  [ disable "Compiler/.*/with-stdlib"
  ]
  where disable = RFInclude

tests :: IO TestTree
tests = do
  ghcVersion <- findGHCVersion
  nodeBinVersion <- findExecutable "node"
    >>= traverse (\nodeBin ->
      findNodeVersion nodeBin <&> (nodeBin,)
    )
  case nodeBinVersion of
    Nothing -> putStrLn "No JS node binary found, skipping JS tests."
    Just (nodeBin, version) -> do
      putStrLn $ "Found JS node binary at " ++ nodeBin
      case version of
        Nothing      -> putStrLn "But could not determine its version"
        Just version -> do
          putStrLn $ "Node binary version is " ++ (show version)
          putStrLn
            $ bool
              "Only CJS-based tests will run."
              "Both CJS-based and ESM-based tests will run."
            $ nodeVersionSupportsESM version
  let ghcVersionAtLeast9 = case ghcVersion of
        Just (n : _) | n >= 9 -> True
        _                     -> False
      ghcCompilers = [ MAlonzo s
        | s <- [Lazy, StrictData] ++
               if ghcVersionAtLeast9 then [Strict] else []
        ]
      jsCompilers = case nodeBinVersion of
        Nothing     -> []
        Just (_, v) ->
          [ JS format opt
          | format <- [CJS] ++
                      case fmap nodeVersionSupportsESM v of
                        Just True -> [ESM]
                        _         -> []
          , opt <- [NonOptimized, Optimized, MinifiedOptimized]
          ]
      enabledCompilers = ghcCompilers ++ jsCompilers
  ts <- mapM forComp enabledCompilers
  return $ testGroup "Compiler" ts
  where
    forComp comp = testGroup (map spaceToUnderscore $ show comp) . catMaybes
        <$> sequence
            -- TODO: update each of these 3 functions to support ESM
            [ Just <$> simpleTests comp
            , Just <$> stdlibTests comp
            , specialTests comp]

    spaceToUnderscore ' ' = '_'
    spaceToUnderscore c   = c

simpleTests :: Compiler -> IO TestTree
simpleTests comp = do
  let testDir = "test" </> "Compiler" </> "simple"
  inps <- getAgdaFilesInDir NonRec testDir

  tests' <- forM inps $ \inp -> do
    opts <- readOptions inp
    return $
      agdaRunProgGoldenTest testDir comp
        (return $ ["-i" ++ testDir, "-itest/"] ++ compArgs comp) inp opts
  return $ testGroup "simple" $ catMaybes tests'

  where compArgs :: Compiler -> AgdaArgs
        compArgs MAlonzo{} =
          ghcArgsAsAgdaArgs ["-itest/", "-fno-excess-precision"]
        compArgs JS{} = []

-- The Compiler tests using the standard library are horribly
-- slow at the moment (1min or more per test case).
stdlibTests :: Compiler -> IO TestTree
stdlibTests comp = do
  let testDir = "test" </> "Compiler" </> "with-stdlib"
  let inps    = [testDir </> "AllStdLib.agda"]
    -- put all tests in AllStdLib to avoid compiling the standard library
    -- multiple times

  let extraArgs :: [String]
      extraArgs =
        [ "-i" ++ testDir
        , "-i" ++ "std-lib" </> "src"
        , "-istd-lib"
        , "--warning=noUnsupportedIndexedMatch"
        ]

  let -- Note that -M4G can trigger the following error on 32-bit
      -- systems: "error in RTS option -M4G: size outside allowed
      -- range (4096 - 4294967295)".
      maxHeapSize =
        if finiteBitSize (undefined :: Int) == 32 then
          "-M2G"
        else
          "-M4G"

      rtsOptions :: [String]
      -- See Issue #3792.
      rtsOptions = [ "+RTS", "-H2G", maxHeapSize, "-RTS" ]

  tests' <- forM inps $ \inp -> do
    opts <- readOptions inp
    return $
      agdaRunProgGoldenTest testDir comp (return $ extraArgs ++ rtsOptions) inp opts
  return $ testGroup "with-stdlib" $ catMaybes tests'


specialTests :: Compiler -> IO (Maybe TestTree)
specialTests c@MAlonzo{} = do
  let t = fromJust $
            agdaRunProgGoldenTest1 testDir c (return extraArgs)
              (testDir </> "ExportTestAgda.agda") defaultOptions cont

  return $ Just $ testGroup "special" [t]
  where extraArgs = ["-i" ++ testDir, "-itest/", "--no-main", "--ghc-dont-call-ghc"]
        testDir = "test" </> "Compiler" </> "special"
        cont compDir out err = do
            (ret, sout, _) <- PT.readProcessWithExitCode "runghc"
                    [ "-itest/"
                    ,"-i" ++ compDir
                    , testDir </> "ExportTest.hs"
                    ]
                    T.empty
            -- ignore stderr, as there may be some GHC warnings in it
            return $ ExecutedProg (ProgramResult ret (out <> sout) err)
specialTests JS{} = return Nothing

ghcArgsAsAgdaArgs :: GHCArgs -> AgdaArgs
ghcArgsAsAgdaArgs = map f
  where f = ("--ghc-flag=" ++)

agdaRunProgGoldenTest :: FilePath     -- ^ directory where to run the tests.
    -> Compiler
    -> IO AgdaArgs     -- ^ extra Agda arguments
    -> FilePath -- ^ relative path to agda input file.
    -> TestOptions
    -> Maybe TestTree
agdaRunProgGoldenTest dir comp extraArgs inp opts =
      agdaRunProgGoldenTest1 dir comp extraArgs inp opts $ \compDir out err -> do
        if executeProg opts then do
          -- read input file, if it exists
          inp' <- maybe T.empty decodeUtf8 <$> readFileMaybe inpFile
          -- now run the new program
          let exec = getExecForComp comp compDir inpFile
          (ret, out', err') <- case comp of
            (JS format _) -> do
              when (format == CJS) $ setEnv "NODE_PATH" compDir
              PT.readProcessWithExitCode "node" ([exec] ++ runtimeOptions opts) inp'
            _ -> do
              PT.readProcessWithExitCode exec (runtimeOptions opts) inp'
          return $ ExecutedProg $ ProgramResult ret (out <> out') (err <> err')
        else
          return $ CompileSucceeded (ProgramResult ExitSuccess out err)
  where inpFile = dropAgdaExtension inp <.> ".inp"

agdaRunProgGoldenTest1 :: FilePath     -- ^ directory where to run the tests.
    -> Compiler
    -> IO AgdaArgs     -- ^ extra Agda arguments
    -> FilePath -- ^ relative path to agda input file.
    -> TestOptions
    -> (FilePath -> T.Text -> T.Text -> IO ExecResult) -- continuation if compile succeeds, gets the compilation dir
    -> Maybe TestTree
agdaRunProgGoldenTest1 dir comp extraArgs inp opts cont
  | (Just cOpts) <- lookup comp (forCompilers opts) =
      Just $ goldenVsAction' testName goldenFile (doRun cOpts) printExecResult
  | otherwise = Nothing
  where goldenFile = dropAgdaExtension inp <.> ".out"
        testName   = asTestName dir inp

        -- Andreas, 2017-04-14, issue #2317
        -- Create temporary files in system temp directory.
        -- This has the advantage that upon Ctrl-C no junk is left behind
        -- in the Agda directory.
        -- doRun cOpts = withTempDirectory dir testName (\compDir -> do
        doRun cOpts = withSystemTempDirectory testName (\compDir -> do
          -- get extra arguments
          extraArgs' <- extraArgs
          -- compile file
          let cArgs   = cleanUpOptions (extraAgdaArgs cOpts)
              defArgs = ["--ignore-interfaces" | notElem "--no-ignore-interfaces" (extraAgdaArgs cOpts)] ++
                        ["--no-libraries"] ++
                        ["--compile-dir", compDir, "-v0", "-vwarning:1"] ++ extraArgs' ++ cArgs ++ [inp]
          let args = argsForComp comp ++ defArgs
          res@(ret, out, err) <- readAgdaProcessWithExitCode args T.empty

          absDir <- canonicalizePath dir
          removePaths [absDir, compDir] <$> case ret of
            ExitSuccess   -> cont compDir out err
            ExitFailure _ -> return $ CompileFailed $ toProgramResult res
          )

        argsForComp :: Compiler -> [String]
        argsForComp (MAlonzo s) = [ "--compile" ] ++ case s of
          Lazy       -> []
          StrictData -> ["--ghc-strict-data"]
          Strict     -> ["--ghc-strict"]
        argsForComp (JS f o)  =
          [ "--js", "--js-verify" ]
          ++ case f of
            CJS -> ["--js-cjs"]
            ESM -> ["--js-esm"]
          ++ case o of
            NonOptimized      -> []
            Optimized         -> [ "--js-optimize" ]
            MinifiedOptimized -> [ "--js-optimize", "--js-minify" ]

        removePaths ps = \case
          CompileFailed    r -> CompileFailed    (removePaths' r)
          CompileSucceeded r -> CompileSucceeded (removePaths' r)
          ExecutedProg     r -> ExecutedProg     (removePaths' r)
          where
          removePaths' (ProgramResult c out err) = ProgramResult c (rm out) (rm err)

          rm = foldr (.) id $
               map (\p -> T.concat . T.splitOn (T.pack p)) ps

readOptions :: FilePath -- file name of the agda file
    -> IO TestOptions
readOptions inpFile =
  maybe defaultOptions (read . T.unpack . decodeUtf8) <$> readFileMaybe optFile
  where optFile = dropAgdaOrOtherExtension inpFile <.> ".options"

cleanUpOptions :: AgdaArgs -> AgdaArgs
cleanUpOptions = filter clean
  where
    clean :: String -> Bool
    clean "--no-ignore-interfaces"         = False
    clean o | isPrefixOf "--ghc-flag=-j" o = True
    clean _                                = True

-- gets the generated executable path
getExecForComp :: Compiler -> FilePath -> FilePath -> FilePath
getExecForComp JS{} compDir inpFile = compDir </> ("jAgda." ++ (takeFileName $ dropAgdaOrOtherExtension inpFile) ++ ".js")
getExecForComp _ compDir inpFile = compDir </> (takeFileName $ dropAgdaOrOtherExtension inpFile)

printExecResult :: ExecResult -> T.Text
printExecResult (CompileFailed r)    = "COMPILE_FAILED\n\n"    <> printProgramResult r
printExecResult (CompileSucceeded r) = "COMPILE_SUCCEEDED\n\n" <> printProgramResult r
printExecResult (ExecutedProg r)     = "EXECUTED_PROGRAM\n\n"  <> printProgramResult r

-- | Tries to figure out the version of the program @ghc@ (if such a
-- program can be found).

findGHCVersion :: IO (Maybe [Integer])
findGHCVersion = do
  (code, version, _) <-
    P.readProcessWithExitCode "ghc" ["--numeric-version"] ""
  case code of
    ExitFailure{} -> return Nothing
    ExitSuccess   -> return $
      sequence $
      concat $
      map (map (readMaybe . toList) . wordsBy (== '.')) $
      take 1 $
      lines version

findNodeVersion :: FilePath -> IO (Maybe Semver)
findNodeVersion binPath =
  P.readProcessWithExitCode binPath ["--version"] ""
  <&> (\(code, version, _) ->
        case code of
          ExitFailure _ -> Nothing
          ExitSuccess   -> parseSemver version
      )

parseSemver :: String -> Maybe Semver
parseSemver version = case semver_reg `matchM` version of
  Just (getAllTextSubmatches -> values) ->
    forM [1, 2, 3, 5, 10] (values !!!)
    >>= (\[major, minor, patch, prerelease, build] ->
      liftM3
        (\major minor patch ->
          (major, minor, patch, nonEmpty prerelease, nonEmpty build)
        )
        (readMaybe major :: Maybe Integer)
        (readMaybe minor :: Maybe Integer)
        (readMaybe patch :: Maybe Integer)
    )
    <&> (\(major, minor, patch, prerelease, build) ->
      Semver { major, minor, patch, prerelease, build }
    )
  _ -> Nothing
  where
  -- based on
  -- https://semver.org/#is-there-a-suggested-regular-expression-regex-to-check-a-semver-string
  -- changed:
  --   - added optional `v` prefix matcher
  --   - switched to POSIX compatible regex
  --   - split into capture groups
  semver_reg = mkRegex . T.pack $ (
      "^v?" ++
      "(0|[1-9][0-9]*)\\." ++    -- 1st capture - `<major>`
      "(0|[1-9][0-9]*)\\." ++    -- 2nd capture - `<minor>`
      "(0|[1-9][0-9]*)" ++       -- 3rd capture - `<patch>`
      "(-" ++
        "(" ++                   -- 5th capture - `<pre-release>`
          "(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)" ++
          "(\\." ++
            "(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)" ++
          ")*" ++
        ")" ++
      ")?" ++
      "(\\+" ++
        "(" ++                   -- 10th capture - `<build>`
          "[0-9a-zA-Z-]+" ++
          "(\\.[0-9a-zA-Z-]+)*" ++
        ")"++
      ")?" ++
      "$"
    )

-- version matching `>= 12.22.0 < 13.0.0 || >= 14.17.0 < 15.0.0 || >= 15.3.0`
nodeVersionSupportsESM :: Semver -> Bool
nodeVersionSupportsESM (Semver {major, minor}) =
  major >= 16 ||
  (major == 15 && minor >= 3) ||
  (major == 14 && minor >= 17) ||
  (major == 12 && minor >= 22)
