-module(aec_tx).

-export([apply_signed/3]).

-include("common.hrl").
-include("trees.hrl").
-include("txs.hrl").

%% aec_tx behavior callbacks

-callback new(Args :: map(), Trees :: trees()) ->
    {ok, Tx :: term()}.

-callback run(Tx :: term(), Trees :: trees(), Height :: non_neg_integer()) ->
    {ok, NewTrees :: trees()}.


%% API

-spec apply_signed(list(signed_tx()), trees(), non_neg_integer()) -> {ok, trees()} | {error, term()}.
apply_signed([], Trees, _Height) ->
    {ok, Trees};
apply_signed([SignedTx | Rest], Trees0, Height) ->
    case aec_tx_sign:verify(SignedTx) of
        ok ->
            Tx = aec_tx_sign:data(SignedTx),
            case aec_proofs:prove(Tx, Trees0) of
                ok ->
                    {ok, Trees} = apply_single(Tx, Trees0, Height),
                    apply_signed(Rest, Trees, Height);
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.


%% Internal functions

-spec apply_single(coinbase_tx(), trees(), non_neg_integer()) -> {ok, trees()}.
apply_single(#coinbase_tx{} = Tx, Trees, Height) ->
    aec_coinbase_tx:run(Tx, Trees, Height).
