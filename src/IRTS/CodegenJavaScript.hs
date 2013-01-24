{-# LANGUAGE PatternGuards #-}

module IRTS.CodegenJavaScript (codegenJavaScript) where

import Idris.AbsSyntax
import IRTS.Bytecode
import IRTS.Lang
import IRTS.Simplified
import IRTS.CodegenCommon
import Core.TT
import Paths_idris
import Util.System

import Control.Arrow
import Data.Char
import Data.List
import qualified Data.Map as Map
import System.IO

type NamespaceName = String
type Decl = ([String], SDecl)

data ModuleTree = Module { moduleName :: String
                     , functions  :: [SDecl]
                     , subModules :: Map.Map String ModuleTree
                     }
            | EmptyModule

insertDecl :: ModuleTree -> Decl -> ModuleTree
insertDecl EmptyModule ([modname], decl) =
  Module modname [decl] Map.empty

insertDecl EmptyModule (m:s:ms, decl) =
  Module m [] (Map.singleton s (insertDecl EmptyModule (s:ms, decl)))

insertDecl mod ([modname], decl)
  | moduleName mod == modname =
    mod { functions = decl : functions mod }

insertDecl mod (_:m:ms, decl)
  |  Nothing <- Map.lookup m (subModules mod) =
       mod {
         subModules =
           Map.insert m (insertDecl EmptyModule (m:ms, decl)) (subModules mod)
       }
  | Just s <- Map.lookup m (subModules mod) =
    mod {
      subModules =
        Map.insert m (insertDecl s (m:ms, decl)) (subModules mod)
    }

instance Show ModuleTree where
  show EmptyModule = ""
  show (Module name fs subs) =
    createModule Nothing name body
    where
      functions  = concatMap (translateDeclaration name) fs
      submodules = Map.foldWithKey (translateSubModule name) "" subs
      body       = functions ++ submodules

      translateSubModule toplevel name mod js =
        js ++ show mod ++ toplevel ++ "." ++ name ++ "=" ++ name ++ ";"

idrNamespace :: NamespaceName
idrNamespace = "__IDR__"

codegenJavaScript
  :: [(Name, SDecl)]
  -> FilePath
  -> OutputType
  -> IO ()
codegenJavaScript definitions filename outputType = do
  path <- getDataDir
  idrRuntime <- readFile (path ++ "/js/Runtime.js")
  writeFile filename (idrRuntime ++ output)
  where
    modules = foldl' insertDecl EmptyModule def
    def = map (first translateNamespace) definitions

    mainLoop :: String
    mainLoop = intercalate "\n" [ "\nfunction main() {"
                                , createTailcall "__IDR__.runMain0()"
                                , "}\n\nmain();\n"
                                ]

    output :: String
    output = show modules ++ mainLoop

createModule :: Maybe String -> NamespaceName -> String -> String
createModule toplevel modname body =
  concat [header modname, body, footer modname]
  where
    header :: NamespaceName -> String
    header modname =
      concatMap (++ "\n")
        [ "\nvar " ++ modname ++ ";"
        , "(function(" ++ modname ++ "){"
        ]

    footer :: NamespaceName -> String
    footer modname =
      let m = maybe "" (++ ".") toplevel ++ modname in
         "\n})("
      ++ m
      ++ " || ("
      ++ m
      ++ " = {})"
      ++ ");\n"

translateModule :: Maybe String -> ([String], SDecl) -> String
translateModule toplevel ([modname], decl) =
  let body = translateDeclaration modname decl in
      createModule toplevel modname body
translateModule toplevel (n:ns, decl) =
  createModule toplevel n $ translateModule (Just n) (ns, decl)

translateIdentifier :: String -> String
translateIdentifier =
  concatMap replaceBadChars
  where replaceBadChars :: Char -> String
        replaceBadChars ' '  = "_"
        replaceBadChars '_'  = "__"
        replaceBadChars '@'  = "_at"
        replaceBadChars '['  = "_OSB"
        replaceBadChars ']'  = "_CSB"
        replaceBadChars '('  = "_OP"
        replaceBadChars ')'  = "_CP"
        replaceBadChars '{'  = "_OB"
        replaceBadChars '}'  = "_CB"
        replaceBadChars '!'  = "_bang"
        replaceBadChars '#'  = "_hash"
        replaceBadChars '.'  = "_dot"
        replaceBadChars ','  = "_comma"
        replaceBadChars ':'  = "_colon"
        replaceBadChars '+'  = "_plus"
        replaceBadChars '-'  = "_minus"
        replaceBadChars '*'  = "_times"
        replaceBadChars '<'  = "_lt"
        replaceBadChars '>'  = "_gt"
        replaceBadChars '='  = "_eq"
        replaceBadChars '|'  = "_pipe"
        replaceBadChars '&'  = "_amp"
        replaceBadChars '/'  = "_SL"
        replaceBadChars '\\' = "_BSL"
        replaceBadChars '%'  = "_per"
        replaceBadChars '?'  = "_que"
        replaceBadChars '~'  = "_til"
        replaceBadChars '\'' = "_apo"
        replaceBadChars c
          | isDigit c = "_" ++ [c] ++ "_"
          | otherwise = [c]

translateNamespace :: Name -> [String]
translateNamespace (UN _)    = [idrNamespace]
translateNamespace (NS _ ns) = idrNamespace : map translateIdentifier ns
translateNamespace (MN _ _)  = [idrNamespace]

translateName :: Name -> String
translateName (UN name)   = translateIdentifier name
translateName (NS name _) = translateName name
translateName (MN i name) = translateIdentifier name ++ show i

translateQualifiedName :: Name -> String
translateQualifiedName name =
  intercalate "." (translateNamespace name) ++ "." ++ translateName name

translateConstant :: Const -> String
translateConstant (I i)   = show i
translateConstant (BI i)  = "__IDR__.bigInt('" ++ show i ++ "')"
translateConstant (Fl f)  = show f
translateConstant (Ch c)  = show c
translateConstant (Str s) = show s
translateConstant IType   = "__IDR__.Int"
translateConstant ChType  = "__IDR__.Char"
translateConstant StrType = "__IDR__.String"
translateConstant BIType  = "__IDR__.Integer"
translateConstant FlType  = "__IDR__.Float"
translateConstant Forgot  = "__IDR__.Forgot"
translateConstant c       =
  "(function(){throw 'Unimplemented Const: " ++ show c ++ "';})()"

translateParameterlist =
  map translateParameter
  where translateParameter (MN i name) = name ++ show i
        translateParameter (UN name) = name

translateDeclaration :: NamespaceName -> SDecl -> String
translateDeclaration modname (SFun name params stackSize body) =
     modname
  ++ "."
  ++ translateName name
  ++ " = function("
  ++ intercalate "," p
  ++ "){\n"
  ++ concatMap assignVar (zip [0..] p)
  ++ concatMap allocVar [numP..(numP+stackSize-1)]
  ++ "return "
  ++ translateExpression modname body
  ++ ";\n};\n"
  where 
    numP :: Int
    numP = length params

    allocVar :: Int -> String
    allocVar n = "var __var_" ++ show n ++ ";\n"

    assignVar :: (Int, String) -> String
    assignVar (n, s) = "var __var_" ++ show n ++ " = " ++ s ++ ";\n"

    p :: [String]
    p = translateParameterlist params

translateVariableName :: LVar -> String
translateVariableName (Loc i) =
  "__var_" ++ show i

translateExpression :: NamespaceName -> SExp -> String
translateExpression modname (SLet name value body) =
     "(function("
  ++ translateVariableName name
  ++ "){\nreturn "
  ++ translateExpression modname body
  ++ ";\n})("
  ++ translateExpression modname value
  ++ ")"

translateExpression _ (SConst cst) =
  translateConstant cst

translateExpression _ (SV var) =
  translateVariableName var

translateExpression modname (SApp False name vars) =
  createTailcall $ translateFunctionCall name vars

translateExpression modname (SApp True name vars) =
     "new __IDR__.Tailcall("
  ++ "function(){\n"
  ++ "return " ++ translateFunctionCall name vars
  ++ ";\n});"

translateExpression _ (SOp op vars)
  | LPlus       <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "+" lhs rhs
  | LMinus      <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "-" lhs rhs
  | LTimes      <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "*" lhs rhs
  | LDiv        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "/" lhs rhs
  | LMod        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "%" lhs rhs
  | LEq         <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "==" lhs rhs
  | LLt         <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "<" lhs rhs
  | LLe         <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "<=" lhs rhs
  | LGt         <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ">" lhs rhs
  | LGe         <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ">=" lhs rhs
  | LAnd        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "&" lhs rhs
  | LOr         <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "|" lhs rhs
  | LXOr        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "^" lhs rhs
  | LSHL        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "<<" rhs lhs
  | LSHR        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ">>" rhs lhs
  | LCompl      <- op
  , (arg:_)     <- vars = '~' : translateVariableName arg

  | LBPlus      <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".add(" lhs rhs  ++ ")"
  | LBMinus     <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".minus(" lhs rhs ++ ")"
  | LBTimes     <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".times(" lhs rhs ++ ")"
  | LBDiv       <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".divide(" lhs rhs ++ ")"
  | LBMod       <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".mod(" lhs rhs ++ ")"
  | LBEq        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".equals(" lhs rhs ++ ")"
  | LBLt        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".lesser(" lhs rhs ++ ")"
  | LBLe        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".lesserOrEquals(" lhs rhs ++ ")"
  | LBGt        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".greater(" lhs rhs ++ ")"
  | LBGe        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ".greaterOrEquals(" lhs rhs ++ ")"

  | LFPlus      <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "+" lhs rhs
  | LFMinus     <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "-" lhs rhs
  | LFTimes     <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "*" lhs rhs
  | LFDiv       <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "/" lhs rhs
  | LFEq        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "==" lhs rhs
  | LFLt        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "<" lhs rhs
  | LFLe        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "<=" lhs rhs
  | LFGt        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ">" lhs rhs
  | LFGe        <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp ">=" lhs rhs

  | LStrConcat  <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "+" lhs rhs
  | LStrEq      <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "==" lhs rhs
  | LStrLt      <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "<" lhs rhs
  | LStrLen     <- op
  , (arg:_)     <- vars = translateVariableName arg ++ ".length"

  | LStrInt     <- op
  , (arg:_)     <- vars = "parseInt(" ++ translateVariableName arg ++ ")"
  | LIntStr     <- op
  , (arg:_)     <- vars = "String(" ++ translateVariableName arg ++ ")"
  | LIntBig     <- op
  , (arg:_)     <- vars = "__IDR__.bigInt(" ++ translateVariableName arg ++ ")"
  | LBigInt     <- op
  , (arg:_)     <- vars = translateVariableName arg ++ ".valueOf()"
  | LBigStr     <- op
  , (arg:_)     <- vars = translateVariableName arg ++ ".toString()"
  | LStrBig     <- op
  , (arg:_)     <- vars = "__IDR__.bigInt(" ++ translateVariableName arg ++ ")"
  | LFloatStr   <- op
  , (arg:_)     <- vars = "String(" ++ translateVariableName arg ++ ")"
  | LStrFloat   <- op
  , (arg:_)     <- vars = "parseFloat(" ++ translateVariableName arg ++ ")"
  | LIntFloat   <- op
  , (arg:_)     <- vars = translateVariableName arg
  | LFloatInt   <- op
  , (arg:_)     <- vars = translateVariableName arg
  | LChInt      <- op
  , (arg:_)     <- vars = translateVariableName arg ++ ".charCodeAt(0)"
  | LIntCh      <- op
  , (arg:_)     <- vars =
    "String.fromCharCode(" ++ translateVariableName arg ++ ")"

  | LFExp       <- op
  , (arg:_)     <- vars = "Math.exp(" ++ translateVariableName arg ++ ")"
  | LFLog       <- op
  , (arg:_)     <- vars = "Math.log(" ++ translateVariableName arg ++ ")"
  | LFSin       <- op
  , (arg:_)     <- vars = "Math.sin(" ++ translateVariableName arg ++ ")"
  | LFCos       <- op
  , (arg:_)     <- vars = "Math.cos(" ++ translateVariableName arg ++ ")"
  | LFTan       <- op
  , (arg:_)     <- vars = "Math.tan(" ++ translateVariableName arg ++ ")"
  | LFASin      <- op
  , (arg:_)     <- vars = "Math.asin(" ++ translateVariableName arg ++ ")"
  | LFACos      <- op
  , (arg:_)     <- vars = "Math.acos(" ++ translateVariableName arg ++ ")"
  | LFATan      <- op
  , (arg:_)     <- vars = "Math.atan(" ++ translateVariableName arg ++ ")"
  | LFSqrt      <- op
  , (arg:_)     <- vars = "Math.sqrt(" ++ translateVariableName arg ++ ")"
  | LFFloor     <- op
  , (arg:_)     <- vars = "Math.floor(" ++ translateVariableName arg ++ ")"
  | LFCeil      <- op
  , (arg:_)     <- vars = "Math.ceil(" ++ translateVariableName arg ++ ")"

  | LStrCons    <- op
  , (lhs:rhs:_) <- vars = translateBinaryOp "+" lhs rhs
  | LStrHead    <- op
  , (arg:_)     <- vars = translateVariableName arg ++ "[0]"
  | LStrRev     <- op
  , (arg:_)     <- vars = let v = translateVariableName arg in
                              v ++ "split('').reverse().join('')"
  | LStrIndex   <- op
  , (lhs:rhs:_) <- vars = let l = translateVariableName lhs
                              r = translateVariableName rhs in
                              l ++ "[" ++ r ++ "]"
  | LStrTail    <- op
  , (arg:_)     <- vars = let v = translateVariableName arg in
                              v ++ ".substr(1," ++ v ++ ".length-1)"
  where
    translateBinaryOp :: String -> LVar -> LVar -> String
    translateBinaryOp f lhs rhs =
         translateVariableName lhs
      ++ f
      ++ translateVariableName rhs

translateExpression _ (SError msg) =
  "(function(){throw \'" ++ msg ++ "\';})();"

translateExpression _ (SForeign _ _ "putStr" [(FString, var)]) =
  "__IDR__.print(" ++ translateVariableName var ++ ");"

translateExpression _ (SForeign _ _ fun args) =
     fun
  ++ "("
  ++ intercalate "," (map (translateVariableName . snd) args)
  ++ ");"

translateExpression modname (SChkCase var cases) =
     "(function(e){\n"
  ++ intercalate " else " (map (translateCase modname "e") cases)
  ++ "\n})("
  ++ translateVariableName var
  ++ ")"

translateExpression modname (SCase var cases) = 
     "(function(e){\n"
  ++ intercalate " else " (map (translateCase modname "e") cases)
  ++ "\n})("
  ++ translateVariableName var
  ++ ")"

translateExpression _ (SCon i name vars) =
  concat [ "new __IDR__.Con("
         , show i
         , ","
         , '\'' : translateQualifiedName name ++ "\',["
         , intercalate "," $ map translateVariableName vars
         , "])"
         ]

translateExpression modname (SUpdate var e) =
  translateVariableName var ++ " = " ++ translateExpression modname e

translateExpression modname (SProj var i) =
  translateVariableName var ++ ".vars[" ++ show i ++"]"

translateExpression _ SNothing = "null"

translateExpression _ e =
     "(function(){throw 'Not yet implemented: "
  ++ filter (/= '\'') (show e)
  ++ "';})()"

translateCase :: String -> String -> SAlt -> String
translateCase modname _ (SDefaultCase e) =
  createIfBlock "true" (translateExpression modname e)

translateCase modname var (SConstCase ty e)
  | ChType   <- ty = matchHelper "Char"
  | StrType  <- ty = matchHelper "String"
  | IType    <- ty = matchHelper "Int"
  | BIType   <- ty = matchHelper "Integer"
  | FlType   <- ty = matchHelper "Float"
  | Forgot   <- ty = matchHelper "Forgot"
  where
    matchHelper tyName = translateTypeMatch modname var tyName e

translateCase modname var (SConstCase cst@(BI _) e) =
  let cond = var ++ ".equals(" ++ translateConstant cst ++ ")" in
      createIfBlock cond (translateExpression modname e)

translateCase modname var (SConstCase cst e) =
  let cond = var ++ " == " ++ translateConstant cst in
      createIfBlock cond (translateExpression modname e)

translateCase modname var (SConCase a i name vars e) =
  let isCon = var ++ " instanceof __IDR__.Con"
      isI = show i ++ " == " ++ var ++ ".i"
      params = intercalate "," $ map (("__var_" ++) . show) [a..(a+length vars)]
      args = ".apply(this," ++ var ++ ".vars)"
      f b =
           "(function("
        ++ params 
        ++ "){\nreturn " ++ b ++ "\n})" ++ args
      cond = intercalate " && " [isCon, isI] in
      createIfBlock cond $ f (translateExpression modname e)

translateTypeMatch :: String -> String -> String -> SExp -> String
translateTypeMatch modname var ty exp =
  let e = translateExpression modname exp in
      createIfBlock (var
                  ++ " instanceof __IDR__.Type && "
                  ++ var ++ ".type == '"++ ty ++"'") e


createIfBlock cond e =
     "if (" ++ cond ++") {\n"
  ++ "return " ++ e
  ++ ";\n}"

createTailcall call =
  "__IDR__.tailcall(function(){return " ++ call ++ "})"

translateFunctionCall name vars =
     concat (intersperse "." $ translateNamespace name)
  ++ "."
  ++ translateName name
  ++ "("
  ++ intercalate "," (map translateVariableName vars)
  ++ ")"
