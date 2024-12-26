type ty =
  | TUnit
  | TVar of string
  | TExVar of string
  | TForall of string * ty
  | TLam of ty * ty
[@@deriving show]

let rec is_monotype = function
  | TForall (_, _) -> false
  | TLam (a, b) -> is_monotype a && is_monotype b
  | _ -> true

let rec replace_tvar n ev = function
  | TVar n' when n == n' -> TExVar ev
  | TLam (a, b) -> TLam (replace_tvar n ev a, replace_tvar n ev b)
  | TForall (x, b) -> TForall (x, replace_tvar n ev b)
  | t -> t

module Ctx = struct
  type entry =
    | CETVar of string
    | CEVar of string * ty
    | CEExVar of string
    | CESolved of string * ty
    | CEMarker of string
  [@@deriving show]

  type t = entry list [@@deriving show]

  let find_map = List.find_map
  let exists pred = List.exists (fun e -> Option.is_some (pred e))

  (*
  first returned list is in reverse order 
  make sure to use List.rev_append    
  *)
  let split pred ctx =
    let rec recurse acc1 acc2 =
      match acc1 with
      | [] -> None
      | e :: es -> (
          match pred e with
          | Some _ -> Some (acc2, e, acc1)
          | None -> recurse es (e :: acc2))
    in
    recurse ctx []

  (*
  the first and second returned lists are in reverse order 
  make sure to use List.rev_append    
  *)
  let split2 pred2 pred1 ctx =
    match split pred2 ctx with
    | Some (ctx3, e2, ctx') -> (
        match split pred1 ctx' with
        | Some (ctx2, e1, ctx1) -> Some (ctx3, e2, ctx2, e1, ctx1)
        | None -> None)
    | None -> None

  let var_named x = function CEVar (x', b) when x == x' -> Some b | _ -> None
  let tvar_named x = function CETVar x' when x == x' -> Some () | _ -> None

  let exvar_named x = function
    | CEExVar x' when x == x' -> Some None
    | CESolved (x', b) when x == x' -> Some (Some b)
    | _ -> None

  let exvar_unsolved x = function
    | CEExVar x' when x == x' -> Some ()
    | _ -> None

  let exvar_solved x = function
    | CESolved (x', b) when x == x' -> Some b
    | _ -> None

  let marker_named x = function
    | CEMarker x' when x == x' -> Some ()
    | _ -> None

  let rec is_wellformed_ty ctx = function
    | TVar x -> exists (tvar_named x) ctx
    | TLam (a, b) -> is_wellformed_ty ctx a && is_wellformed_ty ctx b
    | TForall (x, b) -> is_wellformed_ty (CETVar x :: ctx) b
    | TExVar x -> exists (exvar_named x) ctx
    | _ -> true

  let rec apply ctx = function
    | TExVar x -> (
        match find_map (exvar_solved x) ctx with
        | Some t -> t
        | None -> TExVar x)
    | TLam (a, b) -> TLam (apply ctx a, apply ctx b)
    | TForall (x, a) -> TForall (x, apply ctx a)
    | t -> t
end

module Env = struct
  type 'a r =
    | Success of 'a
    | NonWellformedContext of string
    | NoRuleApplicable of string

  (* exvar_cnt *)
  type s = int
  type 'a t = s -> 'a r * s

  let return x s = (Success x, s)

  let bind x ~f s =
    let a, s' = x s in
    match a with
    | Success r -> f r s'
    | NonWellformedContext m -> (NonWellformedContext m, s')
    | NoRuleApplicable m -> (NoRuleApplicable m, s')

  let map x ~f s =
    let a, s' = x s in
    match a with
    | Success r -> (f r, s')
    | NonWellformedContext m -> (NonWellformedContext m, s')
    | NoRuleApplicable m -> (NoRuleApplicable m, s')

  let fresh_exvar s = (Success ("ev" ^ string_of_int s), s + 1)
  let non_wellformed_context m s = (NonWellformedContext m, s)
  let no_rule_applicable m s = (NoRuleApplicable m, s)
  let run s e = fst (e s)

  module Let_syntax = struct
    module Let_syntax = struct
      let return = return
      let bind = bind
      let map = map

      module Open_on_rhs = struct
        let return = return
      end
    end
  end
end

open Env.Let_syntax

let rec subtype ctx a b =
  match (a, b) with
  | TUnit, TUnit -> Env.return ctx
  | TVar x1, TVar x2 when x1 == x2 ->
      if Ctx.exists (Ctx.tvar_named x1) ctx then Env.return ctx
      else Env.non_wellformed_context [%string "unbound type variable %{x1}"]
  | TExVar x1, TExVar x2 when x1 == x2 ->
      if Ctx.exists (Ctx.exvar_unsolved x1) ctx then Env.return ctx
      else
        Env.non_wellformed_context
          [%string "unbound existential variable %{x1}"]
  | TLam (a1, a2), TLam (b1, b2) ->
      let%bind ctx' = subtype ctx b1 a1 in
      let%bind ctx'' = subtype ctx' (Ctx.apply ctx' a2) (Ctx.apply ctx' b2) in
      Env.return ctx''
  | TForall (x, a), b -> (
      let%bind ev = Env.fresh_exvar in
      let ctx' = Ctx.CEExVar ev :: Ctx.CEMarker ev :: ctx in
      let%bind ctx'' = subtype ctx' (replace_tvar x ev a) b in
      match Ctx.split (Ctx.marker_named ev) ctx'' with
      | Some (_, _, ctx''') -> Env.return ctx'''
      | None ->
          Env.non_wellformed_context
            [%string
              "unable to split: missing marker for existential variable %{ev}"])
  | a, TForall (x, b) -> (
      let ctx' = Ctx.CETVar x :: ctx in
      let%bind ctx'' = subtype ctx' a b in
      match Ctx.split (Ctx.tvar_named x) ctx'' with
      | Some (_, _, ctx''') -> Env.return ctx'''
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: missing type variable %{x}"])
  (* todo: instl & instr *)
  | _ ->
      Env.no_rule_applicable
        [%string "subtype: no rule applicable for %{show_ty a} <: %{show_ty b}"]

and instl ctx eva = function
  | t when is_monotype t -> (
      match Ctx.split (Ctx.exvar_unsolved eva) ctx with
      | Some (ctx2, _, ctx1) ->
          if Ctx.is_wellformed_ty ctx1 t then
            Env.return (List.rev_append ctx2 (Ctx.CESolved (eva, t) :: ctx1))
          else
            Env.non_wellformed_context
              [%string "non wellformed type %{show_ty t}"]
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: %{eva} is unbound or solved"])
  | TExVar evb -> (
      match
        Ctx.split2 (Ctx.exvar_unsolved evb) (Ctx.exvar_unsolved eva) ctx
      with
      | Some (ctx3, _, ctx2, e1, ctx1) ->
          Env.return
            (List.rev_append ctx3
               (Ctx.CESolved (evb, TExVar eva)
               :: List.rev_append ctx2 (e1 :: ctx1)))
      | None ->
          Env.non_wellformed_context
            [%string
              "unable to split2: existential variable %{eva}, %{evb} is \
               unbound or solved"])
  | TLam (a1, a2) -> (
      match Ctx.split (Ctx.exvar_unsolved eva) ctx with
      | Some (ctx2, _, ctx1) ->
          let%bind ev1 = Env.fresh_exvar in
          let%bind ev2 = Env.fresh_exvar in
          let ctx' =
            List.rev_append ctx2
              (Ctx.CESolved (eva, TLam (TExVar ev1, TExVar ev2))
              :: Ctx.CEExVar ev1 :: Ctx.CEExVar ev2 :: ctx1)
          in
          let%bind ctx'' = instr ctx' ev1 a1 in
          let%bind ctx''' = instl ctx'' ev2 (Ctx.apply ctx'' a2) in
          Env.return ctx'''
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: unbound existential variable %{eva}"])
  | TForall (tvb, b) ->
      if Ctx.exists (Ctx.exvar_unsolved eva) ctx then
        let ctx' = Ctx.CETVar tvb :: ctx in
        let%bind ctx'' = instl ctx' eva b in
        match Ctx.split (Ctx.tvar_named tvb) ctx'' with
        | Some (_, _, ctx1) -> Env.return ctx1
        | None ->
            Env.non_wellformed_context
              [%string "unable to split: missing type variable %{tvb}"]
      else
        Env.non_wellformed_context
          [%string "unbound existential variable %{eva}"]
  | t ->
      Env.no_rule_applicable
        [%string "instl: no rule applicable for %{show_ty t}"]

and instr ctx eva = function
  | t when is_monotype t -> (
      match Ctx.split (Ctx.exvar_unsolved eva) ctx with
      | Some (ctx2, _, ctx1) ->
          if Ctx.is_wellformed_ty ctx1 t then
            Env.return (List.rev_append ctx2 (Ctx.CESolved (eva, t) :: ctx1))
          else
            Env.non_wellformed_context
              [%string "non wellformed type %{show_ty t}"]
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: %{eva} is unbound or solved"])
  | TExVar evb -> (
      match
        Ctx.split2 (Ctx.exvar_unsolved evb) (Ctx.exvar_unsolved eva) ctx
      with
      | Some (ctx3, _, ctx2, e1, ctx1) ->
          Env.return
            (List.rev_append ctx3
               (Ctx.CESolved (evb, TExVar eva)
               :: List.rev_append ctx2 (e1 :: ctx1)))
      | None ->
          Env.non_wellformed_context
            [%string
              "unable to split2: existential variable %{eva}, %{evb} is \
               unbound or solved"])
  | TLam (a1, a2) -> (
      match Ctx.split (Ctx.exvar_unsolved eva) ctx with
      | Some (ctx2, _, ctx1) ->
          let%bind ev1 = Env.fresh_exvar in
          let%bind ev2 = Env.fresh_exvar in
          let ctx' =
            List.rev_append ctx2
              (Ctx.CESolved (eva, TLam (TExVar ev1, TExVar ev2))
              :: Ctx.CEExVar ev1 :: Ctx.CEExVar ev2 :: ctx1)
          in
          let%bind ctx'' = instl ctx' ev1 a1 in
          let%bind ctx''' = instr ctx'' ev2 (Ctx.apply ctx'' a2) in
          Env.return ctx'''
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: unbound existential variable %{eva}"])
  | TForall (tvb, b) ->
      if Ctx.exists (Ctx.exvar_unsolved eva) ctx then
        let ctx' = Ctx.CEExVar tvb :: Ctx.CEMarker tvb :: ctx in
        let%bind ctx'' = instr ctx' eva (replace_tvar tvb tvb b) in
        match Ctx.split (Ctx.marker_named tvb) ctx'' with
        | Some (_, _, ctx1) -> Env.return ctx1
        | None ->
            Env.non_wellformed_context
              [%string
                "unable to split: missing marker for existential variable \
                 %{tvb}"]
      else
        Env.non_wellformed_context
          [%string "unbound existential variable %{eva}"]
  | t ->
      Env.no_rule_applicable
        [%string "instr: no rule applicable for %{show_ty t}"]

let rec check ctx e ta =
  match (e, ta) with
  | Syntax.Unit, TUnit -> Env.return ctx
  | e, TForall (tva, a) -> (
      let%bind ctx' = check (Ctx.CETVar tva :: ctx) e a in
      match Ctx.split (Ctx.tvar_named tva) ctx' with
      | Some (_, _, ctx1) -> Env.return ctx1
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: missing type variable %{tva}"])
  | Syntax.Lam ([ Syntax.PVar x ], e), TLam (ta, tb) -> (
      let%bind ctx' = check (Ctx.CEVar (x, ta) :: ctx) e tb in
      match Ctx.split (Ctx.var_named x) ctx' with
      | Some (_, _, ctx1) -> Env.return ctx1
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: missing variable %{x}"])
  | e, b ->
      let%bind a, ctx' = infer ctx e in
      subtype ctx' (Ctx.apply ctx' a) (Ctx.apply ctx' b)

and infer ctx e =
  match e with
  | Syntax.Unit -> Env.return (TUnit, ctx)
  | Syntax.Var x -> (
      match Ctx.find_map (Ctx.var_named x) ctx with
      | Some t -> Env.return (t, ctx)
      | None -> Env.non_wellformed_context [%string "unbound variable %{x}"])
  | Syntax.Lam ([ Syntax.PVar x ], e) -> (
      let%bind eva = Env.fresh_exvar in
      let%bind evb = Env.fresh_exvar in
      let ctx' =
        Ctx.CEVar (x, TExVar eva) :: Ctx.CEExVar evb :: Ctx.CEExVar eva :: ctx
      in
      let%bind ctx'' = check ctx' e (TExVar evb) in
      match Ctx.split (Ctx.var_named x) ctx'' with
      | Some (_, _, ctx1) -> Env.return (TLam (TExVar eva, TExVar evb), ctx1)
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: missing variable %{x}"])
  | Syntax.App (e1, [ e2 ]) ->
      let%bind a, ctx' = infer ctx e1 in
      infer_app ctx' (Ctx.apply ctx' a) e2
  | t -> Env.no_rule_applicable [%string "infer: no rule applicable for %{Syntax.show_expr t}"]

and infer_app ctx ta e =
  match ta with
  | TForall (tva, a) ->
      infer_app (Ctx.CEExVar tva :: ctx) (replace_tvar tva tva a) e
  | TExVar eva -> (
      match Ctx.split (Ctx.exvar_unsolved eva) ctx with
      | Some (ctx2, _, ctx1) ->
          let%bind eva1 = Env.fresh_exvar in
          let%bind eva2 = Env.fresh_exvar in
          let ctx' =
            List.rev_append ctx2
              (Ctx.CESolved (eva, TLam (TExVar eva1, TExVar eva2))
              :: Ctx.CEExVar eva1 :: Ctx.CEExVar eva2 :: ctx1)
          in
          let%bind ctx'' = check ctx' e (TExVar eva1) in
          Env.return (TExVar eva2, ctx'')
      | None ->
          Env.non_wellformed_context
            [%string "unable to split: unbound existential variable %{eva}"])
  | TLam (a, c) ->
      let%bind ctx' = check ctx e a in
      Env.return (c, ctx')
  | t ->
      Env.no_rule_applicable
        [%string "infer_app: no rule applicable for %{show_ty t}"]