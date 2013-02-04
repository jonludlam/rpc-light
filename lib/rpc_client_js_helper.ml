
let test = "{\"foo\":\"bar\",\"baz\":[\"1\",\"2\",\"3\"],\"hello\":true}"

let dummy = Printf.sprintf "foo"

let keys obj =
	let arr = Js.Unsafe.meth_call (Js.Unsafe.variable "Object") "keys" [| Js.Unsafe.inject obj |] in
	List.map (Js.to_string) (Array.to_list (Js.to_array arr))

let is_array obj =
	Js.instanceof obj Js.array_empty

let mlString_constr = Js.Unsafe.variable "MlString"
let is_string obj =
	Js.instanceof obj mlString_constr

let rec rpc_of_json json =
	let ty = Js.typeof json in
	match (Js.to_string ty) with
		| "object" ->
			if is_array ty then begin
				let l = Array.to_list (Js.to_array json) in
				Rpc.Enum (List.map rpc_of_json l)				
			end else if is_string json then begin
				Rpc.String (Js.to_string (Js.Unsafe.coerce json))
			end else begin
				let okeys = keys json in
				Rpc.Dict (List.map (fun x -> (x, rpc_of_json (Js.Unsafe.get json (Js.string x)))) okeys)
			end
		| "boolean" ->
			Rpc.Bool (Js.to_bool (Obj.magic json))
		| _ ->
			Firebug.console##log (Js.string (Printf.sprintf "Ack! got %s" (Js.to_string ty)));
			Rpc.Bool false

let of_string s = rpc_of_json (Json.unsafe_input (Js.string s))

let to_string rpc =
	let rec inner = function 
		| Rpc.Dict kvs ->
			let o = Json.unsafe_input (Js.string "{}") in
			List.iter (fun (x,y) -> Js.Unsafe.set o (Js.string x) (inner y)) kvs
		| Rpc.Int x -> Obj.magic (Js.string (Int64.to_string x))
		| Rpc.Int32 x -> Obj.magic (Js.string (Int32.to_string x))
		| Rpc.Float x -> Obj.magic (Js.string (string_of_float x))
		| Rpc.String x -> Obj.magic (Js.string x)
		| Rpc.Bool x -> Obj.magic (if x then Js._true else Js._false)
		| Rpc.DateTime x -> Obj.magic (Js.string x)
		| Rpc.Enum l -> Obj.magic (Js.array (Array.of_list (List.map inner l)))
		| Rpc.Null -> Obj.magic (Js.null)
	in Json.output (inner rpc)

let new_id =
	let count = ref 0L in
	(fun () -> count := Int64.add 1L !count; !count)

let string_of_call call =
	let json = Rpc.Dict [
		"method", Rpc.String call.Rpc.name;
		"params", Rpc.Enum call.Rpc.params;
		"id", Rpc.Int (new_id ());
	] in
	to_string json

exception Malformed_method_response of string

let get name dict =
	if List.mem_assoc name dict then
		List.assoc name dict
	else begin
		Printf.eprintf "%s was not found in the dictionary\n" name;
		let str = List.map (fun (n,_) -> Printf.sprintf "%s=..." n) dict in
		let str = Printf.sprintf "{%s}" (String.concat "," str) in
		raise (Malformed_method_response str)
	end

let response_of_string str =
	match of_string str with
		| Rpc.Dict d ->
			let result = get "result" d in
			let error = get "error" d in
			let (_:int64) = match get "id" d with Rpc.Int i -> i | _ -> raise (Malformed_method_response "id") in
			begin match result, error with
				| v, Rpc.Null    -> Rpc.success v
				| Rpc.Null, v    -> Rpc.failure v
				| x,y        -> raise (Malformed_method_response (Printf.sprintf "<result=%s><error=%s>" (Rpc.to_string x) (Rpc.to_string y)))
			end
		| rpc -> failwith "Bah"