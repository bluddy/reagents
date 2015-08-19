(*
 * Copyright (c) 2015, Théo Laurent <theo.laurent@ens.fr>
 * Copyright (c) 2015, KC Sivaramakrishnan <sk826@cl.cam.ac.uk>
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

type 'a updt = { expect : 'a ; update : 'a }

type 'a state =
  | Idle of 'a
  | InProgress of 'a

type 'a ref = { mutable content : 'a state ;
                        id      : int      }

let get_id {id; _} = id

let compare_and_swap r x y =
  Obj.compare_and_swap_field (Obj.repr r) 0 (Obj.repr x) (Obj.repr y)
                             (* 0 stands for the first field *)

let ref x = { content = Idle x           ;
              id      = Oo.id (object end) }

let get r = match r.content with
  | Idle a -> a
  | InProgress a -> a

type t = CAS : 'a ref * 'a updt -> t

let cas r u = CAS (r, u)

let is_on_ref (CAS (r1, _)) r2 = r1.id == r2.id

let get_cas_id (CAS ({id;_},_)) = id

let commit (CAS (r, { expect ; update })) =
  let s = r.content in
  match s with
  | Idle a when a == expect -> compare_and_swap r s (Idle update)
  | _                         -> false

let semicas (CAS (r, { expect ; _ })) =
  let s = r.content in
  match s with
  | Idle a when a == expect -> compare_and_swap r s (InProgress a)
  | _                         -> false

(* Only the thread that performed the semicas should be able to rollbwd/fwd.
 * Hence, we don't need to CAS. *)
let rollbwd (CAS (r, _)) =
  match r.content with
  | Idle _      -> ()
  | InProgress x -> r.content <- Idle x

let rollfwd (CAS (r, { update ; _ })) =
  match r.content with
  | Idle _ -> failwith "CAS.kCAS: broken invariant"
  | InProgress x ->  r.content <- Idle update
                    (* we know we have x == expect *)

let kCAS l =
  let l = List.sort (fun c1 c2 -> compare (get_cas_id c1) (get_cas_id c2)) l
  in
  if List.for_all (fun cas -> semicas cas) l then
    ( List.iter rollfwd l ; true )
  else
    ( List.iter rollbwd l ; false )

module Sugar : sig
  val ref : 'a -> 'a ref
  val (!) : 'a ref -> 'a
  val (-->) : 'a -> 'a -> 'a updt
  val (<!=) : 'a ref -> 'a updt -> bool
  val (<:=) : 'a ref -> 'a updt -> t
end = struct
  type 'a casupdt = 'a updt
  type 'a casref = 'a ref
  let ref x = ref x
  let (!) r = get r

  let (-->) expect update = { expect ; update }

  let (<:=) = cas
  let (<!=) r u = commit (cas r u)
end

open Sugar

let try_map r f =
  let s = !r in
  match f s with
  | None -> true
  | Some v -> r <!= s --> v

let map r f =
  let b = Backoff.create () in
  let rec loop () =
    if try_map r f then ()
    else ( Backoff.once b ; loop ())
  in loop ()

let incr r = map r (fun x -> Some (x + 1))
let decr r = map r (fun x -> Some (x - 1))
