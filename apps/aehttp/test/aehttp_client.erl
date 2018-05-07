-module(aehttp_client).

-export([
         request/3,
         request/8
        ]).

%%=============================================================================
%% API
%%=============================================================================

%% Required config values: int_http, ext_http
%% Optional config values: ct_log (true by default)
request(OpId, Params, Cfg) ->
    Op = endpoints:operation(OpId),
    {Method, Interface} = operation_spec(Op),
    BaseUrl = make_base_url(proplists:get_value(Interface, Cfg)),
    Path = operation_path(Method, OpId, convert_params(Params)),
    request(Method, BaseUrl, Path, Params, [], [], [], Cfg).

request(get, BaseUrl, Path, QueryParams, Headers, HttpOpts, Opts, Cfg) ->
    Url = make_url(BaseUrl, Path, QueryParams),
    log("GET ~p", [Url], Cfg),
    Resp = httpc:request(get, {Url, Headers}, HttpOpts, Opts),
    process_response(Resp, Cfg);
request(post, BaseUrl, Path, BodyParams, Headers, HttpOpts, Opts, Cfg) ->
    Url = make_url(BaseUrl, Path, #{}),
    {ContentType, Body} = make_body(BodyParams, Path),
    log("POST ~p~nContentType ~p~n~p", [Url, ContentType, BodyParams], Cfg),
    Resp = httpc:request(post, {Url, Headers, ContentType, Body}, HttpOpts, Opts),
    process_response(Resp, Cfg).

%%=============================================================================
%% Internal functions
%%=============================================================================

process_response({ok, {{_, Code, _State}, _Head, Body}}, Cfg) ->
    case iolist_to_binary(Body) of
        <<>> ->
            log("Return code: ~p", [Code], Cfg),
            {ok, Code, #{}};
        Body1 ->
            Body2 = jsx:decode(Body1, [{labels, attempt_atom}, return_maps]),
            log("Return code: ~p, body: ~p", [Code, Body2], Cfg),
            {ok, Code, Body2}
    end;
process_response({error, _} = Error, _Cfg) ->
    Error.

log(Fmt, Params, Cfg) ->
    case proplists:get_value(ct_log, Cfg, true) of
        true -> ct:log(Fmt, Params);
        F when is_function(F) -> F(Fmt, Params);
        false -> ok
    end.

operation_spec(#{get := GetSpec}) ->
    {get, operation_interface(GetSpec)};
operation_spec(#{post := PostSpec}) ->
    {post, operation_interface(PostSpec)}.

operation_interface(#{tags := Tags}) ->
    IsExt = lists:member(<<"external">>, Tags),
    IsInt = lists:member(<<"internal">>, Tags),
    case {IsExt, IsInt} of
        {true, _} -> ext_http;
        {_, true} -> int_http
    end.

%% Swagger spec requires keys to be of type list and non-numeric values
%% must be converted to list as well.
convert_params(Params) ->
    ConvF =
        fun(K, V, Acc) when is_binary(V) ->
                maps:put(atom_to_list(K), binary_to_list(V), Acc);
           (K, V, Acc) when is_atom(V) ->
                maps:put(atom_to_list(K), atom_to_list(V), Acc);
           (K, V, Acc) ->
                maps:put(atom_to_list(K), V, Acc)
        end,
    maps:fold(ConvF, #{}, Params).

%% Remove the '/' at the end of base URL.
make_base_url(BaseUrl) when is_binary(BaseUrl) ->
    make_base_url(binary_to_list(BaseUrl));
make_base_url(BaseUrl) ->
    case lists:last(BaseUrl) of
        $/ -> lists:droplast(BaseUrl);
        _ -> BaseUrl
    end.

operation_path(Method, OpId, Params) ->
    %% The path includes the leading '/'.
    case endpoints:path(Method, OpId, Params) of
        <<Path/binary>> ->
            Path;
        [<<Part1/binary>>, Part2, Part3] ->
            iolist_to_binary([Part1, Part2, Part3])
    end.

make_url(BaseUrl, Path, Params) ->
    Url = [BaseUrl, Path, make_query(maps:to_list(Params))],
    binary_to_list(iolist_to_binary(Url)).

make_query([{K, V} | T]) ->
    [$?, [encode(K), $= , encode(V)
          | [[$&, encode(K1), $=, encode(V1)] || {K1, V1} <- T]]];
make_query([]) ->
    [].

make_body(Params, _Path) when is_map(Params) ->
    {"application/json", jsx:encode(Params)};
make_body([], Path) ->
    {"application/x-www-form-urlencoded", http_uri:encode(Path)}.

encode(X) when is_atom(X) -> encode(atom_to_list(X));
encode(X) when is_integer(X) -> encode(integer_to_list(X));
encode(X) when is_list(X); is_binary(X) -> http_uri:encode(X).

