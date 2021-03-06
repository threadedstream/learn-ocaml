open Core_kernel 
open Err 

module T = Type 
module Tr = Translate 
module L = Location 
module U = Unique
module S = Symbol 
module ST = Symbol_table 

type expr_ty = {
  expr: Tr.expr;
  ty: T.t;
}

let ret expr ty = 
  Trace.SemanticAnalysis.ret expr ty;
  { expr; ty }

let ret_int x = ret (Tr.e_int x) T.Int 
let ret_string s = ret (Tr.e_string s) T.String
let ret_nil = ret Tr.e_nil T.Nil 
let ret_unit = ret Tr.e_unit T.Unit 

let type_mismatch_error4 msg l expected actual = 
  let msg' = sprintf
    "type \"%s\" is expected, but found \"%s\""
    (T.to_string expected) (T.to_string actual) in 
  type_error l @@ msg ^ msg' 

let type_mismatch_error3 l expected actual = 
  type_mismatch_error4 "" l expected actual 

let missing_field_error t name = 
  id_error name @@ sprintf 
    "record of type \"%s\" doesn't have field \"%s\""
    (T.to_string t) (name.L.value.S.name) 

let rec trans_prog expr = 
  let module Frag = Fragment.Store in 
  Trace.SemanticAnalysis.trans_prog expr; 
  let env = Env.mk () in 
  Frag.reset ();
  let r = trans_expr L.(~?expr) ~env in 
  Tr.proc_entry_exit (env.level, r.expr);
  Frag.result ();

and trans_expr expr ~env = 
  let open Syntax in 

  let rec assert_ty e a = 
    Trace.SemanticAnalysis.assert_ty e a;
    if T.(~!e <> ~!a) then type_mismatch_error3 expr e a 
  
  and assert_int ty = assert_ty T.Int ty 
  and assert_unit ty = assert_ty T.Unit ty 

  and tr_expr expr ~env = 
    Trace.SemanticAnalysis.tr_expr expr;

    let env = Env.enter_expr env expr in 
    match expr.L.value with 
    | Var var -> tr_var var ~env 
    | Nil _ -> ret_nil 
    | Int x -> ret_int x.L.value 
    | String s -> ret_string s.L.value 
    | Call (f, args) -> tr_call f args ~env 
    | Op (l, op, r) -> tr_op l op.L.value r ~env
    | Record (name, fields) -> tr_record name fields ~env 
    | Seq [] -> ret_unit 
    | Seq exprs -> tr_seq exprs ~env 
    | Assign (var, expr) -> tr_assign var expr ~env 
    | If (cond, t, f) -> tr_cond cond t f ~env 
    | While (cond, body) -> tr_while cond body ~env 
    | For (var, lo, hi, body, escapes) -> tr_for var lo hi body escapes ~env 
    | Break br -> tr_break br ~env 
    | Let (decs, body) -> tr_let decs body ~env 
    | Array (ty, size, init) -> tr_array ty size init ~env 
  
  and tr_break br ~env = 
    Trace.SemanticAnalysis.tr_break br env.break;
    match env.break with 
    | Some l -> 
      ret (Tr.e_break l) T.Unit 
    | None -> 
      syntax_error br "unexpected break statement"
  
  and tr_call f args ~env = 
    Trace.SemanticAnalysis.tr_call f args; 
    match ST.look_fun env.venv f with 
    | VarEntry { ty; _ } -> 
      type_error f @@ sprintf 
      "expected function, but found variable \"%s\" of type \"%s\""
      (f.L.value.S.name) (T.to_string ty)
    | FunEntry fn -> 
      if List.length fn.formals <> List.length args then 
        type_error f @@ sprintf 
          "function \"%s\" expects %d formal arguments, but %d was given"
          (f.L.value.S.name) (List.length fn.formals) (List.length args);
      
      let args_r = List.map args ~f:(tr_expr ~env) in 
      List.iter2_exn fn.formals args_r ~f:(fun t ({ ty; _ }) -> assert_ty t ty);
      let result = T.(~!(fn.result)) in 
      let is_proc = T.(result = Unit) in 
      let args_e  = List.map args_r ~f:(fun a -> a.expr) in 
      let expr = Tr.e_call (fn.label, args_e) (env.level, fn.level) is_proc in 
      ret expr result 
  
  and tr_op l op r ~env = 
    Trace.SemanticAnalysis.tr_op l op r;
    let lr = tr_expr l ~env in 
    let rr = tr_expr r ~env in 
    (match op with 
      | Eq | Neq -> 
        assert_ty lr.ty rr.ty
      | _ -> 
        assert_int lr.ty;
        assert_int rr.ty);
    let args = (lr.expr, op, rr.expr) in 
    let ty = T.Int in 
    match op with 
      | Plus | Minus | Times | Divide -> 
        ret (Tr.e_binop args) ty 
      | Ge | Gt | Le | Lt | Eq | Neq -> 
        ret (Tr.e_relop args) ty 
  
  and tr_assign var expr ~env = 
    Trace.SemanticAnalysis.tr_assign var expr;
    let vr = tr_var var ~env in 
    let er = tr_expr expr ~env in 
    if T.(vr.ty = er.ty)
    then ret (Tr.e_assign (vr.expr, er.expr)) T.Unit 
    else type_error expr @@ sprintf 
      "invalid assignment of type \"%s\" to a variable of type \"%s\""
      (T.to_string er.ty) (T.to_string vr.ty)
  
  and tr_seq exprs ~env = 
    Trace.SemanticAnalysis.tr_seq exprs;
    let rs = List.map exprs ~f:(tr_expr ~env) in 
    let lr = List.last_exn rs in 
    let es = List.map rs ~f:(fun e -> e.expr) in 
    ret (Tr.e_seq es) lr.ty 
  
  and tr_cond cond t f ~env = 
    Trace.SemanticAnalysis.tr_cond cond t f;
    let cond_r = tr_expr cond ~env in 
    assert_int cond_r.ty;
    Trace.SemanticAnalysis.tr_then ();
    let tr = tr_expr t ~env in 
    match f with 
      | None -> 
        assert_unit tr.ty;
        ret (Tr.e_cond (cond_r.expr, tr.expr, None)) tr.ty 
      | Some f -> 
        Trace.SemanticAnalysis.tr_else ();
        let fr = tr_expr f ~env in 
        if T.(tr.ty = fr.ty)
        then ret (Tr.e_cond (cond_r.expr, tr.expr, Some fr.expr)) tr.ty 
        else type_error expr @@ sprintf 
          "different types of branch expressions: \"%s\" and \"%s\""
          (T.to_string tr.ty) (T.to_string fr.ty)
  
  and tr_while cond body ~env = 
    Trace.SemanticAnalysis.tr_while cond body;
    let cond_r = tr_expr cond ~env in 
    let (done_l, env') = Env.enter_loop env in 
    let body_r = tr_expr body ~env:env' in 
    assert_int cond_r.ty;
    assert_unit body_r.ty; 
    ret (Tr.e_loop (cond_r.expr, body_r.expr, done_l)) T.Unit 
  
  and tr_for var lo hi body escapes ~env = 
    Trace.SemanticAnalysis.tr_for var lo hi body escapes;

    let lo_r = tr_expr lo ~env in 
    let hi_r = tr_expr hi ~env in 
    assert_int lo_r.ty;
    assert_int hi_r.ty;

    let let_expr = Syntax_rewriter.rewrite_for var lo hi body escapes in 
    tr_expr let_expr ~env 
  
  and tr_let decs body ~env = 
    Trace.SemanticAnalysis.tr_let decs body;
    let (env', exprs) = trans_decs decs ~env in 

    let r = trans_expr body ~env:env' in 
    ret (Tr.e_let (exprs, r.expr)) r.ty 
  
  and tr_record_field rec_typ tfields (name, expr) ~env = 
    Trace.SemanticAnalysis.tr_record_field name expr rec_typ;
    match List.Assoc.find tfields ~equal:S.equal name.L.value with 
    | Some ty_field -> 
      let r = tr_expr expr ~env in 
      if T.(ty_field @<> r.ty)
      then type_mismatch_error3 expr ty_field r.ty 
      else r.expr
    | None -> 
      missing_field_error rec_typ name 
  
  and tr_record ty_name vfields ~env = 
    let open T in 
    Trace.SemanticAnalysis.tr_record ty_name vfields;
    let rec_typ = ST.look_typ env.tenv ty_name in 
    match ~!rec_typ with 
    | T.Record (tfields, _) -> 
      let fields = List.map vfields ~f:(tr_record_field rec_typ tfields ~env) in 
      ret (Tr.e_record fields) rec_typ 
    | _ -> 
      type_error ty_name @@ sprintf 
        "\"%s\" is not a record" (T.to_string rec_typ)

  and tr_array typ size init ~env = 
      let open T in 
      Trace.SemanticAnalysis.tr_array typ size init;
      let size_r = tr_expr size ~env in 
      assert_int size_r.ty;
      let init_r = tr_expr init ~env in 
      let arr_ty = ST.look_typ env.tenv typ in 
      match ~!arr_ty with 
      | T.Array (tn, _) -> 
        let t = ~!tn in 
        let init_ty = ~!(init_r.ty) in 
        if t = init_ty 
        then ret (Tr.e_array (size_r.expr, init_r.expr)) arr_ty 
        else type_mismatch_error4
          "invalid type of array initial value, " init t init_ty 
      | _ -> 
        type_error typ @@ sprintf 
          "\"%s\" is not array" (T.to_string arr_ty)
  
  and tr_var var ~env = 
      Trace.SemanticAnalysis.tr_var var;
      match var.L.value with
      | SimpleVar var -> 
        tr_simple_var var ~env 
      | FieldVar (var, field) -> 
        tr_field_var var field ~env
      | SubscriptVar (var, sub) ->
        tr_subscript_var var sub ~env
  
  and tr_simple_var var ~env = 
      Trace.SemanticAnalysis.tr_simple_var var;
      match ST.look_var env.venv var with 
      | VarEntry ventry -> 
        ret (Tr.e_simple_var (ventry.access, env.level)) (T.actual ventry.ty)
      | FunEntry { formals; result; _ } -> 
        let signature =
          formals
          |> List.map ~f:T.to_string 
          |> String.concat ~sep: ", " in 
        type_error var @@ sprintf 
          "expected variable, but found a function \"(%s) : %s\""
          signature (T.to_string result)
  and tr_field_var var field ~env = 
      Trace.SemanticAnalysis.tr_field_var var field;
      let rec_r = tr_var var ~env in 
      match rec_r.ty with 
      | Record (fields, _) -> 
        (match List.findi fields ~f:(fun _ (name, _) -> S.(name = field.L.value)) with 
        | Some (i, (_, tt)) -> T.(ret (Tr.e_field_var rec_r.expr i) ~!tt)
        | None -> missing_field_error rec_r.ty field)
      | _ -> 
        type_error var @@ sprintf 
          "expected record, but \"%s\" found"
          (T.to_string rec_r.ty)
  
  and tr_subscript_var var sub ~env = 
      Trace.SemanticAnalysis.tr_subscript_var var sub;
      let arr_r = tr_var var ~env in 
      match arr_r.ty with 
      | Array(tn, _) -> 
        let sub_r = tr_expr sub ~env in 
        assert_int sub_r.ty;
        T.(ret (Tr.e_subscript_var arr_r.expr sub_r.expr) ~!tn)
      | _ -> 
        type_error var @@ sprintf 
          "\"%s\" is not an array" (T.to_string arr_r.ty)
  in 
  tr_expr expr ~env 
and trans_decs decs ~env = 
  Trace.SemanticAnalysis.trans_decs decs;
  List.fold_left decs 
    ~f: (fun (env, exprs) dec -> 
         let (env', exprs') = trans_dec dec ~env in
         (env', exprs @ exprs'))
    ~init: (env, [])

and trans_dec ~env = function 
  | TypeDec tys -> (trans_type_decs tys ~env, [])
  | FunDec fs -> (trans_fun_decs fs ~env, [])
  | VarDec var -> trans_var_dec var ~env 

and trans_type_decs tys ~env = 
  let open Syntax in 
  let tr_ty_head (tns, tenv) ty_dec = 
    let typ = ty_dec.L.value.type_name in 
    let tn = ref None in 
    let tenv' = ST.bind_typ tenv typ (T.Name (typ.L.value, tn)) in 
    tn :: tns, tenv' in 
  let (tns, tenv') = List.fold_left tys ~init:([], env.tenv) ~f:tr_ty_head in 
  let resolve_ty tn ty_dec = 
    let { typ; _ } = ty_dec.L.value in 
    let t = trans_ty tenv' typ in 
    tn := Some t 
  in 
  Trace.SemanticAnalysis.trans_type_decs tys;
  List.iter2_exn (List.rev tns) tys ~f: resolve_ty;
  { env with tenv = tenv' }

and trans_fun_decs fs ~env = 
  let open Syntax in 
  let open Env in 

  let tr_fun_head (sigs, venv) fun_dec = 
    Trace.SemanticAnalysis.trans_fun_head fun_dec;
    let { fun_name; params; result_typ; _ } = fun_dec.L.value in 
    let args = List.map params ~f:(fun p -> p, ST.look_typ env.tenv p.typ) in 
    let result = match result_typ with 
      | None -> T.Unit 
      | Some t -> ST.look_typ env.tenv t in 
    let esc_formals = List.map params ~f:(fun f -> !(f.escapes)) in 
    let label = Temp.mk_label None in 
    let parent = Some env.level in 
    let level = Tr.new_level ~parent ~label ~formals:esc_formals in 
    Trace.Translation.new_level level;
    let formals = List.map args ~f: snd in 
    let entry = FunEntry { level; label; formals; result } in 
    let venv' = ST.bind_fun venv fun_name entry in 
    (level, args, result) :: sigs, venv' in 
  
  let (sigs, venv') = List.fold_left fs ~f:tr_fun_head ~init:([], env.venv) in 

  let assert_fun_body (level', params, result) fun_dec = 
    Trace.SemanticAnalysis.assert_fun_body fun_dec result;
    let add_param e ({ name; escapes; _ }, ty) = 
      let access = Tr.alloc_local ~level:env.level ~escapes:!escapes in 
      Trace.Translation.alloc_local access;
      let entry = VarEntry { ty; access } in 
      ST.bind_var e name entry 
    in 
    let venv'' = List.fold_left params ~init:venv' ~f:add_param in 
    let env' = { env with level = level'; venv = venv'' } in 
    let { body; _ } = fun_dec.L.value in 
    let body_ty = trans_expr body ~env:env' in 
    if T.(body_ty.ty <> result) 
    then type_mismatch_error4 
    "type of the body expression doesn't match the declared result type, "
      body result body_ty.ty;
    Tr.proc_entry_exit (level', body_ty.expr)
  in
  Trace.SemanticAnalysis.trans_fun_decs fs;
  List.iter2_exn (List.rev sigs) fs ~f: assert_fun_body;
  { env with venv = venv' }
  
and assert_init var init_ty ~env = 
    let open Syntax in 
    let open Env in 
    let { var_typ; init; _ } = var.L.value in 
    match var_typ with 
    | None -> () 
    | Some ann_ty ->
      let var_ty = ST.look_typ env.tenv ann_ty in 
      if T.(var_ty @<> init_ty)
      then type_mismatch_error3 init var_ty init_ty
and trans_var_dec var ~env = 
  let open Syntax in 
  Trace.SemanticAnalysis.trans_var_dec var;
  let { var_name; init; escapes; _ } = var.L.value in 
  let init_r = trans_expr init ~env in 
  assert_init var init_r.ty ~env;
  let access = Tr.alloc_local ~level:env.level ~escapes:!escapes in 
  Trace.Translation.alloc_local access;
  let entry = Env.VarEntry { ty = init_r.ty; access } in 
  let venv' = ST.bind_var env.venv var_name entry in 
  let var_expr = Tr.e_simple_var (access, env.level) in 
  let exprs = [Tr.e_assign (var_expr, init_r.expr)] in 
  { env with venv = venv' }, exprs

and trans_ty tenv typ =  
  let open Syntax in
  Trace.SemanticAnalysis.trans_ty typ;
  match typ with 
  | NameTy t -> 
    ST.look_typ tenv t 
  | RecordTy dec_fields -> 
    let to_field { name; typ; _ } = 
      name.L.value, ST.look_typ tenv typ in 
    let ty_fields = List.map dec_fields ~f:to_field in 
    T.Record (ty_fields, U.mk ())
  | ArrayTy t -> 
    T.Array (ST.look_typ tenv t, U.mk ())
