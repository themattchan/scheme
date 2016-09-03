{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
module Eval (
   evalText
  , runParseTest
) where

import Parser
import Text.Parsec
import LispVal

import Data.Text as T
-- key/val store for environment
import Data.Map as Map
import Data.Monoid


import Control.Monad.Except
import Control.Monad.Reader


testEnv :: Map.Map T.Text LispVal
testEnv = Map.fromList $ [("x", Number 42)] <> primEnv

runAppT :: EnvCtx -> Eval b -> ExceptT LispError IO b
runAppT code action = do
    res <- liftIO $ runExceptT $ runReaderT (unEval action) code
    ExceptT $ return $ case res of
      Left b -> Left b
      Right a  -> Right a

-- REPL
evalText :: T.Text -> IO ()
evalText textExpr =
  do
    out <- runExceptT $ runAppT testEnv (textToEval textExpr)
    either print print out

textToEval :: T.Text -> Eval LispVal
textToEval input = either throwError eval (runParse_ input)

runParse_ :: T.Text -> Either LispError LispVal
runParse_ input = case (readExpr input) of
                (Right val) -> Right val
                (Left  err) -> Left $ Default "parser error"

runParseTest :: T.Text -> T.Text
runParseTest input = case (readExpr input) of
                (Right val) -> T.pack $ show val
                (Left  err) -> T.pack $ show err

evalParse :: T.Text -> IO ()
evalParse textExpr =
    print $ runParseTest textExpr

evalInEnv ::LispVal -> Map Text LispVal -> Eval LispVal
evalInEnv exp env = local (const env) (eval exp)

printEnv :: Env -> Eval LispVal
printEnv env = 
 let pairs = toList $ showVal <$> Data.Map.mapKeys showVal  env
 in return $ Atom $ showPairs pairs



setLocal :: Text -> LispVal -> Map Text LispVal -> Eval LispVal
setLocal atom exp env = local (const $ Map.insert atom exp env) (eval exp)

setVar :: LispVal -> LispVal -> Eval LispVal
setVar n@(Atom atom) exp = do
  env <- ask
  case Map.lookup atom env of
      Just x -> setLocal  atom exp env
      Nothing -> throwError $ LispErr $ T.pack "setting an unbound var"
setVar _ exp =
  throwError $ LispErr $ T.pack $ "variables can only be assigned to atoms"

getVar :: LispVal ->  Eval LispVal
getVar n@(Atom atom) = do
  env <- ask
  case Map.lookup atom env of
      Just x -> return x
      Nothing -> throwError $ LispErr $ T.pack $ "error on getVar"
getVar _  =
  throwError $ LispErr $ T.pack $ "variables can only be assigned to atoms"

defineVar :: LispVal -> LispVal -> Eval LispVal
defineVar n@(Atom atom) exp =
  do
    env <- ask
    setLocal atom exp env
defineVar _ exp = throwError $ LispErr $ T.pack "can only bind to Atom type valaues"

-- confirm this evals left to right
-- http://dev.stephendiehl.com/hask/#whats-the-point
bindVars :: [(LispVal, LispVal)] -> Eval ()
bindVars  = sequence_ . fmap (uncurry defineVar)

eval :: LispVal -> Eval LispVal
eval (Number i) = return $ Number i
eval (String s) = return $ String s
eval (Bool b)   = return $ Bool b
eval n@(Atom atom) = getVar n
eval (List [Atom "quote", val]) = return $ List [val]
eval (List [Atom "if", pred,ant,cons]) =
    do env <- ask
       ifRes <- eval pred
       case ifRes of
         (Bool True) -> (eval ant)
         (Bool False) ->  (eval cons)
         _           -> throwError (LispErr $ T.pack "ifelse must by T/F")
-- global definition
eval (List [Atom "def", (Atom val), exp]) =
   defineVar (Atom val) exp
eval (List [Atom "define", (Atom val), exp]) =
   defineVar (Atom val) exp

{-
 - List Comprehension
 -}
evalToList :: LispVal -> Eval [LispVal]
evalToList expr = 
  do 
    val <- eval expr
    case val of
      List x -> return x
      _      -> throwError (LispErr $ T.pack "expect list")
eval (List [Atom "cons", x, xs]) = 
    do xval  <- eval x
       xsval <- evalToList xs
       case xsval of 
         [items] -> return $ List xval:xsval
         _       -> throwError (LispErr $ T.pack "cons second arg must be list"

eval (List [Atom "car", arg]) = 
    do xval <- evalToList arg
       case xval of 
         x:xs -> return $ x
         [x]  -> return $ x
         []         -> throwError (LispErr $ T.pack "car takes a list with one  or more items"

eval (List [Atom "cdr", arg]) = 
    do xval <- evalToList arg
       case xval of 
         x:xs   -> return $ List xs
         [x,y]  -> return $ List [y]
         _      -> throwError (LispErr $ T.pack "cdr takes a list with two  or more items"
letPairs :: [LispVal] -> Eval ()
letPairs x = 
  case x of
    []        -> throwError (LispErr $ T.pack "let")
    [one]     -> throwError (LispErr $ T.pack "let")
    [a:as]    -> bindVars $ zipWith (\a b -> (x !! a, x !! b))  (filter even [0..(length x - 1)]) $ filter odd [0..(length x -1)]

eval (List [Atom "let", pairs, expr]) = 
    do x <- evalToList pairs
       letPairs x
       eval expr

eval (List [Atom "lambda", params, expr]) = 
    envLocal <- ask
    paramsEvald <- evalToList params
    return $ Lambda ([args] -> (bindVars $ zipWith (,) paramsEvald args) >> eval expr) envLocal 
                         

eval (List fn:args) =
  do
    fnVariable <- getVar fn
    argsEval <- evalToList args
    case fnVariable of
      (Fun ( IFunc internalFn)) -> internalFn argsEval
      (Lambda (IFunc internalFn) boundEnv) -> local (const boundEnv) (internalFn argsEval) 
      _                -> throwError $ NotFunction "function" "not found???"
--

-- TODO: make internal form for primative
-- add two numbers
type Prim = [(T.Text, LispVal)]

primEnv :: Prim
primEnv = [   ("+", Fun $ IFunc $ binop $ numOp (+))
            , ("-", Fun $ IFunc $ binop $ numOp (-))
            , ("*", Fun $ IFunc $ binop $ numOp (*))
            , ("++", Fun $ IFunc $ binopFold $ strOp (++))
            ]


type Unary = LispVal -> Eval LispVal
type Binary = LispVal -> LispVal -> Eval LispVal

binop :: Binary -> [LispVal] -> Eval LispVal
binop op args@[x,y] = case args of
                            [a,b] -> op a b
                            _ -> throwError $ NumArgs 2 args

binopFold :: Binary -> [LispVal] -> Eval LispVal
binopFold op args = case args of
                            [a,b] -> op a b
                            [a:as] -> foldl1 op args
                            []-> throwError $ NumArgs 2 args

numOp :: (Integer -> Integer -> Integer) -> LispVal -> LispVal -> Eval LispVal
numOp op (Number x) (Number y) = return $ Number $ op x  y
numOp op _          _          = throwError $ TypeMismatch "+" (String "Number")

strOp :: (T.Text -> T.Text -> T.Text) -> LispVal -> LispVal -> Eval LispVal
strOp op (String x) (String y) = return $ String $ op x y
strOp op _          _          =  throwError $ TypeMismatch "+" (String "String")

-- default return to Eval monad (no error handling)
binopFixPoint :: (LispVal -> LispVal -> LispVal) -> [LispVal] -> Eval LispVal
binopFixPoint f2 = binop $ (\x y -> return $ f2 x y)

numOpVal :: (Integer -> Integer -> Integer ) -> LispVal -> LispVal -> LispVal
numOpVal op (Number x) (Number y) = Number $ op x  y

