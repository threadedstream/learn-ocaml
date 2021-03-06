%token TYPE     "type"
%token VAR      "var"
%token FUNCTION "function"
%token BREAK    "break"
%token OF       "of"
%token END      "end"
%token IN       "in"
%token NIL      "nil" (* nil denotes a value belonging to every record type *)
%token LET      "let"
%token ARRAY    "array"

(* Loops *)
%token DO    "do"
%token TO    "to"
%token FOR   "for"
%token WHILE "while"

(* Conditionals *)
%token IF   "if"
%token THEN "then"
%token ELSE "else"

(* General operators *)
%token ASSIGN ":="

(* Logical *)
%token OR  "|"
%token AND "&"

(* Comparison *)
%token GE  ">="
%token GT  ">"
%token LE  "<="
%token LT  "<"
%token NEQ "<>"
%token EQ  "="

(* Arithmetics *)
%token DIVIDE "/"
%token TIMES  "*"
%token PLUS   "+"
%token MINUS  "-"

(* Separators *)
%token DOT       "."
%token LBRACE    "{"
%token RBRACE    "}"
%token LBRACK    "["
%token RBRACK    "]"
%token LPAREN    "("
%token RPAREN    ")"
%token SEMICOLON ";"
%token COLON     ":"
%token COMMA     ","

(* Strings, Numbers, Indentifiers *)
%token <string> STRING "string"
%token <int>    INT    "int"
%token <string> ID     "id"

(* Other tokens *)
%token EOF

(* Associativity of operators *)
%nonassoc "of"
%nonassoc "then"
%nonassoc "else"
%nonassoc "do"
%nonassoc ":="
%left     "|"
%left     "&"
%nonassoc ">=" ">" "<=" "<" "<>" "="
%left     "+" "-"
%left     "*" "/"

%start <Syntax.expr> main

%{ open Syntax %}
%{ module L = Location %}
%{ module E = Err %}

%%

let main := 
    | ~ = expr; EOF; <>
    | err = loc(error); { E.syntax_error err "" }

let expr := 
    | primitive 
    | nil 
    | break 
    | create_rec 
    | create_arr 
    | var 
    | assignment
    | local 
    | conditional 
    | loop 
    | call 
    | unary 
    | binary 
    | bool 
    | seq 

let nil := 
    ~ = loc("nil"); <Nil>

let break := 
    ~ = loc("break"); <Break>

let primitive :=
    | ~ = loc("string"); <String>
    | ~ = loc("int"); <Int>

let unary := 
    m = loc("-"); e = loc(expr);
    { Op(L.dummy(Int (L.dummy 0)), L.mk Minus m.L.loc, e) }

let binary := 
    ~ = loc(expr); ~ = loc(binary_op); ~ = loc(expr); <Op>

let binary_op :=
    | "+"; { Plus }
    | "-"; { Minus }
    | "*"; { Times }
    | "/"; { Divide }
    | ">="; { Ge }
    | ">"; { Gt }
    | "<="; { Le }
    | "<";  { Lt }
    | "="; { Eq }
    | "<>"; { Neq }

let bool :=
  | l = loc(expr); "&"; r = loc(expr);
    { If(l, r, Some (L.dummy (Int (L.dummy 0)))) }
  | l = loc(expr); "|"; r = loc(expr);
    { If(l, L.dummy (Int (L.dummy 1)), Some r) }

let loop :=
    | while_loop 
    | for_loop

let while_loop := 
    "while"; cond = loc(expr); "do"; body = loc(expr);
    { While(cond, body) }

let for_loop :=
    "for"; i = "id"; ":="; lo = loc(expr);
    "to"; hi = loc(expr); "do"; body = loc(expr);
    { For(L.mk (S.mk i) $loc, lo, hi, body, ref false) }

let conditional := 
    | "if"; cond = loc(expr); "then"; t = loc(expr); "else"; f = loc(expr);
        { If(cond, t, Some f) }
    | "if"; cond = loc(expr); "then"; t = loc(expr);
        { If(cond, t, None) }

let local := 
    "let"; decs = decs; "in"; es = expr_seq; "end";
    { Let(decs, L.mk (Seq es) $loc(es)) }

let decs := 
    ~ = list(dec); <>

let dec := 
    | ~ = loc(var_dec); <VarDec>
    | ~ = dec_ty_fun; <>

let dec_ty_fun := 
    | ~ = nonempty_list(loc(ty_dec)); <TypeDec>
    | ~ = nonempty_list(loc(fun_dec)); <FunDec>

let ty_dec := 
    "type"; type_name = symbol; "="; typ = ty;
    { { type_name; typ } }

let ty := 
    | ~ = delimited("{", ty_fields, "}"); <RecordTy>
    | "array"; "of"; ~ = symbol; <ArrayTy>
    | ~ = symbol; <NameTy>

let ty_fields := 
    ~ = separated_list(",", ty_field); <>

let ty_field := 
    name = symbol; ":"; typ = symbol;
    { { name; typ; escapes = ref false } }

let var_dec := 
    | "var"; var_name = symbol; ":="; init = loc(expr);
    { { var_name; var_typ = None; init; escapes = ref false } }
    | "var"; var_name = symbol; ":"; vt = symbol; ":="; init = loc(expr);
        { { var_name; var_typ = Some vt; init; escapes = ref false } }

let create_rec :=
  typ = symbol; fields = delimited("{", init_rec_fields, "}");
  { Record(typ, fields) }

let create_arr := 
    typ = symbol; size = bracketed(expr); "of"; init = loc(expr);
    { Array(typ, size, init) }

let init_rec_fields :=
  ~ = separated_list(",", init_rec_field); <>

let init_rec_field := 
    name = symbol; "="; e = loc(expr);
    { (name, e) }

let fun_dec := 
    | "function"; fun_name = symbol; params = fun_params; 
    "="; body = loc(expr);
    { { fun_name; params; body; result_typ = None } }
    | "function"; fun_name = symbol; params = fun_params;
    ":"; rt = symbol; "="; body = loc(expr); 
    { { fun_name; params; body; result_typ = Some rt } }

let fun_params := 
    ~ = delimited("(", ty_fields, ")"); <>

let var := 
    ~ = loc(lvalue); <Var>

let lvalue := 
    | ~ = symbol; <SimpleVar>
    | lvalue_complex   

let lvalue_complex := 
    | v = symbol; "."; f = symbol;
     { FieldVar(L.mk (SimpleVar v) v.L.loc, f) }
    | ~ = loc(lvalue_complex); "."; ~ = symbol;
        <FieldVar>
    | s = symbol; e = bracketed(expr);
        { SubscriptVar(L.mk (SimpleVar s) s.L.loc, e) }
    | ~ = loc(lvalue_complex); ~ = bracketed(expr);
        <SubscriptVar>

let symbol :=   
    x = loc("id"); { L.mk (S.mk x.L.value) x.L.loc }

let assignment := 
    ~ = loc(lvalue); ":="; ~ = loc(expr); <Assign>

let expr_seq := 
    ~ = separated_list(";", loc(expr)); <>

let seq := 
    ~ = delimited("(", expr_seq, ")"); <Seq>

let call := 
    ~ = symbol; ~ = delimited("(", fun_args, ")"); <Call>

let fun_args := 
    ~ = separated_list(",", loc(expr)); <>

let loc(t) := 
    ~ = t; { L.mk t $loc }

let bracketed(x) := 
    loc(delimited("[", x, "]"))