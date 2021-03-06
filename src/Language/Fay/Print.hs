{-# OPTIONS -fno-warn-orphans #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE TypeSynonymInstances #-}

-- | Simple code (non-pretty) printing.
--
-- No clever printing is done here. If you want pretty printing, use a
-- JS pretty printer. The output should be passed directly to a JS
-- compressor, anyway.
--
-- Special constructors and symbols in Haskell are encoded to
-- JavaScript appropriately.

module Language.Fay.Print where

import Language.Fay.Types

import Data.Aeson.Encode
import qualified Data.ByteString.Lazy.UTF8 as UTF8
import Data.List
import Data.String
import Language.Haskell.Exts.Syntax
import Prelude                      hiding (exp)

--------------------------------------------------------------------------------
-- Printing

-- | Print literals. These need some special encoding for
-- JS-format literals. Could use the Text.JSON library.
instance Printable JsLit where
  printJS (JsChar char)    = UTF8.toString (encode (UTF8.fromString [char]))
  printJS (JsStr str)      = UTF8.toString (encode (UTF8.fromString str))
  printJS (JsInt int)      = show int
  printJS (JsFloating rat) = show rat
  printJS (JsBool b)       = if b then "true" else "false"

-- | Print (and properly encode to JS) a qualified name.
instance Printable QName where
  printJS qname =
    case qname of
      Qual moduleName name -> printJS moduleName ++ "$$" ++ printJS name
      UnQual name -> printJS name
      Special con -> printJS con

-- | Print special constructors (tuples, list, etc.)
instance Printable SpecialCon where
  printJS specialCon =
    case specialCon of
      UnitCon          -> printJS (Qual "Fay" (Ident "unit"))
      ListCon          -> printJS (Qual "Fay" (Ident "emptyList"))
      FunCon           -> printJS (Qual "Fay" (Ident "funCon"))
      TupleCon boxed n -> printJS (Qual "Fay"
                                         (Ident (if boxed == Boxed
                                                    then "boxed"
                                                    else "unboxed" ++
                                                    "TupleOf" ++ show n)))
      Cons             -> printJS (Qual "Fay" (Ident "cons"))
      UnboxedSingleCon -> printJS (Qual "Fay" (Ident "unboxedSingleCon"))

-- | Print module name.
instance Printable ModuleName where
  printJS (ModuleName moduleName) =
    jsEncodeName moduleName

-- | Print (and properly encode) a name.
instance Printable Name where
  printJS name =
    case name of
      Ident ident -> jsEncodeName ident
      Symbol sym -> jsEncodeName sym

-- | Print a list of statements.
instance Printable [JsStmt] where
  printJS = concatMap printJS

-- | Print a single statement.
instance Printable JsStmt where
  printJS (JsBlock stmts) =
    "{ " ++ unwords (map printJS stmts) ++ "}"
  printJS (JsVar name expr) =
    unwords ["var",printJS name,"=",printJS expr ++ ";"]
  printJS (JsUpdate name expr) =
    unwords [printJS name,"=",printJS expr ++ ";"]
  printJS (JsSetProp name prop expr) =
    concat [printJS name,".",printJS prop," = ",printJS expr ++ ";"]
  printJS (JsIf exp thens elses) =
    concat
      [("if (" ++ printJS exp ++ ") {")
      ,printJS thens] ++
      if length elses > 0
         then concat ["} else {"
                     ,printJS elses ++ "}"]
         else "}"
  printJS (JsEarlyReturn exp) =
    "return " ++ printJS exp ++ ";"
  printJS (JsThrow exp) =
    "throw " ++ printJS exp ++ ";"
  printJS (JsWhile cond stmts) =
    unwords ["while (" ++ printJS cond ++ ") {"
            ,printJS stmts
            ,"}"]
  printJS JsContinue = "continue;"

-- | Print an expression.
instance Printable JsExp where
  printJS (JsRawExp name) = name
  printJS (JsThrowExp exp) =
    "(function(){ throw (" ++ printJS exp ++ "); })()"
  printJS (JsFun params stmts ret) =
    concat ["function("
           ,intercalate "," (map (printJS) params)
           ,"){"
           ,printJS stmts
           ] ++
    case ret of
      Just ret' ->
        concat ["return "
               ,printJS ret'
               ,";"
               ,"}"]
      Nothing -> "}"
  printJS JsNull = "null"
  printJS (JsSequence exprs) =
    intercalate "," (map printJS exprs)
  printJS (JsName name) = printJS name
  printJS (JsApp op args) =
    printJS (if isFunc op then JsParen op else op) ++
    "(" ++
    intercalate "," (map (printJS) args) ++
    ")"
     where isFunc JsFun{..} = True; isFunc _ = False
  printJS (JsLit lit) = printJS lit
  printJS (JsParen exp) = "(" ++ printJS exp ++ ")"
  printJS (JsTernaryIf cond conseq alt) =
    concat [printJS cond ++ " ? "
           , printJS conseq ++ " : "
           , printJS alt]
  printJS (JsList exps) =
    "[" ++
    intercalate "," (map printJS exps) ++
    "]"
  printJS (JsNew name args) =
    "new " ++ printJS (JsApp (JsName name) args)
  printJS (JsInstanceOf exp classname) =
    printJS exp ++ " instanceof " ++ printJS classname
  printJS (JsIndex i exp) =
    "(" ++ printJS exp ++ ")[" ++ show i ++ "]"
  printJS (JsEq exp1 exp2) =
    printJS exp1 ++ " === " ++ printJS exp2
  printJS (JsGetProp exp prop) =
    printJS exp ++ "." ++ printJS prop
  printJS (JsLookup exp1 exp2) =
    printJS exp1 ++ "[" ++ printJS exp2 ++ "]"
  printJS (JsUpdateProp name prop expr) =
    concat ["(",printJS name,".",printJS prop," = ",printJS expr,")"]
  printJS (JsInfix op x y) =
    printJS x ++ " " ++ op ++ " " ++ printJS y
  -- Externs: Careful, here be dragons! Or at least warm lizards.
  printJS (JsGetPropExtern exp prop) =
    printJS exp ++ "[" ++ printJS (JsLit (JsStr prop)) ++ "]"
  printJS (JsUpdatePropExtern name prop expr) =
    concat ["(",printJS name,"['",printJS prop,"'] = ",printJS expr,")"]
  printJS (JsObj assoc) =
    concat ["{"
           ,intercalate "," (map cons assoc)
           ,"}"]
     where cons (key,value) = "\"" ++ key ++ "\": " ++ printJS value

--------------------------------------------------------------------------------
-- Utilities

-- Words reserved in haskell as well are not needed here:
-- case, class, do, else, if, import, in, let
reservedWords :: [String]
reservedWords = [
  "break", "catch", "const", "continue", "debugger", "delete", "enum", "export",
  "extends", "finally", "for", "function", "global", "implements", "instanceof",
  "interface", "new", "null", "package", "private", "protected", "public", "return",
  "static", "super", "switch", "this", "throw", "try", "typeof", "undefined",
  "var", "void", "while", "window", "with", "yield"]

-- | Encode a Haskell name to JavaScript.
-- TODO: Fix this hack.
jsEncodeName :: String -> String
-- Special symbols:
jsEncodeName ":tmp" = "$tmp"
jsEncodeName ":thunk" = "$"
jsEncodeName ":this" = "this"
-- jsEncodeName ":return" = "return"
-- Used keywords:
jsEncodeName name
  | "$_" `isPrefixOf` name = normalize name
  | name `elem` reservedWords = "$_" ++ normalize name
-- Anything else.
jsEncodeName name = normalize name

-- | Normalize the given name to JavaScript-valid names.
normalize :: [Char] -> [Char]
normalize name =
  concatMap encodeChar name

  where
    encodeChar c | c `elem` allowed = [c]
                 | otherwise      = escapeChar c
    allowed = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "_"
    escapeChar c = "$" ++ charId c ++ "$"
    charId c = show (fromEnum c)

-- | Helpful for writing qualified symbols (Fay.*).
instance IsString ModuleName where
  fromString = ModuleName

-- | Helpful for writing variable names.
instance IsString JsName where
  fromString = UnQual . Ident
