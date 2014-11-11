{-# LANGUAGE TupleSections #-}

module Cobalt.Language.Parser (
  parseTerm
, parsePolyType
, parseClosedPolyType
, parseMonoType
, parseSig
, parseData
, parseAxiom
, parseDefn
, parseFile
) where

import Control.Applicative hiding (many)
import Text.Parsec hiding ((<|>))
import Text.Parsec.Language
import qualified Text.Parsec.Token as T
import Unbound.LocallyNameless

import Cobalt.Language.Syntax
import Cobalt.Types

parseTerm :: Parsec String s RawTerm
parseTerm = parseAtom `chainl1` (pure (\x y -> Term_App x y ()))

parseAtom :: Parsec String s RawTerm
parseAtom = -- Parenthesized expression
            parens parseTerm
        <|> -- Type annotated abstraction
            try (createTermAbsAnn <$  reservedOp "\\"
                                  <*> parens ((,) <$> identifier
                                                  <*  reservedOp "::"
                                                  <*> parseClosedPolyType)
                                  <*  reservedOp "->"
                                  <*> parseTerm)
        <|> -- Abstraction
            createTermAbs <$  reservedOp "\\"
                          <*> identifier
                          <*  reservedOp "->"
                          <*> parseTerm
        <|> -- Type annotated let
            try (createTermLetAbs <$  reserved "let"
                                  <*> identifier
                                  <*  reservedOp "::"
                                  <*> parseClosedPolyType
                                  <*  reservedOp "="
                                  <*> parseTerm
                                  <*  reserved "in"
                                  <*> parseTerm)
        <|> -- Let
            createTermLet <$  reserved "let"
                          <*> identifier
                          <*  reservedOp "="
                          <*> parseTerm
                          <*  reserved "in"
                          <*> parseTerm
        <|> -- Case
            Term_Match <$  reserved "match"
                       <*> parseTerm
                       <*  reserved "with"
                       <*> parseDataName
                       <*> many parseCaseAlternative
                       <*> pure ()
        <|> -- Literal
            Term_IntLiteral <$> integer <*> pure ()
        <|> -- Variable
            Term_Var . string2Name <$> identifier <*> pure ()

parseCaseAlternative :: Parsec String s (RawTermVar, Bind [RawTermVar] RawTerm)
parseCaseAlternative = createCaseAlternative <$  reservedOp "|"
                                             <*> identifier
                                             <*> many identifier
                                             <*  reservedOp "->"
                                             <*> parseTerm

createTermAbsAnn :: (String, PolyType) -> RawTerm -> RawTerm
createTermAbsAnn (x,t) e = Term_AbsAnn (bind (string2Name x) e) t ()

createTermAbs :: String -> RawTerm -> RawTerm
createTermAbs x e = Term_Abs (bind (string2Name x) e) ()

createTermLetAbs :: String -> PolyType -> RawTerm -> RawTerm -> RawTerm
createTermLetAbs x t e1 e2 = Term_LetAnn (bind (string2Name x, embed e1) e2) t ()

createTermLet :: String -> RawTerm -> RawTerm -> RawTerm
createTermLet x e1 e2 = Term_Let (bind (string2Name x, embed e1) e2) ()

createCaseAlternative :: String -> [String] -> RawTerm -> (RawTermVar, Bind [RawTermVar] RawTerm)
createCaseAlternative con args e = (string2Name con, bind (map string2Name args) e)

parsePolyType :: Parsec String s PolyType
parsePolyType = nf <$> parsePolyType'

parsePolyType' :: Parsec String s PolyType
parsePolyType' = createPolyTypeBind <$> braces identifier
                                    <*> parsePolyType'
             <|> try (PolyType_Mono <$> parseConstraint `sepBy1` comma
                                    <*  reservedOp "=>"
                                    <*> parseMonoType)
             <|> PolyType_Bottom <$ reservedOp "_|_"
             <|> PolyType_Mono [] <$> parseMonoType

parseClosedPolyType :: Parsec String s PolyType
parseClosedPolyType = do t <- parsePolyType
                         if null $ fvAny t
                            then return t
                            else fail "Closed type expected"

createPolyTypeBind :: String -> PolyType -> PolyType
createPolyTypeBind x p = PolyType_Bind $ bind (string2Name x) p

parseConstraint :: Parsec String s Constraint
parseConstraint = try (Constraint_Inst  <$> (var . string2Name <$> identifier)
                                        <*  reservedOp ">"
                                        <*> parsePolyType)
              <|> try (Constraint_Equal <$> (var . string2Name <$> identifier)
                                        <*  reservedOp "="
                                        <*> parsePolyType)
              <|> Constraint_Class <$> parseClsName
                                   <*> many parseMonoType
              <|> Constraint_Unify <$> parseMonoType
                                   <*  reservedOp "~"
                                   <*> parseMonoType

parseMonoType :: Parsec String s MonoType
parseMonoType = foldr1 MonoType_Arrow <$> parseMonoAtom `sepBy1` reservedOp "->"

parseMonoAtom :: Parsec String s MonoType
parseMonoAtom = MonoType_List <$> brackets parseMonoType
            <|> try (uncurry MonoType_Tuple <$>
                       parens ((,) <$> parseMonoType
                                   <*  comma
                                   <*> parseMonoType))
            <|> parens parseMonoType
            <|> MonoType_Con <$> parseDataName
                             <*> many (    (\x -> MonoType_Con x []) <$> parseDataName
                                       <|> (\x -> MonoType_Fam x []) <$> parseFamName
                                       <|> MonoType_List <$> brackets parseMonoType
                                       <|> MonoType_Var . string2Name <$> identifier
                                       <|> parens parseMonoType)
            <|> MonoType_Fam <$> parseFamName
                             <*> many (    (\x -> MonoType_Con x []) <$> parseDataName
                                       <|> (\x -> MonoType_Fam x []) <$> parseFamName
                                       <|> MonoType_List <$> brackets parseMonoType
                                       <|> MonoType_Var . string2Name <$> identifier
                                       <|> parens parseMonoType)
            <|> MonoType_Var . string2Name <$> identifier

parseDataName :: Parsec String s String
parseDataName = id <$ char '\'' <*> identifier

parseFamName :: Parsec String s String
parseFamName = id <$ char '^' <*> identifier

parseClsName :: Parsec String s String
parseClsName = id <$ char '$' <*> identifier

parseSig :: Parsec String s (RawTermVar, PolyType)
parseSig = (,) <$  reserved "import"
               <*> (string2Name <$> identifier)
               <*  reservedOp "::"
               <*> parsePolyType
               <*  reservedOp ";"

parseData :: Parsec String s (String,[TyVar])
parseData = (,) <$  reserved "data"
                <*> parseDataName
                <*> many (string2Name <$> identifier)
                <*  reservedOp ";"

parseAxiom :: Parsec String s Axiom
parseAxiom = id <$ reserved "axiom"
                <*> (    try (createAxiomUnify <$> many (braces identifier)
                                               <*> parseMonoType
                                               <*  reservedOp "~"
                                               <*> parseMonoType)
                     
                     <|> try (createAxiomClass <$> many (braces identifier)
                                               <*> many parseConstraint
                                               <*  reservedOp "=>"
                                               <*> parseClsName
                                               <*> many parseMonoType)
                     <|> flip createAxiomClass [] <$> many (braces identifier)
                                                  <*> parseClsName
                                                  <*> many parseMonoType )
                <* reservedOp ";"

createAxiomUnify :: [String] -> MonoType -> MonoType -> Axiom
createAxiomUnify vs r l = Axiom_Unify (bind (map string2Name vs) (r,l))

createAxiomClass :: [String] -> [Constraint] -> String -> [MonoType] -> Axiom
createAxiomClass vs ctx c m = Axiom_Class (bind (map string2Name vs) (ctx,c,m))

parseDefn :: Parsec String s (RawDefn,Bool)
parseDefn = buildDefn
                <$> many1 identifier
                <*> (    try (Just <$  reservedOp "::"
                                   <*> parsePolyType)
                     <|> pure Nothing)
                <*  reservedOp "="
                <*> parseTerm
                <*> parseExpected
                <*  reservedOp ";"

buildDefn :: [String] -> Maybe PolyType -> RawTerm -> Bool -> (RawDefn,Bool)
buildDefn [] _ _ _ = error "This should never happen"
buildDefn (n:args) ty tr ex = let finalTerm = foldr createTermAbs tr args
                               in ((string2Name n,finalTerm,ty),ex)

parseExpected :: Parsec String s Bool
parseExpected = try (id <$ reservedOp "=>" <*> (    const True  <$> reservedOp "ok"
                                                <|> const False <$> reservedOp "fail"))
            <|> pure True

data DeclType = AData   (String, [TyVar])
              | AnAxiom Axiom
              | ASig    (RawTermVar, PolyType)
              | ADefn   (RawDefn, Bool)

parseDecl :: Parsec String s DeclType
parseDecl = AData   <$> parseData
        <|> AnAxiom <$> parseAxiom
        <|> ASig    <$> parseSig
        <|> ADefn   <$> parseDefn

buildProgram :: [DeclType] -> (Env, [(RawDefn,Bool)])
buildProgram = foldr (\decl (Env s d a, df) -> case decl of
                        AData i   -> (Env s (i:d) a, df)
                        AnAxiom i -> (Env s d (i:a), df)
                        ASig i    -> (Env (i:s) d a, df)
                        ADefn i   -> (Env s d a, (i:df)))
                     (Env [] [] [], [])

parseFile :: Parsec String s (Env,[(RawDefn,Bool)])
parseFile = buildProgram <$> many parseDecl

-- Lexer for Haskell-like language

lexer :: T.TokenParser t
lexer = T.makeTokenParser $ haskellDef { T.reservedNames = "with" : T.reservedNames haskellDef }

parens :: Parsec String s a -> Parsec String s a
parens = T.parens lexer

braces :: Parsec String s a -> Parsec String s a
braces = T.braces lexer

brackets :: Parsec String s a -> Parsec String s a
brackets = T.brackets lexer

comma :: Parsec String s String
comma = T.comma lexer

identifier :: Parsec String s String
identifier = T.identifier lexer

reserved :: String -> Parsec String s ()
reserved = T.reservedOp lexer

reservedOp :: String -> Parsec String s ()
reservedOp = T.reservedOp lexer

integer :: Parsec String s Integer
integer = T.integer lexer