(* Required reading: Seq.ml
 *
 * This file contian all code that deals with memoiziation.
 * There is multiple mutually recursive component which together enable memoization.
 * However, three of them are the most critical:
 *   The Reference type. It represent fragment of the finger tree that is unavailable, as we're working on fragment of the tree.
 *   The Store. It give meaning to Reference type in the tree.
 *   The memo. It is a fusion between hashtable and trie, somewhat like the patrica trie, to traverse prefix at exponential rate.
 *)
open BatFingerTree
open Word
open Common
module Hasher = Hash.SL2

type env = value Dynarray.t

(* One thing we might want is to have exp as an adt,
 *   which allow memoizing exp fragment to incrementalize the program under changes.
 * However, it
 *   0 - add extra overhead
 *   1 - we dont really need this for eval
 *   2 - is unclear how we actually do this with recursive function
 *         ideally, modifying a recursive function and nothing else
 *         should only cause all reexecution of that recursive function at the changed location.
 *)
and exp = {
  (* One step transition. Throw an exception when done. *)
  step : state -> state;
  (*pc is an isomorphism to func, and pc -> func is a table lookup.*)
  pc : int;
}

and kont = value

(* Record Mode:
 * Adding new entries to the memo require entering record mode,
 * Which track fetched fragment versus unfetched fragment.
 * Fetched fragment can be used normally,
 *   while the unfetched fragment cannot be used(forced).
 * Upon attempt to force an unfetched fragment, the current recording is completed,
 *   which will add a new entry to the memo.
 * Then ant will try to extend the recording by fetching the fragment,
 *   which will again run until stuck, and a new entries will then be added.
 * To extend the fetch require us to keep a old copy of the CEK machine.
 * Additionally, during record mode, ant might enter record mode again,
 *   to record a more fine-grained entries which will not skip as far, but will fire more often.
 * This mean that the CEK machine form a non-empty stack, so ant can extend the recording at any level.
 *
 * The stack can then be assigned a depth, where the root CEK machine (which does not do recording whatsowever)
 *   have a depth of 0, and an extension increase the depth by 1.
 * Values also have their own individual depth, which denote when they are created/last fetched.
 *)
and depth_t = int

and state = {
  mutable c : exp;
  mutable e : env;
  mutable k : kont;
  d : depth_t;
  mutable last : record_state option;
}

(* The Reference
 * To track whether a fragment is fetched or unfetched,
 *   ant extend the seq finger tree to include a Reference Type.
 * For a value with depth x+1, the Reference is an index into the C/E/S/K of the machine at depth x.
 * A key invariant is that a machine at depth x only contain value with depth x or with depth x+1,
 *   and a key collary is that machine at depth x is only able to fetch value at depth x-1:
 *   The machine only contain reference with depth x or x+1, and the latter is already fetched, so cannot be fetched again.
 *
 * If a value at depth x have a reference which refer to a value at depth x,
 *   It should path-compress lazily, as it had already been fetched, and the reference is pointless.
 *)
and reference = { src : source; offset : int; values_count : int }
and source = E of int | S of int | K

(* Needed in Record Mode *)
and record_state = {
  (*s f r die earlier then m so they are separated.*)
  m : state;
  s : store;
  mutable f : fetch_count;
  mutable r : record_context;
}

and fetch_count = int
and fg_et = Word of Word.t | Reference of reference
and seq = (fg_et, measure_t) Generic.fg
and measure_t = { degree : int; max_degree : int; full : full_measure option }

(* measure have this iff fully fetched (only Word.t, no reference). *)
and full_measure = { length : int; hash : Hasher.t }

(* The Store
 * A fetch can be partial, so the remaining fragment need to be fetched again.
 *   they are appended into the Store.
 * Partial fetching on consecutive value result in exponentially longer and longer fetching length,
 *   done by pairing each value a ref of length, aliased on all fetch of the same origin, growing exponentially.
 *)
and store = value Dynarray.t

(* Note: Value should not alias. Doing so will mess with the fetch_length, which is bad. *)
and value = {
  seq : seq;
  depth : depth_t;
  fetch_length : int ref;
  (* A value with depth x is path-compressed iff all the reference refer to value with depth < x.
   * If a value with depth x have it's compressed_since == fetch_count on depth x-1, it is path_compressed.
   *)
  compressed_since : fetch_count;
}

(* The memo
 * The memo is the key data structure that handle all memoization logic.
 *   It contain a fetch request, which try to fetch a reference of a length.
 *   The segment then is hashed and compared to value in a hashtable.
 *   The value inside a hashtable is a transit function,
 *     which mutate the env and the current value,
 *     alongside an extra memo.
 *   Transit function:
 *     When memo end, he result contain reference which is invalid in the original context, 
 *     and the transit function lift the result to the original context.
 *     It merely look at all the references, resolve them, and finally rebuild the result.
 *     Note that we can lookup memo inside record mode, so the transit function still operate over references.
 *     This would be handled naturally as the execution should only depend on the prefixes.
 *   The caller should traverse down this memo tree until it can not find a fetch,
 *     then execute the function.
 *)
and memo_t = memo_node_t ref Array.t

and memo_node_t =
  (* We know transiting need to resolve a fetch_request to continue. *)
  | Need of {
      request : fetch_request;
      lookup : lookup_t;
      progress : progress_t;
    }
  (* We know there is no more fetch to be done, as the machine evaluate to a value state. *)
  | Done of done_t
  (* We know nothing about what's gonna happen. Will switch to Need or Done.
   * Another design is to always force it to be a Need/Done before hand.
   *)
  | Root
  (* We are figuring out this entry. *)
  | BlackHole

and done_t = { skip : record_state -> state }

(*todo: maybe try janestreet's hashtable. we want lookup to be as fast as possible so it might be worth to ffi some SOTA*)
and lookup_t = (fetch_result, memo_node_t ref) Hashtbl.t

and progress_t = {
  (* potential optimization: make enter and exit optional to denote no progress. *)
  (* ++depth. *)
  enter : record_state -> state;
  (* --depth.
   * When a memoization run is finished, we need to replace the caller (the machine at last_t) with the current machine.
   *   Doing this require shifting all value of depth x to depth x-1.
   *   This is done by resolving reference to depth x-1.
   *)
  exit : state -> state;
}

and fetch_request = { src : source; offset : int; word_count : int }

(* todo: when the full suffix is fetched, try to extend at front. *)
and fetch_result = { fetched : words; have_prefix : bool; have_suffix : bool }
and words = seq
(* Just have Word.t. We could make Word a finger tree of Word.t but that would cost lots of conversion between two representation. *)

and record_context =
  | Evaluating of memo_node_t ref
  | Reentrance of memo_node_t
  | Building (* Urgh I hate this. It's so easy though. *)

let monoid : measure_t monoid =
  {
    zero =
      {
        degree = 0;
        max_degree = 0;
        full = Some { length = 0; hash = Hasher.unit };
      };
    combine =
      (fun x y ->
        {
          degree = x.degree + y.degree;
          max_degree = max x.max_degree (x.degree + y.max_degree);
          full =
            (match (x.full, y.full) with
            | Some xf, Some yf ->
                Some
                  {
                    length = xf.length + yf.length;
                    hash = Hasher.mul xf.hash yf.hash;
                  }
            | _ -> None);
        });
  }

let constructor_degree_table : int Dynarray.t = Dynarray.create ()

let set_constructor_degree (ctag : int) (degree : int) : unit =
  assert (Dynarray.length constructor_degree_table == ctag);
  Dynarray.add_last constructor_degree_table degree

let measure (et : fg_et) : measure_t =
  match et with
  | Word w ->
      let degree =
        match Word.get_tag w with
        | 0 -> 1
        | 1 -> Dynarray.get constructor_degree_table (Word.get_value w)
        | _ -> panic "unknown tag"
      in
      {
        degree;
        max_degree = degree;
        full = Some { length = 1; hash = Hasher.from_int w };
      }
  | Reference r ->
      { degree = r.values_count; max_degree = r.values_count; full = None }

let pop_n (s : seq) (n : int) : seq * seq =
  if n == 0 then (Generic.empty, s)
  else
    let x, y = Generic.split ~monoid ~measure (fun m -> m.max_degree >= n) s in
    let w, v = Generic.front_exn ~monoid ~measure y in
    let m = Generic.measure ~monoid ~measure x in
    assert (m.degree == m.max_degree);
    match v with
    | Word v ->
        assert (m.degree + 1 == n);
        let l = Generic.snoc ~monoid ~measure x (Word v) in
        (l, w)
    | Reference v ->
        assert (m.degree < n);
        assert (m.degree + v.values_count >= n);
        let need = n - m.degree in
        let l =
          Generic.snoc ~monoid ~measure x
            (Reference { src = v.src; offset = v.offset; values_count = need })
        in
        if v.values_count == need then (l, w)
        else
          let r =
            Generic.cons ~monoid ~measure w
              (Reference
                 {
                   src = v.src;
                   offset = v.offset + need;
                   values_count = v.values_count - need;
                 })
          in
          (l, r)

(* If it refer to a value from depth-1, it need a value which had not been fetched yet. 
     We can then flush the current state into the Recording record_context, 
       and fetch the value, and register it in memo_t.
     Then the memo_node and lookup field in record_context can be replaced with the adequate result.
 * If it refer to a value from < depth-1, it cannot be fetch. 
     We still flush the state but do not change record_context, but throw an exception instead.*)
let resolve : state * reference -> state * seq = fun _ -> todo "todo"

let get_value (rs : record_state) (src : source) : value =
  match src with
  | E i -> Dynarray.get rs.m.e i
  | S i -> Dynarray.get rs.s i
  | K -> rs.m.k

let set_value (rs : record_state) (src : source) (v : value) : unit =
  match src with
  | E i -> Dynarray.set rs.m.e i v
  | S i -> Dynarray.set rs.s i v
  | K -> rs.m.k <- v

let rec path_compress (rs : record_state) (src : source) : value =
  let v = get_value rs src in
  let new_v =
    if v.depth == 0 then v (*anything at depth 0 is trivially path-compressed*)
    else if v.depth == rs.m.d + 1 then path_compress_value rs v
    else if v.depth == rs.m.d then path_compress_value (Option.get rs.m.last) v
    else panic "bad depth"
  in
  set_value rs src new_v;
  new_v

(*given a last of depth x, value with depth x+1. path compress*)
and path_compress_value (rs : record_state) (v : value) : value =
  assert (v.depth == rs.m.d + 1);
  if v.compressed_since == rs.f then v
  else
    {
      seq = path_compress_seq rs v.seq;
      compressed_since = rs.f;
      depth = v.depth;
      fetch_length = v.fetch_length;
    }

(*path compressing a seq with depth x+1*)
and path_compress_seq (rs : record_state) (x : seq) : seq =
  let lhs, rhs =
    Generic.split ~monoid ~measure (fun m -> Option.is_none m.full) x
  in
  assert (Option.is_some (Generic.measure ~monoid ~measure lhs).full);
  match Generic.front rhs ~monoid ~measure with
  | None -> lhs
  | Some (rest, Reference y) ->
      Generic.append ~monoid ~measure lhs
        (Generic.append ~monoid ~measure
           (path_compress_reference rs y)
           (path_compress_seq rs rest))
  | _ -> panic "impossible"

(*path compressing reference of depth x+1*)
and path_compress_reference (rs : record_state) (r : reference) : seq =
  let v = get_value rs r.src in
  if v.depth == rs.m.d + 1 then (
    let v = path_compress_value rs v in
    let _, x = pop_n v.seq r.offset in
    let y, _ = pop_n x r.values_count in
    set_value rs r.src v;
    y)
  else Generic.Single (Reference r)

let add_to_store (rs : record_state) (seq : seq) (fetch_length : int ref) : seq
    =
  let v = { depth = rs.m.d; seq; compressed_since = 0; fetch_length } in
  let r = { src = S (Dynarray.length rs.s); offset = 0; values_count = 1 } in
  Dynarray.add_last rs.s v;
  Generic.singleton (Reference r)

(*move a value from depth x to depth x+1*)
let fetch_value (rs : record_state) (req : fetch_request) : fetch_result option
    =
  let v = get_value rs req.src in
  (* Only value at the right depth can be fetched. 
   * If higher depth, it is already fetched so pointless to fetch again.
   * If lower depth, it is not fetched by the last level so we cannot trepass.
   *)
  assert (v.depth == rs.m.d);
  let v = path_compress rs req.src in
  let x, y = pop_n v.seq req.offset in
  let words, rest =
    Generic.split ~monoid ~measure
      (fun m ->
        not
          (match m.full with
          | None -> false
          | Some m -> req.word_count <= m.length))
      y
  in
  let length =
    (Option.get (Generic.measure ~monoid ~measure words).full).length
  in
  if (not (Generic.is_empty rest)) && length != req.word_count then
    (*we could try to return the shorten fragment and continue. however i doubt it is reusable so we are just cluttering the hashtable*)
    None
  else
    let transformed_x =
      if Generic.is_empty x then Generic.empty
      else add_to_store rs x v.fetch_length
    in
    let transformed_rest =
      if Generic.is_empty rest then Generic.empty
        (*todo: match in the reverse direction*)
      else add_to_store rs rest v.fetch_length
    in
    rs.f <- rs.f + 1;
    set_value rs req.src
      {
        depth = v.depth + 1;
        fetch_length = v.fetch_length;
        seq =
          Generic.append ~monoid ~measure transformed_x
            (Generic.append ~monoid ~measure words transformed_rest);
        compressed_since = rs.f;
      };
    Some
      {
        fetched = words;
        have_prefix = Generic.is_empty x;
        have_suffix = Generic.is_empty rest;
      }

let init_fetch_length () : int ref = ref 1

(*assuming this seq is at depth l.m.d+1, convert it to depth l.m.d*)
let rec unshift_seq (rs : record_state) (x : seq) : seq =
  let lhs, rhs =
    Generic.split ~monoid ~measure (fun m -> Option.is_none m.full) x
  in
  assert (Option.is_some (Generic.measure ~monoid ~measure lhs).full);
  match Generic.front rhs ~monoid ~measure with
  | None -> lhs
  | Some (rest, Reference y) ->
      Generic.append ~monoid ~measure lhs
        (Generic.append ~monoid ~measure (unshift_reference rs y)
           (unshift_seq rs rest))
  | _ -> panic "impossible"

and unshift_reference (rs : record_state) (r : reference) : seq =
  let v = unshift_source rs r.src in
  assert (v.depth == rs.m.d);
  let _, x = pop_n v.seq r.offset in
  let y, _ = pop_n x r.values_count in
  y

(*move a value from depth x to depth x-1. if it refer to other value at the current level, unshift them as well.*)
and unshift_value (rs : record_state) (v : value) : value =
  if v.depth > rs.m.d then (
    assert (v.depth == rs.m.d + 1);
    {
      seq = unshift_seq rs v.seq;
      depth = rs.m.d;
      fetch_length = init_fetch_length ();
      compressed_since = 0;
    })
  else v

and unshift_source (rs : record_state) (src : source) : value =
  let v = get_value rs src in
  if v.depth > rs.m.d then (
    let new_v = unshift_value rs v in
    set_value rs src new_v;
    new_v)
  else v

let unshift_c (s : state) : exp = s.c

let unshift_all (s : state) : state =
  let last = Option.get s.last in
  (* since c is an int theres no shifting needed. todo: make this resilient to change in type *)
  let c = unshift_c s in
  let e = Dynarray.map (fun v -> unshift_value last v) s.e in
  let k = unshift_value last s.k in
  last.m.c <- c;
  last.m.e <- e;
  last.m.k <- k;
  last.m

let record_memo_exit (s : state) : state = unshift_all s
let strip_c (c : exp) : exp = c

(* Carefully written to make sure that unneeded values can be freed asap. *)
let get_enter (s : state) : record_state -> state =
  let c = strip_c s.c in
  let e = Dynarray.map (fun v -> v.seq) s.e in
  let k = s.k.seq in
  fun rs ->
    let depth = rs.m.d + 1 in
    let seq_to_value s =
      { seq = s; depth; fetch_length = ref 0; compressed_since = 0 }
    in
    {
      c;
      e = Dynarray.map seq_to_value e;
      k = seq_to_value k;
      d = depth;
      last = Some rs;
    }

let get_progress (s : state) : progress_t =
  {
    enter = get_enter s;
    (* We might want hint of new values to speedup the exit process, so have it general for now. 
     * Also good to make explicit the symmetry.
     *)
    exit = record_memo_exit;
  }

(* Stepping require an unfetched fragment. register the current state.
 * Note that the reference in request does not refer to value in s, but value one level down.
 *)
let register_memo_need_unfetched (s : state) (req : fetch_request) : state =
  let last = Option.get s.last in
  let lookup =
    match last.r with
    | Evaluating ev -> (
        match !ev with
        | BlackHole | Root ->
            let lookup = Hashtbl.create 0 in
            ev := Need { request = req; lookup; progress = get_progress s };
            lookup
        | Need _ | Done _ -> panic "impossible")
    | Reentrance re -> (
        match re with
        | Need n ->
            assert (req == n.request);
            n.lookup
        | BlackHole | Root | Done _ -> panic "impossible")
    | Building -> panic "impossible"
  in
  match fetch_value last req with
  | Some fr ->
      let bh = ref BlackHole in
      assert (not (Hashtbl.mem lookup fr));
      Hashtbl.add lookup fr bh;
      last.r <- Evaluating bh;
      s
  | None -> record_memo_exit s

let get_done (s : state) : done_t =
  let p = get_progress s in
  { skip = (fun rs -> p.exit (p.enter rs)) }

(*done so no more stepping needed. register the current state.*)
let register_memo_done (s : state) : state =
  let last = Option.get s.last in
  (match last.r with
  | Evaluating ev -> (
      match !ev with
      | BlackHole -> ev := Done (get_done s)
      | _ -> panic "impossible")
  | _ -> panic "impossible");
  record_memo_exit s

let lift_c (c : exp) : exp = c

let lift_value (src : source) (d : depth_t) : value =
  {
    seq = Generic.singleton (Reference { src; offset = 0; values_count = 1 });
    depth = d + 1;
    fetch_length = init_fetch_length ();
    compressed_since = 0;
  }

let rec enter_new_memo (s : state) (m : memo_t) : state =
  enter_new_memo_aux
    { m = s; s = Dynarray.create (); f = 0; r = Building }
    (Array.get m s.c.pc) true

(*only enter if there is an existing entries. this is cheaper then enter_new_memo.*)
and try_match_memo (s : state) (m : memo_t) : state =
  enter_new_memo_aux
    { m = s; s = Dynarray.create (); f = 0; r = Building }
    (Array.get m s.c.pc) false

and enter_new_memo_aux (rs : record_state) (m : memo_node_t ref)
    (matched : bool) : state =
  match !m with
  | BlackHole -> panic "impossible"
  | Done d ->
      rs.r <- Reentrance !m;
      d.skip rs
  | Root ->
      if matched then (
        m := BlackHole;
        rs.r <- Evaluating m;
        {
          c = lift_c rs.m.c;
          e =
            Dynarray.init (Dynarray.length rs.m.e) (fun i ->
                lift_value (E i) rs.m.d);
          k = lift_value K rs.m.d;
          d = rs.m.d + 1;
          last = Some rs;
        })
      else rs.m
  | Need n -> (
      match fetch_value rs n.request with
      | Some fr -> (
          match Hashtbl.find_opt n.lookup fr with
          | None ->
              let bh = ref BlackHole in
              Hashtbl.add n.lookup fr bh;
              rs.r <- Evaluating bh;
              n.progress.enter rs
          | Some m -> enter_new_memo_aux rs m true)
      | None ->
          if matched then (
            rs.r <- Reentrance !m;
            n.progress.enter rs)
          else rs.m)
