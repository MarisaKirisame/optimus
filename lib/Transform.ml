open Syntax
open Fresh
module Ctx = Map.Make (String)

type ctx = int Ctx.t

let cps ctx expr =
  let mk_fresh_param prefix =
    let k = next_fresh prefix in
    (PVar k, Var k)
  in
  let mk_fresh_params n prefix =
    let rec aux acc acc2 n =
      if n = 0 then (acc, acc2)
      else
        let x = next_fresh prefix in
        aux (PVar x :: acc) (Var x :: acc2) (n - 1)
    in
    let l1, l2 = aux [] [] n in
    (List.rev l1, List.rev l2)
  in
  let is_atomic = function
    | Unit | Int _ | Float _ | Bool _ | Str _ | Builtin _ | Var _ | Ctor _
    | Lam _ ->
        true
    | _ -> false
  in
  let ( let* ) e f = e f in
  let rec atom = function
    | Unit -> Unit
    | Int i -> Int i
    | Float f -> Float f
    | Bool b -> Bool b
    | Str s -> Str s
    | Builtin b -> Builtin b
    | Var x -> Var x
    | Ctor x ->
        let n = Ctx.find x ctx in
        if n = 0 then Ctor x
        else
          let pas, vas = mk_fresh_params n "_'a" in
          let pks, vks = mk_fresh_params n "_'k" in
          List.fold_right2
            (fun (pa, _) (pk, vk) acc -> Lam ([ pa; pk ], App (vk, [ acc ])))
            (List.combine pas vas) (List.combine pks vks)
            (App (Ctor x, vas))
    | Lam (xs, e) ->
        let pk, vk = mk_fresh_param "_'k" in
        Lam (xs @ [ pk ], cps'' e vk)
    | _ -> failwith "not an atom"
  and cps' e k =
    match e with
    | x when is_atomic x -> k (atom x)
    | App (f, xs) ->
        assert (List.length xs <= 1);
        let* f = cps' f in
        let* xs = cps_l' xs in
        let pa, va = mk_fresh_param "_'a" in
        let pc, vc = mk_fresh_param "_'cont" in
        Let (BCont (pc, Lam ([ pa ], k va)), App (f, xs @ [ vc ]))
    | Op (op, e1, e2) ->
        let* e1 = cps' e1 in
        let* e2 = cps' e2 in
        k (Op (op, e1, e2))
    | Tup es ->
        let* es = cps_l' es in
        k (Tup es)
    | Arr es ->
        let* es = cps_l' es in
        k (Arr es)
    | Let (BOne (x, e1), e2) ->
        let* e1 = cps' e1 in
        let* e2 = cps' e2 in
        k (Let (BOne (x, e1), e2))
    | Let (BRec xs, e2) ->
        let rhs = List.map snd xs in
        let* rhs = cps_l' rhs in
        let* e2 = cps' e2 in
        let r = Let (BRec (List.combine (List.map fst xs) rhs), e2) in
        k r
    | Sel (e, x) ->
        let* e = cps' e in
        k (Sel (e, x))
    | If (e1, e2, e3) ->
        let pk, vk = mk_fresh_param "_'k" in
        let pa, va = mk_fresh_param "_'a" in
        let pc, vc = mk_fresh_param "_'cont" in
        let* e1 = cps' e1 in
        Let
          ( BCont (pc, Lam ([ pa ], k va)),
            App (Lam ([ pk ], If (e1, cps'' e2 vk, cps'' e3 vk)), [ vc ]) )
    | Match (cond, MatchPattern cases) ->
        let* cond = cps' cond in
        let arms = List.map snd cases in
        let* arms = cps_l' arms in
        Match (cond, MatchPattern (List.combine (List.map fst cases) arms))
    | _ -> failwith "not an valid expr"
  and cps_l' es k =
    match es with
    | [] -> k []
    | e :: es' -> cps' e (fun e' -> cps_l' es' (fun es' -> k (e' :: es')))
  and cps'' e cont =
    match e with
    | x when is_atomic x -> App (cont, [ atom x ])
    | App (f, xs) ->
        assert (List.length xs <= 1);
        let* f = cps' f in
        let* xs = cps_l' xs in
        App (f, xs @ [ cont ])
    | Op (op, e1, e2) ->
        let* e1 = cps' e1 in
        let* e2 = cps' e2 in
        App (cont, [ Op (op, e1, e2) ])
    | Tup es ->
        let* es = cps_l' es in
        App (cont, [ Tup es ])
    | Arr es ->
        let* es = cps_l' es in
        App (cont, [ Arr es ])
    | Let (BOne (x, e1), e2) ->
        let* e1 = cps' e1 in
        let* e2 = cps' e2 in
        App (cont, [ Let (BOne (x, e1), e2) ])
    | Let (BRec xs, e2) ->
        let rhs = List.map snd xs in
        let* rhs = cps_l' rhs in
        let* e2 = cps' e2 in
        let r = Let (BRec (List.combine (List.map fst xs) rhs), e2) in
        App (cont, [ r ])
    | Sel (e, x) ->
        let* e = cps' e in
        App (cont, [ Sel (e, x) ])
    | If (e1, e2, e3) ->
        let* e1 = cps' e1 in
        If (e1, cps'' e2 cont, cps'' e3 cont)
    | Match (cond, MatchPattern cases) ->
        let* cond = cps' cond in
        let arms = List.map snd cases in
        let arms = List.map (fun e -> cps'' e cont) arms in
        Match (cond, MatchPattern (List.combine (List.map fst cases) arms))
    | _ -> failwith "not an valid expr"
  in
  cps' expr (fun x -> x)

let cps_prog (prog : prog) =
  let scan_ctors_arity ctx =
    let aux ctx (kind : ty_kind) =
      match kind with
      | Enum { ctors; _ } ->
          List.fold_left
            (fun ctx (name, params) ->
              assert (not @@ Ctx.mem name ctx);
              Ctx.add name (List.length params) ctx)
            ctx ctors
    in
    function
    | TBOne (_, kind) -> aux ctx kind
    | TBRec kinds ->
        List.fold_left (fun ctx (_, kind) -> aux ctx kind) ctx kinds
  in
  let _, prog =
    List.fold_left_map
      (fun ctx item ->
        match item with
        | Type tb -> (scan_ctors_arity ctx tb, item)
        | Term (p, e) -> (ctx, Term (p, cps ctx e))
        | _ -> failwith "Unsuppored item")
      Ctx.empty prog
  in
  prog
