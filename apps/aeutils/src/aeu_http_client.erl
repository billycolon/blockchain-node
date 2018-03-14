-module(aeu_http_client).

%% API
-export([request/3]).

-spec request(iodata(), atom(), list({string(), iodata()}) | map()) -> {ok, integer(), any()} | {error, any()}.
request(BaseUri, OperationId, Params) ->
    Timeout = aeu_env:user_config_or_env(
                [<<"http">>, <<"external">>,<<"request_timeout">>],
                aehttp, http_request_timeout, 5000),
    CTimeout = aeu_env:user_config_or_env(
                 [<<"http">>, <<"external">>, <<"connect_timeout">>],
                 aehttp, http_connect_timeout, max(Timeout, 1000)),
    HTTPOptions = [{timeout, Timeout}, {connect_timeout, CTimeout}],
    %% we support only one method at the moment
    [Method|_] = maps:keys(endpoints:operation(OperationId)),
    Endpoint = endpoints:path(Method, OperationId, Params),
    request(BaseUri, Method, Endpoint, Params, [], HTTPOptions, []).

request(BaseUri, get, Endpoint, Params, Header, HTTPOptions, Options) ->
    URL = binary_to_list(
            iolist_to_binary(
              [BaseUri, Endpoint, encode_get_params(Params)])),
    lager:debug("GET URL = ~p", [URL]),
    R = httpc:request(get, {URL, Header}, HTTPOptions, Options),
    process_http_return(R);
request(BaseUri, post, Endpoint, Params, Header, HTTPOptions, Options) ->
    URL = binary_to_list(iolist_to_binary([BaseUri, Endpoint])),
    {Type, Body} = case Params of
                       Map when is_map(Map) ->
                           %% JSON-encoded
                           lager:debug("JSON-encoding Params: ~p",[Params]),
                           {"application/json", jsx:encode(Params)};
                       [] ->
                           {"application/x-www-form-urlencoded",
                            http_uri:encode(Endpoint)}  %% is this correct??
                   end,
    lager:debug("POST URL = ~p Type = ~p; Body = ~p", [URL, Type, Body]),
    R = httpc:request(post, {URL, Header, Type, Body}, HTTPOptions, Options),
    process_http_return(R).

process_http_return(R) ->
    case R of
        %% if Body == [] an error is thrown!
        {ok, {{_, StatusCode, _State}, _Head, Body}} ->
            try
                Result = jsx:decode(iolist_to_binary(Body), [return_maps]),
                lager:debug("Decoded response: ~p", [Result]),
                {ok, StatusCode, Result}
            catch
                error:E ->
                    lager:error("http response ~p", [R]),
                    {error, {parse_error, [E, erlang:get_stacktrace()]}}
            end;
        {error, _} = Error ->
            lager:debug("process_http_return: ~p", [Error]),
            Error
    end.

-spec encode_get_params(map() | list({string(), iodata()})) -> iodata().
encode_get_params(#{} = Ps) ->
    encode_get_params(maps:to_list(Ps));
encode_get_params(Params) when is_list(Params) ->
    ["?", lists:join( "&", [ [http_uri:encode(to_string(K)), "=" , http_uri:encode(to_string(V))]
                             || {K,V} <- Params ] ) ].

to_string(A) when is_atom(A) ->
    atom_to_list(A);
to_string(N) when is_integer(N) ->
    integer_to_list(N);
to_string(S) ->
    S.
