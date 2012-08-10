{-# LANGUAGE QuasiQuotes, RecordWildCards, OverloadedStrings #-}

module Language.MessagePack.IDL.CodeGen.Erlang (
  Config(..),
  generate,
  ) where

import Data.Char
import Data.List
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.IO as LT
import System.FilePath
import Text.Shakespeare.Text

import Language.MessagePack.IDL.Syntax

data Config
  = Config
    { configFilePath :: FilePath
    }
  deriving (Show, Eq)

generate:: Config -> Spec -> IO ()
generate Config {..} spec = do
  let name = takeBaseName configFilePath
      once = map toUpper name

      headerFile = name ++ "_types.hrl"
  
  LT.writeFile (headerFile) $ templ configFilePath once "TYPES" [lt|
-ifndef(#{once}).
-define(#{once}, 1).

-type mp_string() :: binary().

#{LT.concat $ map (genTypeDecl name) spec }

-endif.
|]

  LT.writeFile (name ++ "_server.tmpl.erl") $ templ configFilePath once "SERVER" [lt|

-module(#{name}_server).
-author('@msgpack-idl').

-include("#{headerFile}").

#{LT.concat $ map genServer spec}
|]

  LT.writeFile (name ++ "_client.erl") [lt|
% This file is automatically generated by msgpack-idl.
-module(#{name}_client).
-author('@msgpack-idl').

-include("#{headerFile}").
-export([connect/3, close/1]).

#{LT.concat $ map genClient spec}
|]

genTypeDecl :: String -> Decl -> LT.Text
genTypeDecl _ MPMessage {..} =
  genMsg msgName msgFields False

genTypeDecl _ MPException {..} =
  genMsg excName excFields True
  
genTypeDecl _ MPType { .. } =
  [lt|
-type #{tyName}() :: #{genType tyType}.
|]

genTypeDecl _ _ = ""

genMsg name flds isExc =
  let fields = map f flds
  in [lt|
-type #{name}() :: [
      #{LT.intercalate "\n    | " fields}
    ]. % #{e}
|]
  where
    e = if isExc then [lt| (exception)|] else ""
    f Field {..} = [lt|#{genType fldType} %  #{fldName}|]

sortField flds =
  flip map [0 .. maximum $ [-1] ++ map fldId flds] $ \ix ->
  find ((==ix). fldId) flds

makeExport i Function {..} = [lt|#{methodName}/#{show $ i + length methodArgs}|]
makeExport _ _ = ""


genServer :: Decl -> LT.Text
genServer MPService {..} = [lt|

-export([#{LT.intercalate ", " $ map (makeExport 0) serviceMethods}]).

#{LT.concat $ map genSetMethod serviceMethods}

|]
  where
    genSetMethod Function {..} =
      let typs = map (genType . maybe TVoid fldType) $ sortField methodArgs
          args = map f methodArgs
          f Field {..} = [lt|#{capitalize0 fldName}|]
          capitalize0 str = T.cons (toUpper $ T.head str) (T.tail str)

      in [lt|
-spec #{methodName}(#{LT.intercalate ", " typs}) -> #{genType methodRetType}.
#{methodName}(#{LT.intercalate ", " args}) ->
  Reply = <<"ok">>,  % write your code here
  Reply.
|]
    genSetMethod _ = ""

genServer _ = ""

genClient :: Decl -> LT.Text
genClient MPService {..} = [lt|

-export([#{LT.intercalate ", " $ map (makeExport 1) serviceMethods}]).

-spec connect(inet:ip_address(), inet:port_number(), [proplists:property()]) -> {ok, pid()} | {error, any()}.
connect(Host,Port,Options)->
    msgpack_rpc_client:connect(tcp,Host,Port,Options).

-spec close(pid())-> ok.
close(Pid)->
    msgpack_rpc_client:close(Pid).

#{LT.concat $ map genMethodCall serviceMethods}
|]
  where
  genMethodCall Function {..} =
      let typs = map (genType . maybe TVoid fldType) $ sortField methodArgs
          args = map f methodArgs
          f Field {..} = [lt|#{capitalize0 fldName}|]
          capitalize0 str = T.cons (toUpper $ T.head str) (T.tail str)
      in [lt|
-spec #{methodName}(pid(), #{LT.intercalate ", " typs}) -> #{genType methodRetType}.
#{methodName}(Pid, #{LT.intercalate ", " args}) ->
    msgpack_rpc_client:call(Pid, #{methodName}, [#{LT.intercalate ", " args}]).
|]
    where
      arg Field {..} = [lt|#{genType fldType} #{fldName}|]
      val Field {..} = [lt|#{fldName}|]

  genMethodCall _ = ""

genClient _ = ""

genType :: Type -> LT.Text
genType (TInt sign bits) =
  let base = if sign then "non_neg_integer" else "integer" :: LT.Text in
  [lt|#{base}()|]
genType (TFloat _) =
  [lt|float()|]
genType TBool =
  [lt|boolean()|]
genType TRaw =
  [lt|binary()|]
genType TString =
  [lt|mp_string()|]
genType (TList typ) =
  [lt|list(#{genType typ})|]
genType (TMap typ1 typ2) =
  [lt|list({#{genType typ1}, #{genType typ2}})|]
genType (TUserDef className params) =
  [lt|#{className}()|]
genType (TTuple ts) =
  -- TODO: FIX
  foldr1 (\t1 t2 -> [lt|{#{t1}, #{t2}}|]) $ map genType ts
genType TObject =
  [lt|term()|]
genType TVoid =
  [lt|void()|]

templ :: FilePath -> String -> String -> LT.Text -> LT.Text
templ filepath once name content = [lt|
% This file is auto-generated from #{filepath}

#{content}|]