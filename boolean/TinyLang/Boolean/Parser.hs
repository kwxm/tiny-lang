{-| A parser for the boolean language.  The concrete syntax is as follows:

  val ::= T | F
  var ::= [a-z][a-z0-9]*

  expr ::= val
           var
           'not' expr
           expr 'and' expr
           expr 'or'  expr
           expr 'xor' expr
           (expr)

  Things like 'and' denote keywords.

  Precedence: 'not' > 'xor' > 'and' > 'or'  (but use parentheses anyway).
  if-then-else has to be parenthesised unless it's at the very top.

  The code is based on the tutorial at
  https://markkarpov.com/megaparsec/parsing-simple-imperative-language.html

  See also https://markkarpov.com/megaparsec/megaparsec.html
-}

-- | TODO: Generate unique names properly when parsing variable names

module TinyLang.Boolean.Parser
    ( parseExpr
    ) where

import           TinyLang.Boolean.Core
import           TinyLang.Prelude               hiding (many, try)
import           TinyLang.Var

import           Control.Monad.Combinators.Expr as E
import           Text.Megaparsec
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer     as L
import           Text.Megaparsec.Error

type Parser = Parsec Void String  -- Void -> No custom error messages

parseExpr :: String -> Either String Expr
parseExpr = first errorBundlePretty . parse top ""

-- The main entry point: parse the whole of an input stream
top :: Parser Expr
top = between ws eof expr

-- A temporary workaround to deal with Uniques
makeVar :: String -> Var
makeVar = Var (Unique 0)

-- Consume whitespace
ws :: Parser ()
ws = L.space space1 empty empty
-- Last two arguments are for comment delimiters.  Let's not have any comments for now.

-- Wrapper to consume whitespace after parsing an item using the wrapped parser
lexeme :: Parser a -> Parser a
lexeme = L.lexeme ws

-- Parse a fixed string
symbol :: String -> Parser String
symbol = L.symbol ws

-- 'parens' parses something between parenthesis.
parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

-- Keywords
keywords :: [String]
keywords = ["T", "F", "not", "and", "or", "xor", "if", "then", "else"]

-- Parse a keyword, checking that it's not a prefix of something else
keyword :: String -> Parser ()
keyword w = (lexeme . try) (string w *> notFollowedBy alphaNumChar)

identifier :: Parser String
identifier =  (lexeme . try) (p >>= check)
    where
      p       = (:) <$> lowerChar <*> many (lowerChar <|> digitChar)
      check x = if x `elem` keywords
                then fail $ "keyword " ++ show x ++ " cannot be an identifier"
                else return x

-- Constants T and F
trueExpr :: Parser Expr
trueExpr =  EVal True <$ keyword "T"

falseExpr :: Parser Expr
falseExpr = EVal False <$ keyword "F"

valExpr :: Parser Expr
valExpr = trueExpr <|> falseExpr


-- Variables
varExpr :: Parser Expr
varExpr = EVar . makeVar <$> identifier


{- Use the Expr combinators from Control.Monad.Combinators.Expr to parse
   epressions involving prefix and infix operators.  This makes it a
   lot easier to get parsing of expressions right. It deals with
   precedence automatically and avoids problems with left recursion
   that may lead to non-terminating parses if you're not careful about
   binary infix expressions.
-}

-- expr1: things that can appear inside operExpr. This does not
-- include operExpr itself, because that would cause infinite recursion.
-- Note that an operExpr doesn't have to contain an operator: it
-- can just be a single expr1.
-- If an ifExpr has to appear inside an operExpr it has to be parenthesised.
expr1 :: Parser Expr
expr1 =  valExpr <|> varExpr <|> parens expr

-- expr: full expressions
expr :: Parser Expr
expr = operExpr <|> ifExpr

-- operExpr: expressions involving unary and binary operators
operExpr :: Parser Expr
operExpr = makeExprParser expr1 operators

operators :: [[E.Operator Parser Expr]]
operators = -- The order here determines operator precedence.
  [ [Prefix (EAppUnOp  Not <$ keyword "not")]
  , [InfixL (EAppBinOp Xor <$ keyword "xor")]
  , [InfixL (EAppBinOp And <$ keyword "and")]
  , [InfixL (EAppBinOp Or  <$ keyword "or")]
  ]

-- if e then r1 else e2
ifExpr :: Parser Expr
ifExpr = EIf <$> (keyword "if" *> expr) <*> (keyword "then" *> expr) <*> (keyword "else" *> expr)