val model : string
val canonical_identity : string
val dimensions : int
val maximum_response_bytes : int

type usage = { prompt_tokens : int; total_tokens : int }
type embedding = { values : float array; usage : usage; identity : string }

type error_kind =
  | Authentication
  | Validation
  | Rate_limited
  | Payment_required
  | Transient
  | Invalid_response
  | Response_too_large

type error = {
  kind : error_kind;
  code : string;
  message : string;
  paid_request_ambiguous : bool;
}

val request_body : string -> string
val parse_response : status:int -> body:string -> (embedding, error) result
val embed : api_key:string -> string -> (embedding, error) result
val authenticated_model_check : api_key:string -> (unit, error) result

module For_test : sig
  type request_kind = Non_paid_get | Paid_post

  val run_retry :
    request_kind:request_kind ->
    total_timeout_ms:int ->
    now:(unit -> float) ->
    sleep:(float -> unit) ->
    jitter:(unit -> float) ->
    operation:(timeout_ms:int -> ('a, error) result) ->
    ('a, error) result

  val with_curl_setup_exception : Curl.curlCode -> (unit -> 'a) -> 'a * int

  val embed_at :
    ?timeout_ms:int ->
    url:string ->
    api_key:string ->
    string ->
    (embedding, error) result

  val authenticated_model_check_at :
    timeout_ms:int -> url:string -> api_key:string -> (unit, error) result
end
