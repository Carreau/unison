{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}

module Unison.Codebase.Editor where

import           Control.Monad                  ( forM_, when)
import           Control.Monad.Extra            ( ifM )
import           Data.Bifunctor                 ( second )
import qualified Data.Map                      as Map
import           Data.Sequence                  ( Seq )
import           Data.Set                       ( Set )
import           Data.Text                      ( Text
                                                , unpack
                                                )
import qualified Unison.Builtin                as B
import           Unison.Codebase                ( Codebase )
import qualified Unison.Codebase               as Codebase
import           Unison.Codebase.Branch         ( Branch
                                                , Branch0
                                                )
import qualified Unison.Codebase.Branch        as Branch
import           Unison.DataDeclaration         (DataDeclaration')
import           Unison.FileParsers             ( parseAndSynthesizeFile )
import           Unison.Names                   ( Name
                                                , Names
                                                , NameTarget
                                                )
import           Unison.Parser                  ( Ann )
import qualified Unison.Parser                 as Parser
import qualified Unison.PrettyPrintEnv         as PPE
import           Unison.Reference               ( Reference, pattern DerivedId )
import           Unison.Result                  ( Note
                                                , Result
                                                )
import qualified Unison.Result                 as Result
import           Unison.Referent                ( Referent )
import qualified Unison.Referent               as Referent
import qualified Unison.Codebase.Runtime       as Runtime
import           Unison.Codebase.Runtime       (Runtime)
import qualified Unison.Term                   as Term
import qualified Unison.Type                   as Type
import qualified Unison.Typechecker.Context    as Context
import qualified Unison.UnisonFile             as UF
import           Unison.Util.Free               ( Free )
import qualified Unison.Util.Free              as Free
import           Unison.Var                     ( Var )

data Event
  = UnisonFileChanged SourceName Text
  | UnisonBranchChanged (Set Name)

type BranchName = Name
type Source = Text -- "id x = x\nconst a b = a"
type SourceName = Text -- "foo.u" or "buffer 7"
type TypecheckingResult v =
  Result (Seq (Note v Ann))
         (PPE.PrettyPrintEnv, Maybe (UF.TypecheckedUnisonFile' v Ann))
type Term v a = Term.AnnotatedTerm v a
type Type v a = Type.AnnotatedType v a

data AddOutputComponent v =
  AddOutputComponent { implicatedTypes :: Set v, implicatedTerms :: Set v }
  deriving (Show)

data AddOutput v
  = NothingToAdd
  | Added {
          -- The file that we tried to add from
            originalFile :: UF.TypecheckedUnisonFile v Ann
          -- The branch after adding everything
          , updatedBranch :: Branch
          -- Previously existed only in the file; now added to the codebase.
          , successful :: AddOutputComponent v
          -- Exists in the branch and the file, with the same name and contents.
          , duplicates :: AddOutputComponent v
          -- Has a colliding name but a different definition than the codebase.
          , collisions :: AddOutputComponent v
          -- Already defined in the branch, but with a different name.
          , duplicateReferents :: Branch.RefCollisions
          }
          deriving (Show)

data Input
  -- high-level manipulation of names
  = AliasUnconflictedI NameTarget Name Name
  | RenameUnconflictedI NameTarget Name Name
  | UnnameAllI NameTarget Name
  -- low-level manipulation of names
  | AddTermNameI Referent Name
  | AddTypeNameI Reference Name
  | RemoveTermNameI Referent Name
  | RemoveTypeNameI Reference Name
  -- resolving naming conflicts
  | ChooseTermForNameI Referent Name
  | ChooseTypeForNameI Reference Name
  -- create and remove update directives
  | ListAllUpdatesI
    -- update a term or type, error if it would produce a conflict
  | UpdateTermI Referent Referent
  | UpdateTypeI Reference Reference
    -- clear updates for a term or type
  | RemoveAllTermUpdatesI Referent
  | RemoveAllTypeUpdatesI Reference
  -- resolve update conflicts
  | ChooseUpdateForTermI Referent Referent
  | ChooseUpdateForTypeI Reference Reference
  -- other
  | AddI -- [Name]
  | ListBranchesI
  | SearchByNameI [String]
  | SwitchBranchI BranchName
  | ForkBranchI BranchName
  | MergeBranchI BranchName
  | ShowDefinitionI [String]
  | QuitI
  deriving (Show)

data Output v
  = Success Input
  | NoUnisonFile
  | UnknownBranch BranchName
  | UnknownName BranchName NameTarget Name
  | NameAlreadyExists BranchName NameTarget Name
  -- `name` refers to more than one `nameTarget`
  | ConflictedName BranchName NameTarget Name
  | BranchAlreadyExists BranchName
  | ListOfBranches BranchName [BranchName]
  | ListOfTerms Branch [String] [(Name, Referent, Maybe (Type v Ann))]
  | AddOutput (AddOutput v)
  -- Original source, followed by the errors:
  | ParseErrors Text [Parser.Err v]
  | TypeErrors Text PPE.PrettyPrintEnv [Context.ErrorNote v Ann]
  | DisplayConflicts Branch0
  | Evaluated Names ([(Text, Term v ())], Term v ())
  | Typechecked SourceName PPE.PrettyPrintEnv (UF.TypecheckedUnisonFile' v Ann)
  | FileChangeEvent SourceName Text
  | DisplayDefinitions Branch
                       [(Name, Term v Ann)]
                       [(DataDeclaration' v Ann,
                         Maybe Name,
                         [(Int, Name, ConstructorSort)])]
  deriving (Show)

data Command i v a where
  Input :: Command i v i

  -- Presents some output to the user
  Notify :: Output v -> Command i v ()

  Add :: BranchName
      -> Branch
      -> UF.TypecheckedUnisonFile v Ann
      -> Command i v (AddOutput v)

  Typecheck :: Branch
            -> SourceName
            -> Source
            -> Command i v (TypecheckingResult v)

  -- Evaluate a UnisonFile and return the result and the result of
  -- any watched expressions (which are just labeled with `Text`)
  Evaluate :: Branch
           -> UF.UnisonFile v Ann
           -> Command i v ([(Text, Term v ())], Term v ())

  -- Load definitions from codebase:
  -- option 1:
      -- LoadTerm :: Reference -> Command i v (Maybe (Term v Ann))
      -- LoadTypeOfTerm :: Reference -> Command i v (Maybe (Type v Ann))
      -- LoadDataDeclaration :: Reference -> Command i v (Maybe (DataDeclaration' v Ann))
      -- LoadEffectDeclaration :: Reference -> Command i v (Maybe (EffectDeclaration' v Ann))
  -- option 2:
      -- LoadTerm :: Reference -> Command i v (Maybe (Term v Ann))
      -- LoadTypeOfTerm :: Reference -> Command i v (Maybe (Type v Ann))
      -- LoadTypeDecl :: Reference -> Command i v (Maybe (TypeLookup.Decl v Ann))
  -- option 3:
      -- TypeLookup :: [Reference] -> Command i v (TypeLookup.TypeLookup)

  ListBranches :: Command i v [BranchName]

  -- Loads a branch by name from the codebase, returning `Nothing` if not found.
  LoadBranch :: BranchName -> Command i v (Maybe Branch)

  -- Switches the app state to the given branch.
  SwitchBranch :: Branch -> BranchName -> Command i v ()

  -- Returns `Nothing` if a branch by that name already exists.
  NewBranch :: BranchName -> Command i v Bool

  -- Create a new branch which is a copy of the given branch, and assign the
  -- forked branch the given name. Returns `False` if the forked branch name
  -- already exists.
  ForkBranch :: Branch -> BranchName -> Command i v Bool

  -- Merges the branch with the existing branch with the given name. Returns
  -- `False` if no branch with that name exists, `True` otherwise.
  MergeBranch :: BranchName -> Branch -> Command i v Bool

  -- Return the subset of the branch tip which is in a conflicted state.
  -- A conflict is:
  -- * A name with more than one referent.
  -- *
  GetConflicts :: Branch -> Command i v Branch0

  -- RemainingWork :: Branch -> Command i v [RemainingWork]

  -- Return a list of terms whose names match the given queries.
  SearchTerms :: Branch
              -> [String]
              -> Command i v [(Name, Referent, Maybe (Type v Ann))]

  -- Return a list of types whose names match the given queries.
  SearchTypes :: Branch
              -> [String]
              -> Command i v [(Name, Reference)] -- todo: can add Kind later

  LoadTerm :: Reference -> Command i v (Term v Ann)

  LoadType :: Reference -> Command i v (DataDeclaration' v Ann)

addToBranch
  :: (Var v, Monad m)
  => Codebase m v Ann
  -> BranchName
  -> Branch
  -> UF.TypecheckedUnisonFile v Ann
  -> m (AddOutput v)
addToBranch codebase branchName branch unisonFile
  = let
      branchUpdate = Branch.fromTypecheckedFile unisonFile
      collisions   = Branch.collisions branchUpdate branch
      duplicates   = Branch.duplicates branchUpdate branch
      -- old references with new names
      dupeRefs     = Branch.refCollisions branchUpdate branch
      diffNames    = Branch.differentNames dupeRefs branch
      successes    = Branch.ours
        $ Branch.diff' branchUpdate (collisions <> duplicates <> dupeRefs)
      mkOutput x =
        uncurry AddOutputComponent $ Branch.intersectWithFile x unisonFile
      allTypeDecls =
        (second Left <$> UF.effectDeclarations' unisonFile)
          `Map.union` (second Right <$> UF.dataDeclarations' unisonFile)
      hashedTerms = UF.hashTerms unisonFile
    in
      do
        forM_ (Map.toList allTypeDecls)
          $ \(_, (r@(DerivedId id), dd)) ->
            when (Branch.contains successes r) $
              Codebase.putTypeDeclaration codebase id dd
        forM_ (Map.toList hashedTerms)
          $ \(_, (r@(DerivedId id), tm, typ)) ->
            when (Branch.contains successes r) $
            -- Discard all line/column info when adding to the codebase
            Codebase.putTerm
              codebase
              id
              (Term.amap (const Parser.External) tm)
              typ
        updated <- Codebase.mergeBranch
          codebase
          branchName
          (Branch.append (successes <> dupeRefs) branch)
        pure $ Added unisonFile
                     updated
                     (mkOutput successes)
                     (mkOutput duplicates)
                     (mkOutput collisions)
                     diffNames
typecheck
  :: (Monad m, Var v)
  => Codebase m v Ann
  -> Names
  -> SourceName
  -> Text
  -> m (TypecheckingResult v)
typecheck codebase names sourceName src =
  Result.getResult $ parseAndSynthesizeFile
    (((<> B.typeLookup) <$>) . Codebase.typeLookupForDependencies codebase)
    names
    (unpack sourceName)
    src

builtinBranch :: Branch
builtinBranch = Branch.append (Branch.fromNames B.names) mempty

newBranch :: Monad m => Codebase m v a -> BranchName -> m Bool
newBranch codebase branchName = forkBranch codebase builtinBranch branchName

forkBranch :: Monad m => Codebase m v a -> Branch -> BranchName -> m Bool
forkBranch codebase branch branchName = do
  ifM (Codebase.branchExists codebase branchName)
      (pure False)
      ((branch ==) <$> Codebase.mergeBranch codebase branchName branch)

mergeBranch :: Monad m => Codebase m v a -> Branch -> BranchName -> m Bool
mergeBranch codebase branch branchName = ifM
  (Codebase.branchExists codebase branchName)
  (Codebase.mergeBranch codebase branchName branch *> pure True)
  (pure False)

data ConstructorSort = Data | Effect deriving (Eq, Ord, Show)

collateReferences
  :: [(Name, Referent)] -- terms requested, including ctors
  -> [(Name, Reference)] -- types requested
  -> ( [(Name, Reference)]
     , [(Reference, Maybe Name, [(Int, Name, ConstructorSort)])]
     )
collateReferences terms types =
  let terms' = [ (n, r) | (n, Referent.Ref r) <- terms ]
      types' = (\(n, r) -> (r, Just n, go r)) <$> types
      go r = foldr (f r) [] terms
      f r' (n, r) ts = case r of
        Referent.Con r i | r == r' -> (i, n, Data) : ts
        Referent.Req r i | r == r' -> (i, n, Effect) : ts
        _                          -> ts
  in  (terms', types')

commandLine
  :: forall i v a
   . Var v
  => IO i
  -> Runtime v
  -> (Branch -> BranchName -> IO ())
  -> (Output v -> IO ())
  -> Codebase IO v Ann
  -> Free (Command i v) a
  -> IO a
commandLine awaitInput rt branchChange notifyUser codebase command = do
  Free.fold go command
 where
  go :: forall x . Command i v x -> IO x
  go = \case
    -- Wait until we get either user input or a unison file update
    Input         -> awaitInput
    Notify output -> notifyUser output
    Add branchName branch unisonFile ->
      addToBranch codebase branchName branch unisonFile
    Typecheck branch sourceName source ->
      typecheck codebase (Branch.toNames branch) sourceName source
    Evaluate branch unisonFile -> do
      selfContained <- Codebase.makeSelfContained codebase branch unisonFile
      Runtime.evaluate rt selfContained codebase
    ListBranches                      -> Codebase.branches codebase
    LoadBranch branchName             -> Codebase.getBranch codebase branchName
    NewBranch  branchName             -> newBranch codebase branchName
    ForkBranch  branch     branchName -> forkBranch codebase branch branchName
    MergeBranch branchName branch     -> mergeBranch codebase branch branchName
    GetConflicts branch               -> pure $ Branch.conflicts' branch
    SwitchBranch branch branchName    -> branchChange branch branchName
    SearchTerms branch queries ->
      Codebase.fuzzyFindTermTypes codebase branch queries
    SearchTypes branch queries ->
      pure $ Codebase.fuzzyFindTypes' branch queries
    LoadTerm _ -> error "todo"
    LoadType _ -> error "todo"

