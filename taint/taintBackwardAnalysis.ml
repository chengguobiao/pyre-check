(** Copyright (c) 2016-present, Facebook, Inc.

    This source code is licensed under the MIT license found in the
    LICENSE file in the root directory of this source tree. *)

open Core

open Analysis
open Ast
open Expression
open Pyre
open Statement
open TaintDomains
open TaintAccessPath


module type FixpointState = sig
  type t = { taint: BackwardState.t }
  [@@deriving show]

  include Fixpoint.State with type t := t

  val create: unit -> t
end


let initial_taint =
  let result_taint = BackwardTaint.add BackwardTaint.empty TaintSinks.LocalReturn in
  BackwardState.assign
    ~root:Root.LocalResult
    ~path:[]
    (BackwardState.make_leaf result_taint)
    BackwardState.empty


module type FUNCTION_CONTEXT = sig
  val definition : Define.t
end


module AnalysisInstance(FunctionContext: FUNCTION_CONTEXT) = struct

  module rec FixpointState : FixpointState = struct

    type t = { taint: BackwardState.t }
    [@@deriving show]


    let create () =
      { taint = BackwardState.empty }


    let less_or_equal ~left:{ taint = left; _ } ~right:{ taint = right; _ } =
      BackwardState.less_or_equal ~left ~right


    let join { taint = left } { taint = right; _ } =
      let taint = BackwardState.join left right in
      { taint }


    let widen ~previous:{ taint = previous; _ } ~next:{ taint = next; _ } ~iteration =
      let taint = BackwardState.widen ~iteration ~previous ~next in
      { taint }


    let get_taint access_path { taint; _ } =
      match access_path with
      | None ->
          BackwardState.empty_tree
      | Some { root; path } ->
          BackwardState.read_access_path ~root ~path taint


    let store_weak_taint ~root ~path taint { taint = state_taint } =
      { taint = BackwardState.assign_weak ~root ~path taint state_taint }


    let store_weak_taint_option access_path taint state =
      match access_path with
      | None -> state
      | Some (root, path) -> store_weak_taint ~root ~path taint state


    let rec analyze_argument taint { Argument.value = argument; _ } state =
      analyze_expression taint argument state


    and analyze_call_target call_target arguments state call_taint =
      let existing_model =
        Interprocedural.Fixpoint.get_model call_target
        >>= Interprocedural.Result.get_model TaintResult.kind
      in
      match existing_model with
      | Some { backward; _ } ->
          let collapsed_call_taint = BackwardState.collapse call_taint in
          let reversed_arguments = List.rev arguments in
          let number_of_arguments = List.length arguments in
          let analyze_argument_position reverse_position state argument =
            let position = number_of_arguments - reverse_position - 1 in
            let argument_taint =
              BackwardState.read
                (TaintAccessPath.Root.Parameter { position })
                backward.sink_taint
            in
            let taint_in_taint_out =
              BackwardState.read
                (TaintAccessPath.Root.Parameter { position })
                backward.taint_in_taint_out
              |> BackwardState.filter_map_tree ~f:(fun _ -> collapsed_call_taint)
            in
            let argument_taint = BackwardState.join_trees argument_taint taint_in_taint_out in
            analyze_argument argument_taint argument state
          in
          List.foldi ~f:analyze_argument_position reversed_arguments ~init:state
      | None ->
          Log.log
            ~section:`Taint
            "No model found for %s"
            (Log.Color.cyan (Interprocedural.Callable.show call_target));
          (* TODO(T31435739): if we don't have a model: assume function propagates argument
             taint to result. *)
          List.fold_right ~f:(analyze_argument call_taint) arguments ~init:state


    and analyze_call ~callee arguments state taint =
      match callee with
      | Identifier identifier when Identifier.show identifier = "__testSink" ->
          let test_taint = BackwardState.make_leaf (BackwardTaint.singleton TaintSinks.TestSink) in
          List.fold_right ~f:(analyze_argument test_taint) arguments ~init:state

      | Identifier identifier when Identifier.show identifier = "__testRCESink" ->
          let test_taint =
            BackwardState.make_leaf (BackwardTaint.singleton TaintSinks.RemoteCodeExecution)
          in
          List.fold_right ~f:(analyze_argument test_taint) arguments ~init:state

      | Identifier identifier ->
          let call_target =
            Interprocedural.Callable.make_real (Access.create_from_identifiers [identifier])
          in
          analyze_call_target call_target arguments state taint

      | Access { expression = receiver; member = method_name} ->
          (* TODO(T32198746): figure out the BW and TAINT_IN_TAINT_OUT model for
             whatever is called here.
             Member access. Don't propagate the taint to the member, skip to the receiver. *)
          let state = List.fold_right ~f:(analyze_argument taint) arguments ~init:state in
          analyze_normalized_expression state taint receiver

      | _ ->
          (* TODO(T32198746): figure out the BW and TAINT_IN_TAINT_OUT model for
             whatever is called here.
             For now, we propagate taint to all args implicitly, and to the function. *)
          let state = List.fold_right ~f:(analyze_argument taint) arguments ~init:state in
          analyze_normalized_expression state taint callee


    and analyze_normalized_expression state taint expression =
      match expression with
      | Access { expression; member } ->
          let field = TaintAccessPathTree.Label.Field member in
          let taint =
            BackwardState.assign_tree_path [field] ~tree:BackwardState.empty_tree ~subtree:taint
          in
          analyze_normalized_expression state taint expression
      | Call { callee; arguments; } ->
          analyze_call ~callee arguments state taint
      | Expression expression ->
          analyze_expression taint expression state
      | Identifier name ->
          store_weak_taint ~root:(Root.Variable name) ~path:[] taint state

    and analyze_expression taint { Node.value = expression; _ } state =
      match expression with
      | Access access ->
          normalize_access access
          |> analyze_normalized_expression state taint
      | Await _
      | BooleanOperator _
      | ComparisonOperator _
      | Complex _
      | Dictionary _
      | DictionaryComprehension _
      | Ellipses
      | False
      | Float _
      | Generator _
      | Integer _
      | Lambda _
      | List _
      | ListComprehension _
      | Set _
      | SetComprehension _
      | Starred _
      | String _
      | Ternary _
      | True
      | Tuple _
      | UnaryOperator _
      | Yield _ ->
          state


    let analyze_expression_option taint expression state =
      match expression with
      | None -> state
      | Some expression -> analyze_expression taint expression state


    let analyze_definition ~define:_ _ =
      failwith "We don't handle nested defines right now"


    let analyze_statement state statement =
      Log.log ~section:`Taint "Backward state: %s" (Log.Color.yellow (show state));
      match statement with
      | Assign { target; value; _ } ->
          let access_path = of_expression target in
          analyze_expression_option (get_taint access_path state) value state
      | Assert _
      | Break
      | Class _
      | Continue ->
          state
      | Define define ->
          analyze_definition ~define state
      | Delete _ ->
          state
      | Expression expression ->
          analyze_expression BackwardState.empty_tree expression state
      | For _
      | Global _
      | If _
      | Import _
      | Nonlocal _
      | Pass
      | Raise _ ->
          state
      | Return { expression = Some expression; _ } ->
          let access_path = { root = Root.LocalResult; path = [] } in
          let return_taint = get_taint (Some access_path) state in
          analyze_expression return_taint expression state
      | Return { expression = None; _ }
      | Try _
      | With _
      | While _
      | Yield _
      | YieldFrom _ ->
          state


    let backward state ~statement:({ Node.value = statement; _ }) =
      analyze_statement state statement


    let forward ?key:_ state ~statement =
      failwith "Don't call me"
  end


  and Analyzer : Fixpoint.Fixpoint with type state = FixpointState.t = Fixpoint.Make(FixpointState)

end

(* Split the inferred entry state into externally visible taint_in_taint_out
   parts and sink_taint. *)
let extract_tito_and_sink_models parameters entry_taint =
  let filter_to_local_return taint =
    BackwardTaint.filter ~f:((=) TaintSinks.LocalReturn) taint
  in
  let extract_taint_in_taint_out position model { Node.value = { Parameter.name; _ }; _ } =
    let taint_in_taint_out_taint =
      BackwardState.read (Root.Variable name) entry_taint
      |> BackwardState.filter_map_tree ~f:filter_to_local_return
    in
    if not (BackwardState.is_empty_tree taint_in_taint_out_taint) then
      let parameter = Root.(Parameter { position }) in
      BackwardState.assign ~root:parameter ~path:[] taint_in_taint_out_taint model
    else
      model
  in
  let filter_to_real_sinks taint =
    BackwardTaint.filter ~f:((<>) TaintSinks.LocalReturn) taint
  in
  let extract_sink_taint position model { Node.value = { Parameter.name; _ }; _ } =
    let sink_taint =
      BackwardState.read (Root.Variable name) entry_taint
      |> BackwardState.filter_map_tree ~f:filter_to_real_sinks
    in
    if not (BackwardState.is_empty_tree sink_taint) then
      let parameter = Root.(Parameter { position }) in
      BackwardState.assign ~root:parameter ~path:[] sink_taint model
    else
      model
  in
  let taint_in_taint_out =
    List.foldi parameters ~f:extract_taint_in_taint_out ~init:BackwardState.empty
  in
  let sink_taint =
    List.foldi parameters ~f:extract_sink_taint ~init:BackwardState.empty
  in
  TaintResult.Backward.{ taint_in_taint_out; sink_taint; }


let run ({ Define.name; parameters; _ } as define) =
  (* TODO(T31697954): initial_taint is hardcoded *)
  let module AnalysisInstance = AnalysisInstance(struct let definition = define end) in
  let open AnalysisInstance in
  let initial = FixpointState.{ taint = initial_taint } in
  let cfg = Cfg.create define in
  let () = Log.log ~section:`Taint "Processing CFG:@.%s" (Log.Color.yellow (Cfg.show cfg)) in
  let entry_state =
    Analyzer.backward ~cfg ~initial
    |> Analyzer.entry
  in
  let () =
    match entry_state with
    | Some entry_state ->
        Log.log
          ~section:`Taint
          "Final state: %s"
          (Log.Color.yellow (FixpointState.show entry_state))
    | None ->
        Log.log ~section:`Taint "No final state found"
  in
  let extract_model FixpointState.{ taint; _ } =
    let model = extract_tito_and_sink_models parameters taint in
    let () =
      Log.log
        ~section:`Taint
        "Models: %s"
        (Log.Color.yellow (TaintResult.Backward.show_model model))
    in
    model
  in
  entry_state
  >>| extract_model
  |> Option.value ~default:TaintResult.Backward.empty
