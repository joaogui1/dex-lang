-- Copyright 2019 Google LLC
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

{-# LANGUAGE OverloadedStrings #-}

module Flops (flopsPass) where

import Control.Monad.Reader
import Control.Monad.Writer
import qualified Data.Map.Strict as M
import Data.Text.Prettyprint.Doc hiding (group)

import Syntax
import Env
import Pass
import PPrint

data Term = Term Int [(Name, Int)]  deriving (Show, Eq, Ord)
type Count = [Term]
newtype Profile = Profile (M.Map Builtin Count)

type FlopM a = ReaderT Term (Writer Profile) a

flopsPass :: TopPass ImpDecl ImpDecl
flopsPass = TopPass flopsPass'

flopsPass' :: ImpDecl -> TopPassM () ImpDecl
flopsPass' (ImpEvalCmd _ _ (Command Flops prog)) = do
  let ans = snd $ runWriter (runReaderT (flops prog) (litTerm 1))
  emitOutput $ TextOut $ pprint ans
flopsPass' decl = return decl

flops :: ImpProg -> FlopM ()
flops (ImpProg []) = return ()
flops (ImpProg (statement:rest)) = do
  statementFlops statement
  flops (ImpProg rest)

statementFlops :: Statement -> FlopM ()
statementFlops statement = case statement of
  Alloc _ body -> flops body  -- TODO: count memory allocation
  Update _ _ b _ _ -> do
    n <- ask
    tell $ Profile $ M.singleton b [n]
  Loop _ size block -> do
    let n = evalSizeExpr  size
    local (mulTerm n) $ flops block

evalSizeExpr :: IExpr -> Term
evalSizeExpr (ILit (IntLit n)) = litTerm n
evalSizeExpr (IVar v) = varTerm v
evalSizeExpr expr = error $ "Not implemented: " ++ pprint expr

litTerm :: Int -> Term
litTerm n = Term n []

varTerm :: Name -> Term
varTerm v = Term 1 [(v, 1)]

mulTerm :: Term -> Term -> Term
mulTerm (Term n xs) (Term  n' xs') = Term (n * n') (xs <> xs')

canonicalizeCount :: Count -> Count
canonicalizeCount terms =
  let terms' = groupReduce (+) [(term, coeff) |
                                Term coeff term <- map canonicalizeTerm terms]
  in [Term coeff term | (term, coeff) <- terms']

canonicalizeTerm :: Term -> Term
canonicalizeTerm (Term coeff term) = Term coeff (groupReduce (+) term)

prettyCount :: Count -> Doc ann
prettyCount terms =
  hsep $ punctuate " +" $ map pretty terms'
  where terms' = canonicalizeCount terms

groupReduce :: Ord a => (b -> b -> b) -> [(a,b)] -> [(a,b)]
groupReduce f pairs = M.toAscList $ foldr (M.unionWith f) mempty $
                        map (uncurry M.singleton) pairs

instance Semigroup Profile where
  Profile m <> Profile m' = Profile $ M.unionWith (<>) m m'

instance Monoid Profile where
  mempty = Profile mempty
  mappend = (<>)

instance Pretty Profile where
  pretty (Profile m) = vsep $ [pretty b <+> prettyCount c
                              | (b, c) <- M.toAscList m]

instance Pretty Term where
  pretty (Term coeff term) = pretty coeff <+>
                             hsep ([pretty v <> "^" <> pretty pow | (v, pow) <- term])
